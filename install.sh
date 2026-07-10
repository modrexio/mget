#!/bin/sh
# Not meant to be curled directly: a project's own endpoint fetches this file
# plus its install.config.json and prepends the config as CFG_* env vars.
set -eu

DRY_RUN=0
UNINSTALL=0
ASSUME_YES=0
PURGE=0
VERSION_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    --purge) PURGE=1 ;;
    --version)
      [ $# -ge 2 ] || { echo "error: --version requires an argument" >&2; exit 1; }
      VERSION_OVERRIDE="$2"; shift ;;
    --install-dir)
      [ $# -ge 2 ] || { echo "error: --install-dir requires an argument" >&2; exit 1; }
      CFG_INSTALL_DIR="$2"; shift ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done
[ "$PURGE" -eq 1 ] && [ "$UNINSTALL" -eq 0 ] && { echo "error: --purge only applies to --uninstall" >&2; exit 1; }

: "${CFG_SCHEMA_VERSION:?missing CFG_SCHEMA_VERSION}"
[ "$CFG_SCHEMA_VERSION" = "1" ] || { echo "error: unsupported config schema version: $CFG_SCHEMA_VERSION" >&2; exit 1; }
: "${CFG_PROJECT_NAME:?missing CFG_PROJECT_NAME}"
: "${CFG_MANIFEST_URL:?missing CFG_MANIFEST_URL}"
: "${CFG_INSTALL_DIR:?missing CFG_INSTALL_DIR}"
CFG_GITHUB_REPO="${CFG_GITHUB_REPO:-}"
CFG_PUBKEY="${CFG_PUBKEY:-}"
CFG_ADD_TO_PATH="${CFG_ADD_TO_PATH:-true}"
CFG_POST_INSTALL_CMD="${CFG_POST_INSTALL_CMD:-}"
CFG_UNINSTALL_MANIFEST="${CFG_UNINSTALL_MANIFEST:-\$HOME/.$CFG_PROJECT_NAME/uninstall.json}"
CFG_MACOS_BUNDLE_NAME="${CFG_MACOS_BUNDLE_NAME:-$CFG_PROJECT_NAME}"
CFG_MACOS_EXECUTABLE_NAME="${CFG_MACOS_EXECUTABLE_NAME:-$CFG_PROJECT_NAME}"
# Package identifiers don't necessarily match the project's display/command
# name. Debian Policy (5.6.7) hard-requires lowercase and forbids underscores
# in package names — a project_name like "Refract_MC" can never literally
# equal its own .deb package name. RPM/Fedora naming is a softer convention
# (lowercase preferred, not tooling-enforced), but can still diverge. These
# let a project declare the true identifier instead of assuming they match.
CFG_DEB_PACKAGE_NAME="${CFG_DEB_PACKAGE_NAME:-$CFG_PROJECT_NAME}"
CFG_RPM_PACKAGE_NAME="${CFG_RPM_PACKAGE_NAME:-$CFG_PROJECT_NAME}"
# The project's own public curl URL (e.g. https://modrex.net/install.sh), used
# only to print an accurate --uninstall hint after a successful install. This
# engine has no way to know its own public URL otherwise.
CFG_INSTALL_URL="${CFG_INSTALL_URL:-}"
# Per-OS preferred packaging variant, e.g. "linux:appimage darwin:app" — space-separated
# key:value pairs, since env vars can't carry a nested JSON object.
CFG_PREFERRED_VARIANT="${CFG_PREFERRED_VARIANT:-}"

case "$CFG_MANIFEST_URL" in
  https://*) ;;
  *) echo "error: CFG_MANIFEST_URL must be https://" >&2; exit 1 ;;
esac

# project_name ends up in filesystem paths, symlink targets, and desktop
# filenames — reject anything that could turn "$INSTALL_DIR/$CFG_PROJECT_NAME"
# into a path outside INSTALL_DIR (e.g. "..").
case "$CFG_PROJECT_NAME" in
  .|..) echo "error: invalid project_name: $CFG_PROJECT_NAME" >&2; exit 1 ;;
  *[!A-Za-z0-9._-]*) echo "error: project_name may contain only letters, digits, '.', '_', '-'" >&2; exit 1 ;;
esac
# macOS bundle names may legitimately contain spaces, so only path-traversal
# and control characters are rejected here, not the full project_name
# character set. Any control character (not just newline) could corrupt the
# newline-delimited INSTALLED_FILES/uninstall-manifest representation.
case "$CFG_MACOS_BUNDLE_NAME" in
  .|..|*/*|*'\'*) echo "error: invalid macos_bundle_name: $CFG_MACOS_BUNDLE_NAME" >&2; exit 1 ;;
esac
if printf '%s' "$CFG_MACOS_BUNDLE_NAME" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  echo "error: macos_bundle_name contains a control character: $CFG_MACOS_BUNDLE_NAME" >&2
  exit 1
fi
# Unlike the bundle name, this is a single path component under Contents/MacOS/
# with no reason to contain a space, so it gets the same restricted set as
# project_name rather than the looser bundle-name rules.
case "$CFG_MACOS_EXECUTABLE_NAME" in
  .|..) echo "error: invalid macos_executable_name: $CFG_MACOS_EXECUTABLE_NAME" >&2; exit 1 ;;
  *[!A-Za-z0-9._-]*) echo "error: macos_executable_name may contain only letters, digits, '.', '_', '-'" >&2; exit 1 ;;
esac

# No eval: only $HOME/... and absolute paths are accepted, so config data can
# never be interpreted as shell code. Applies to every config value that's a
# filesystem path, not just CFG_INSTALL_DIR — a literal, un-expanded "$HOME"
# passed straight through would otherwise create paths relative to cwd.
expand_home_path() {
  case "$1" in
    '$HOME'/*) printf '%s/%s' "$HOME" "${1#\$HOME/}" ;;
    /*) printf '%s' "$1" ;;
    *) return 1 ;;
  esac
}
INSTALL_DIR=$(expand_home_path "$CFG_INSTALL_DIR") \
  || { echo "error: CFG_INSTALL_DIR must be an absolute path or start with \$HOME/: $CFG_INSTALL_DIR" >&2; exit 1; }
CFG_UNINSTALL_MANIFEST=$(expand_home_path "$CFG_UNINSTALL_MANIFEST") \
  || { echo "error: CFG_UNINSTALL_MANIFEST must be an absolute path or start with \$HOME/: $CFG_UNINSTALL_MANIFEST" >&2; exit 1; }

# A path value is later interpolated into a double-quoted line appended to
# the user's shell rc file (export PATH="$INSTALL_DIR:$PATH"). Double-quoted
# shell strings still expand $(...) and old-style backtick substitution, so
# an unrestricted path could plant a command that runs the next time the
# user opens a shell — a delayed
# injection eval-removal alone doesn't prevent. Restricting to ordinary path
# characters closes that off entirely. ':' is excluded here specifically
# (unlike the uninstall-manifest check below) because INSTALL_DIR is actually
# inserted into PATH — an embedded ':' would silently split it into two PATH
# entries, and a non-absolute second entry is a classic command-hijack vector.
case "$INSTALL_DIR" in
  *[!A-Za-z0-9_./+-]*) echo "error: install_dir contains unsupported characters: $INSTALL_DIR" >&2; exit 1 ;;
esac
case "$CFG_UNINSTALL_MANIFEST" in
  *[!A-Za-z0-9_./+:-]*) echo "error: uninstall_manifest contains unsupported characters: $CFG_UNINSTALL_MANIFEST" >&2; exit 1 ;;
esac

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

info() { [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && printf '\033[1;34m==>\033[0m %s\n' "$*" || printf '==> %s\n' "$*"; }
warn() { [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2 || printf 'warn: %s\n' "$*" >&2; }
err()  { [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && printf '\033[1;31merror:\033[0m %s\n' "$*" >&2 || printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have curl || err "curl is required"
have jq   || err "jq is required (e.g. 'apt install jq' / 'brew install jq')"

# In the common curl-pipe-to-sh invocation, fd 0 (stdin) is the piped script
# source, not the terminal — reading a prompt from it would consume script
# bytes as the answer. /dev/tty is the real terminal regardless of how stdin
# is wired, which is why scripts/install.sh's confirm() does the same thing.
confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local reply=""
  if [ -t 0 ]; then
    printf '%s [y/N] ' "$1" >&2
    read -r reply || reply=""
  elif { : </dev/tty; } 2>/dev/null; then
    printf '%s [y/N] ' "$1" >&2
    read -r reply </dev/tty || reply=""
  else
    err "refusing to proceed without confirmation in a non-interactive shell — rerun with -y"
  fi
  case "$reply" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

SUDO=""
require_sudo() {
  [ "$(id -u)" -eq 0 ] && return
  have sudo || err "sudo is required for this operation"
  SUDO="sudo"
}

detect_platform() {
  case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=darwin ;;
    *) err "unsupported OS: $(uname -s) — this installer supports Linux and macOS only" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) ARCH=x86_64 ;;
    arm64|aarch64) ARCH=aarch64 ;;
    *) err "unsupported architecture: $(uname -m)" ;;
  esac
}

# Native package manager, when present, is preferred over a raw AppImage —
# same priority order as modrex's scripts/install.sh.
PKG_MANAGER=""
detect_pkg_manager() {
  [ "$OS" = linux ] || return 0
  if have apt-get; then PKG_MANAGER=apt
  elif have dnf; then PKG_MANAGER=dnf
  elif have zypper; then PKG_MANAGER=zypper
  fi
}

fetch_manifest() {
  info "fetching release manifest"
  curl_download "$CFG_MANIFEST_URL" "$WORK_DIR/manifest.json" \
    || err "failed to fetch $CFG_MANIFEST_URL"
}

json_get() { jq -r ".$1" "$WORK_DIR/manifest.json"; }
platform_field() { jq -r ".platforms[\"$1\"].$2 // empty" "$WORK_DIR/manifest.json"; }

preferred_variant_for() {
  local pair
  for pair in $CFG_PREFERRED_VARIANT; do
    case "$pair" in
      "$1":*) echo "${pair#*:}"; return ;;
    esac
  done
  echo ""
}

# --proto/--proto-redir lock https-only through the whole redirect chain —
# -L alone only means "follow redirects," not "stay on https," so a github.com
# URL that happened to redirect to plain http would otherwise be followed.
curl_download() {
  curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --retry 2 "$1" -o "$2"
}

# Same as curl_download but with visible progress — for the actual asset
# (an AppImage/deb/rpm/app.tar.gz can be 50-100MB+), a silent multi-minute
# download looks hung. Not used for the tiny JSON fetches, where a progress
# bar would just flash and add noise. curl's progress bar goes to stderr, so
# it's unaffected by the outer curl-to-sh pipe carrying this script's own stdout.
curl_download_progress() {
  curl -fL --proto '=https' --proto-redir '=https' --connect-timeout 10 --retry 2 --progress-bar "$1" -o "$2"
}

# Looks up the actual asset list from the GitHub Releases API rather than
# guessing a filename convention — a bundler/packaging change just changes
# what's in this list, nothing to keep in sync by hand. Cached in WORK_DIR so
# repeated lookups (deb, then rpm) don't refetch.
fetch_github_release() {
  [ -z "${GH_RELEASE_FETCHED:-}" ] || return 0
  [ -n "$CFG_GITHUB_REPO" ] || return 1
  curl_download "https://api.github.com/repos/$CFG_GITHUB_REPO/releases/latest" "$WORK_DIR/gh_release.json" \
    || { warn "failed to query GitHub releases API for $CFG_GITHUB_REPO"; return 1; }
  GH_RELEASE_FETCHED=1
}

# Release asset whose filename ends in ".$1" (e.g. "deb", "rpm"). Among
# multiple matches (a project shipping separate amd64/arm64 packages),
# prefers one whose filename mentions this machine's architecture; falls
# back to the first match if none do. check_package_arch, run after
# download, remains the actual authority — this is just picking a sane
# candidate to try first, not a substitute for that check.
find_gh_asset_url() {
  local ext arch_pattern
  ext="$1"
  case "$ARCH" in
    x86_64) arch_pattern="x86_64|amd64|x64" ;;
    aarch64) arch_pattern="aarch64|arm64" ;;
  esac
  jq -r --arg ext ".$ext" --arg re "$arch_pattern" '
    [.assets[] | select(.name | endswith($ext))] as $cands
    | ($cands | map(select(.name | test($re; "i")))[0].browser_download_url) as $matched
    | if $matched then $matched else ($cands[0].browser_download_url // empty) end
  ' "$WORK_DIR/gh_release.json"
}

# Precedence: an explicit preferred_variant manifest key wins; then, on Linux
# with a detected package manager, a matching .deb/.rpm asset discovered via
# the GitHub Releases API; then a deb/rpm manifest key if the project's
# manifest happens to publish one; then the bare {os}-{arch} manifest key
# (AppImage on Linux, .app on macOS).
resolve_asset_source() {
  local base_key variant url
  base_key="${OS}-${ARCH}"
  ASSET_SOURCE=""

  variant=$(preferred_variant_for "$OS")
  if [ -n "$variant" ] && [ -n "$(platform_field "${base_key}-${variant}" url)" ]; then
    ASSET_SOURCE=manifest; ASSET_KEY="${base_key}-${variant}"; return
  fi

  if [ "$OS" = linux ]; then
    case "$PKG_MANAGER" in
      apt)
        if fetch_github_release; then
          url=$(find_gh_asset_url deb)
          [ -n "$url" ] && { ASSET_SOURCE=pattern; ASSET_URL="$url"; return; }
        fi
        if [ -n "$(platform_field "${base_key}-deb" url)" ]; then
          ASSET_SOURCE=manifest; ASSET_KEY="${base_key}-deb"; return
        fi
        ;;
      dnf|zypper)
        if fetch_github_release; then
          url=$(find_gh_asset_url rpm)
          [ -n "$url" ] && { ASSET_SOURCE=pattern; ASSET_URL="$url"; return; }
        fi
        if [ -n "$(platform_field "${base_key}-rpm" url)" ]; then
          ASSET_SOURCE=manifest; ASSET_KEY="${base_key}-rpm"; return
        fi
        ;;
    esac
  fi

  ASSET_SOURCE=manifest; ASSET_KEY="$base_key"
}

download_asset() {
  local key
  key="$1"
  ASSET_URL=$(platform_field "$key" url)
  ASSET_SIG=$(platform_field "$key" signature)
  [ -n "$ASSET_URL" ] || err "no release asset for platform '$key' — is $CFG_PROJECT_NAME built for this OS/arch?"
  case "$ASSET_URL" in https://*) ;; *) err "asset URL is not https: $ASSET_URL" ;; esac

  ASSET_FILE="$WORK_DIR/$(basename "${ASSET_URL%%\?*}")"
  info "downloading $(basename "$ASSET_FILE")"
  curl_download_progress "$ASSET_URL" "$ASSET_FILE" || err "download failed: $ASSET_URL"
}

# .deb/.rpm assets found via the GitHub API aren't part of the signed Tauri
# updater manifest, so there's nothing to verify them against — same unsigned
# posture scripts/install.sh already has for these formats.
fetch_pattern_asset() {
  case "$ASSET_URL" in https://*) ;; *) err "asset URL is not https: $ASSET_URL" ;; esac
  ASSET_FILE="$WORK_DIR/$(basename "${ASSET_URL%%\?*}")"
  info "downloading $(basename "$ASSET_FILE")"
  curl_download_progress "$ASSET_URL" "$ASSET_FILE" \
    || err "download failed: $ASSET_URL (does this release actually publish this asset?)"
  warn "no manifest signature available for this asset — verifying via HTTPS only"
}

verify_signature() {
  if [ -z "$CFG_PUBKEY" ]; then
    warn "no pubkey configured — skipping signature verification"
    return
  fi
  have minisign || err "a pubkey is configured but minisign is not installed — refusing to install unverified"
  [ -n "$ASSET_SIG" ] || err "release manifest has no signature for this asset"

  have base64 || err "base64 is required for signature verification"
  printf '%s' "$ASSET_SIG" | base64 -d > "$ASSET_FILE.minisig" 2>/dev/null \
    || err "invalid base64 signature in updater manifest"
  minisign -V -P "$CFG_PUBKEY" -m "$ASSET_FILE" -x "$ASSET_FILE.minisig" \
    || err "signature verification FAILED — refusing to install"
  info "signature verified"
}

INSTALLED_FILES=""

# Extracts the .desktop/icon pair AppImages carry internally and registers
# them under the XDG user dirs, same layout as modrex's scripts/install.sh.
# $1 is the AppImage to extract from (must be executable); $2 is the path the
# binary will live at once installed, used as the desktop entry's Exec target.
integrate_appimage_desktop() {
  local extractable exec_path desktop_src icon_src icon_ext desktop_dest icon_dest
  extractable="$1"; exec_path="$2"
  ( cd "$WORK_DIR" && "$extractable" --appimage-extract >/dev/null 2>&1 ) \
    || { warn "could not extract desktop integration assets from the AppImage"; return; }
  [ -d "$WORK_DIR/squashfs-root" ] || return

  desktop_src=$(find "$WORK_DIR/squashfs-root" -maxdepth 1 -name '*.desktop' -print -quit)
  icon_src=$(find "$WORK_DIR/squashfs-root" -maxdepth 1 \( -name '*.png' -o -name '*.svg' \) -print -quit)
  [ -n "$desktop_src" ] && [ -n "$icon_src" ] || { warn "no .desktop/icon found inside the AppImage"; return; }
  icon_ext="${icon_src##*.}"

  mkdir -p "$HOME/.local/share/applications" "$HOME/.local/share/icons"
  desktop_dest="$HOME/.local/share/applications/$CFG_PROJECT_NAME.desktop"
  icon_dest="$HOME/.local/share/icons/$CFG_PROJECT_NAME.$icon_ext"
  cp "$icon_src" "$icon_dest"
  sed -e "s|^Exec=.*|Exec=$exec_path %U|" -e "s|^Icon=.*|Icon=$icon_dest|" "$desktop_src" > "$desktop_dest"
  have update-desktop-database && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1

  DESKTOP_FILES="$desktop_dest
$icon_dest"
}

# .deb/.rpm architecture metadata is already embedded in the package by the
# bundler — reading it back catches a wrong-arch asset without needing any
# manifest or config changes. $1 is the package's own reported arch string,
# $2/$3 are the expected tokens for x86_64/aarch64 (deb and rpm use different
# vocabularies: amd64/arm64 vs x86_64/aarch64).
check_package_arch() {
  local pkg_arch expected
  pkg_arch="$1"
  [ -n "$pkg_arch" ] || err "could not determine package architecture — refusing to install"
  case "$ARCH" in
    x86_64) expected="$2" ;;
    aarch64) expected="$3" ;;
  esac
  case "$pkg_arch" in
    "$expected"|all|noarch) return ;;
    *) err "package architecture '$pkg_arch' does not match this machine ($ARCH, expected '$expected')" ;;
  esac
}

# The GitHub-discovered .deb/.rpm comes from a separate API call than the
# Tauri updater manifest VERSION was read from — normally the same release,
# but not cross-checked by construction. A loose prefix match (rather than
# exact) tolerates rpm's "-1" release suffixes and similar formatting that
# don't indicate an actual version mismatch.
check_package_version() {
  local pkg_version
  pkg_version="$1"
  [ -n "$pkg_version" ] || { warn "could not determine package version — proceeding without a version check"; return; }
  # Separator-aware, not a bare prefix match: "1.2"* would wrongly accept a
  # package version of "1.20". Allows an rpm release suffix (-1) or a debian
  # epoch prefix (N:) around the exact version.
  case "$pkg_version" in
    "$VERSION"|"$VERSION"-*|*:"$VERSION"|*:"$VERSION"-*) ;;
    *) warn "package version '$pkg_version' does not match the release manifest version '$VERSION'" ;;
  esac
}

ensure_macos_signature() {
  local app_bundle signature_error
  app_bundle="$1"
  signature_error="$WORK_DIR/codesign-verify.err"

  have codesign || err "codesign is required to install macOS app bundles"

  if codesign --verify --deep --strict "$app_bundle" 2>"$signature_error"; then
    return
  fi

  # A bundle seal that exists but fails verification is a broken release
  # artifact; replacing it would hide the real failure.
  if [ -e "$app_bundle/Contents/_CodeSignature/CodeResources" ]; then
    cat "$signature_error" >&2
    err "macOS app bundle has an invalid code signature"
  fi

  info "applying a local ad-hoc code signature"
  codesign --force --sign - --timestamp=none "$app_bundle" \
    || err "failed to apply a local ad-hoc code signature"
  codesign --verify --deep --strict "$app_bundle" \
    || err "ad-hoc code signature verification failed"
}

install_asset() {
  local dest app_bundle app_count staged pkg_name macos_executable
  DESKTOP_FILES=""
  # .deb/.rpm installs put their binary on the system PATH themselves via the
  # package manager — adding $INSTALL_DIR (which they never touch) would just
  # be a misleading no-op entry in the user's shell rc.
  case "$ASSET_FILE" in *.deb|*.rpm) NEEDS_PATH_UPDATE=0 ;; *) NEEDS_PATH_UPDATE=1 ;; esac
  mkdir -p "$INSTALL_DIR"
  case "$ASSET_FILE" in
    *.AppImage)
      dest="$INSTALL_DIR/$CFG_PROJECT_NAME"
      staged="$INSTALL_DIR/.${CFG_PROJECT_NAME}.new.$$"
      cp "$ASSET_FILE" "$staged"; chmod +x "$staged"
      [ "$OS" = linux ] && integrate_appimage_desktop "$staged" "$dest"
      mv -f "$staged" "$dest"
      INSTALLED_FILES="$dest"
      [ -n "$DESKTOP_FILES" ] && INSTALLED_FILES="$INSTALLED_FILES
$DESKTOP_FILES"
      ;;
    *.app.tar.gz)
      tar -xzf "$ASSET_FILE" -C "$WORK_DIR"
      app_count=$(find "$WORK_DIR" -maxdepth 1 -name '*.app' | wc -l)
      [ "$app_count" -eq 1 ] || err "expected exactly one .app bundle in the archive, found $app_count"
      app_bundle=$(find "$WORK_DIR" -maxdepth 1 -name '*.app')
      # Validated on the extracted bundle before it ever replaces the working
      # install — catching a bad bundle here means the old version (and its
      # backup) is never touched, instead of being discarded first and only
      # discovering the problem afterward.
      [ -x "$app_bundle/Contents/MacOS/$CFG_MACOS_EXECUTABLE_NAME" ] \
        || err "macOS executable not found at Contents/MacOS/$CFG_MACOS_EXECUTABLE_NAME (set macos_executable_name in config if it differs from project_name)"
      ensure_macos_signature "$app_bundle"

      # Destination name is CFG_MACOS_BUNDLE_NAME, not the archive's own
      # filename, so it always matches what safe_remove is willing to touch.
      dest="$HOME/Applications/$CFG_MACOS_BUNDLE_NAME.app"
      mkdir -p "$HOME/Applications"
      rm -rf "$dest.old"
      [ -e "$dest" ] && mv "$dest" "$dest.old"
      if mv "$app_bundle" "$dest"; then
        rm -rf "$dest.old"
      else
        [ -e "$dest.old" ] && mv "$dest.old" "$dest"
        err "failed to install new app bundle; previous version restored"
      fi
      macos_executable="$dest/Contents/MacOS/$CFG_MACOS_EXECUTABLE_NAME"
      ln -sf "$macos_executable" "$INSTALL_DIR/$CFG_PROJECT_NAME"
      INSTALLED_FILES="$dest
$INSTALL_DIR/$CFG_PROJECT_NAME"
      ;;
    *.deb)
      have dpkg-deb || err "dpkg-deb is required to inspect .deb packages"
      check_package_arch "$(dpkg-deb -f "$ASSET_FILE" Architecture 2>/dev/null)" amd64 arm64
      pkg_name=$(dpkg-deb -f "$ASSET_FILE" Package) || err "could not read package name from $ASSET_FILE"
      [ "$pkg_name" = "$CFG_DEB_PACKAGE_NAME" ] \
        || err "unexpected Debian package name '$pkg_name' (expected '$CFG_DEB_PACKAGE_NAME' — set deb_package_name in config if this is intentional)"
      check_package_version "$(dpkg-deb -f "$ASSET_FILE" Version 2>/dev/null)"
      require_sudo
      if [ "$PKG_MANAGER" = apt ]; then
        info "installing via apt-get (sudo required)"
        $SUDO apt-get install -y "$ASSET_FILE"
        INSTALLED_FILES="pkg:apt:$pkg_name"
      else
        have dpkg || err "*.deb asset selected but dpkg not found"
        info "installing via dpkg (sudo required)"
        $SUDO dpkg -i "$ASSET_FILE"
        INSTALLED_FILES="pkg:dpkg:$pkg_name"
      fi
      ;;
    *.rpm)
      have rpm || err "rpm is required to inspect .rpm packages"
      check_package_arch "$(rpm -qp --queryformat '%{ARCH}' "$ASSET_FILE" 2>/dev/null)" x86_64 aarch64
      pkg_name=$(rpm -qp --queryformat '%{NAME}' "$ASSET_FILE") || err "could not read package name from $ASSET_FILE"
      [ "$pkg_name" = "$CFG_RPM_PACKAGE_NAME" ] \
        || err "unexpected RPM package name '$pkg_name' (expected '$CFG_RPM_PACKAGE_NAME' — set rpm_package_name in config if this is intentional)"
      check_package_version "$(rpm -qp --queryformat '%{VERSION}' "$ASSET_FILE" 2>/dev/null)"
      require_sudo
      case "$PKG_MANAGER" in
        dnf)
          info "installing via dnf (sudo required)"
          $SUDO dnf install -y "$ASSET_FILE"
          INSTALLED_FILES="pkg:dnf:$pkg_name"
          ;;
        zypper)
          info "installing via zypper (sudo required)"
          $SUDO zypper --non-interactive install "$ASSET_FILE"
          INSTALLED_FILES="pkg:zypper:$pkg_name"
          ;;
        *)
          info "installing via rpm (sudo required)"
          $SUDO rpm -U "$ASSET_FILE"
          INSTALLED_FILES="pkg:rpm:$pkg_name"
          ;;
      esac
      ;;
    *)
      err "don't know how to install asset type: $ASSET_FILE"
      ;;
  esac
}

update_path() {
  local rc line
  [ "$CFG_ADD_TO_PATH" = "true" ] || return
  case ":$PATH:" in *":$INSTALL_DIR:"*) return ;; esac
  case "${SHELL:-}" in
    */fish)
      rc="$HOME/.config/fish/config.fish"
      mkdir -p "$(dirname "$rc")"
      line="fish_add_path \"$INSTALL_DIR\"  # added by $CFG_PROJECT_NAME installer"
      ;;
    */zsh) rc="$HOME/.zshrc"; line="export PATH=\"$INSTALL_DIR:\$PATH\"  # added by $CFG_PROJECT_NAME installer" ;;
    */bash) rc="$HOME/.bashrc"; line="export PATH=\"$INSTALL_DIR:\$PATH\"  # added by $CFG_PROJECT_NAME installer" ;;
    *) rc="$HOME/.profile"; line="export PATH=\"$INSTALL_DIR:\$PATH\"  # added by $CFG_PROJECT_NAME installer" ;;
  esac
  grep -qF "$INSTALL_DIR" "$rc" 2>/dev/null || { echo "$line" >> "$rc"; info "added $INSTALL_DIR to PATH in $rc (restart your shell)"; }
}

write_uninstall_manifest() {
  local tmp
  tmp="$CFG_UNINSTALL_MANIFEST.tmp.$$"
  mkdir -p "$(dirname "$CFG_UNINSTALL_MANIFEST")"
  printf '%s\n' "$INSTALLED_FILES" | jq -R '.' | jq -s \
    --arg project "$CFG_PROJECT_NAME" --arg version "$VERSION" --arg install_dir "$INSTALL_DIR" \
    '{project:$project, version:$version, install_dir:$install_dir, files:map(select(length>0))}' \
    > "$tmp"
  mv -f "$tmp" "$CFG_UNINSTALL_MANIFEST"
}

# Exact matches only — every path this script can ever install to is a fixed,
# known value, so there's no need for a wildcard (a "$INSTALL_DIR"/* prefix
# match is a textual match, not a resolved-path check: a manifest entry like
# "$INSTALL_DIR/../../victim" passes that test even though rm then acts on
# the escaped path). The uninstall manifest is treated as data, not as
# trusted rm targets.
safe_remove() {
  case "$1" in
    "$INSTALL_DIR/$CFG_PROJECT_NAME"| \
    "$HOME/Applications/$CFG_MACOS_BUNDLE_NAME.app"| \
    "$HOME/.local/share/applications/$CFG_PROJECT_NAME.desktop"| \
    "$HOME/.local/share/icons/$CFG_PROJECT_NAME.png"| \
    "$HOME/.local/share/icons/$CFG_PROJECT_NAME.svg")
      rm -rf -- "$1"; info "removed $1" ;;
    # A mismatch here almost always means install_dir/macos_bundle_name
    # changed since install, not that the manifest was tampered with — but
    # either way, silently treating it as done (and then deleting the
    # uninstall record) would leave the actual install behind untracked.
    *) err "refusing to remove unexpected path: $1 (uninstall state may be stale — does install_dir/macos_bundle_name still match what was installed?)" ;;
  esac
}

remove_package() {
  local manager name expected
  manager="${1#pkg:}"; manager="${manager%%:*}"
  name="${1##*:}"
  # install_asset already validated the real package name equals the
  # configured expected name before ever installing it, so the manifest
  # recording anything else means either a modified manifest or install_asset
  # was bypassed — either way, requiring the same match here closes the gap
  # where a low-privilege local write becomes a root-level package removal
  # once it rides along with the sudo this uninstall already runs under.
  case "$manager" in
    apt|dpkg) expected="$CFG_DEB_PACKAGE_NAME" ;;
    dnf|zypper|rpm) expected="$CFG_RPM_PACKAGE_NAME" ;;
    *) err "unrecognized entry in uninstall manifest: $1" ;;
  esac
  [ "$name" = "$expected" ] \
    || err "refusing to remove package '$name': does not match the configured package name '$expected'"
  require_sudo
  case "$manager" in
    apt)    $SUDO apt-get remove -y "$name" ;;
    dnf)    $SUDO dnf remove -y "$name" ;;
    zypper) $SUDO zypper --non-interactive remove "$name" ;;
    dpkg)   $SUDO dpkg -r "$name" ;;
    rpm)    $SUDO rpm -e "$name" ;;
  esac
  info "removed package $name via $manager"
}

do_uninstall() {
  local manifest_project manifest_install_dir files_list
  [ -f "$CFG_UNINSTALL_MANIFEST" ] || err "no install record found at $CFG_UNINSTALL_MANIFEST"

  manifest_project=$(jq -er '.project' "$CFG_UNINSTALL_MANIFEST") \
    || err "uninstall manifest is corrupt: $CFG_UNINSTALL_MANIFEST"
  [ "$manifest_project" = "$CFG_PROJECT_NAME" ] \
    || err "uninstall manifest belongs to '$manifest_project', not '$CFG_PROJECT_NAME'"

  # Catches --install-dir or a config change since install with one clear
  # message, rather than letting every recorded path fail individually in
  # safe_remove further down.
  manifest_install_dir=$(jq -er '.install_dir' "$CFG_UNINSTALL_MANIFEST") \
    || err "uninstall manifest is corrupt: $CFG_UNINSTALL_MANIFEST"
  [ "$manifest_install_dir" = "$INSTALL_DIR" ] \
    || err "install_dir ('$INSTALL_DIR') differs from what was recorded at install time ('$manifest_install_dir') — uninstall would not find the real files. Re-run without --install-dir, or with the same install_dir used to install."

  confirm "Remove $CFG_PROJECT_NAME ($INSTALL_DIR/$CFG_PROJECT_NAME and related files)?" || err "aborted"

  # Written to a file rather than piped straight into the loop: a pipeline's
  # exit status is its last command's, so piping jq into a while-read loop would
  # silently treat a jq failure as "nothing to uninstall" and still report success.
  files_list="$WORK_DIR/uninstall-files"
  jq -r '.files[]' "$CFG_UNINSTALL_MANIFEST" > "$files_list" \
    || err "uninstall manifest is corrupt: $CFG_UNINSTALL_MANIFEST"

  info "removing $CFG_PROJECT_NAME"
  while IFS= read -r f; do
    case "$f" in
      pkg:*) remove_package "$f" ;;
      *) safe_remove "$f" ;;
    esac
  done < "$files_list"

  rm -f "$CFG_UNINSTALL_MANIFEST"

  if [ "$PURGE" -eq 1 ]; then
    confirm "Also remove settings, cache, and data (\$HOME/.config/$CFG_PROJECT_NAME, \$HOME/.cache/$CFG_PROJECT_NAME, \$HOME/.local/share/$CFG_PROJECT_NAME)?" \
      || err "aborted"
    for dir in "$HOME/.config/$CFG_PROJECT_NAME" "$HOME/.cache/$CFG_PROJECT_NAME" "$HOME/.local/share/$CFG_PROJECT_NAME"; do
      [ -d "$dir" ] || continue
      rm -rf -- "$dir"
      info "removed $dir"
    done
  fi

  info "done. (PATH entry left in your shell rc file — remove manually if desired)"
}

main() {
  local uninstall_hint
  if [ "$UNINSTALL" -eq 1 ]; then do_uninstall; exit 0; fi
  [ -z "$VERSION_OVERRIDE" ] || err "--version is not supported yet (this installer always installs latest)"

  detect_platform
  detect_pkg_manager
  fetch_manifest
  VERSION=$(json_get version)
  [ -n "$VERSION" ] && [ "$VERSION" != "null" ] || err "manifest did not report a version"

  resolve_asset_source
  if [ "$ASSET_SOURCE" = manifest ]; then
    info "resolved platform: $ASSET_KEY"
    ASSET_URL=$(platform_field "$ASSET_KEY" url)
  else
    info "resolved via direct package URL ($PKG_MANAGER)"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would install $CFG_PROJECT_NAME $VERSION"
    echo "  asset:   $ASSET_URL"
    echo "  target:  $INSTALL_DIR"
    exit 0
  fi

  if [ "$ASSET_SOURCE" = manifest ]; then
    download_asset "$ASSET_KEY"
    verify_signature
  else
    fetch_pattern_asset
  fi
  install_asset
  [ "$NEEDS_PATH_UPDATE" -eq 1 ] && update_path
  write_uninstall_manifest

  info "$CFG_PROJECT_NAME $VERSION installed to $INSTALL_DIR"
  if [ -n "$CFG_POST_INSTALL_CMD" ] && ! sh -c "$CFG_POST_INSTALL_CMD"; then
    warn "post-install command failed: $CFG_POST_INSTALL_CMD"
  fi

  # $0 is the literal string "sh" when piped via curl, so a local-file
  # invocation hint is only meaningful when $0 really is a script on disk.
  if [ -n "$CFG_INSTALL_URL" ]; then
    uninstall_hint="curl -fsSL $CFG_INSTALL_URL | sh -s -- --uninstall"
  elif [ -f "$0" ]; then
    uninstall_hint="sh $0 --uninstall"
  else
    uninstall_hint="re-run this installer with --uninstall"
  fi
  echo ""
  info "Launch $CFG_PROJECT_NAME from your app menu, or run '$CFG_PROJECT_NAME'."
  info "Uninstall: $uninstall_hint"
}

main "$@"
