#!/bin/sh
# Not meant to be curled directly: a project's own endpoint fetches this file
# plus its install.config.json and prepends the config as CFG_* env vars.
set -eu

DRY_RUN=0
UNINSTALL=0
ASSUME_YES=0
PURGE=0
VERSION_OVERRIDE=""
FORCE_FORMAT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    --purge) PURGE=1 ;;
    --appimage)
      [ -z "$FORCE_FORMAT" ] || { echo "error: only one of --appimage/--deb/--rpm may be given" >&2; exit 1; }
      FORCE_FORMAT=appimage ;;
    --deb)
      [ -z "$FORCE_FORMAT" ] || { echo "error: only one of --appimage/--deb/--rpm may be given" >&2; exit 1; }
      FORCE_FORMAT=deb ;;
    --rpm)
      [ -z "$FORCE_FORMAT" ] || { echo "error: only one of --appimage/--deb/--rpm may be given" >&2; exit 1; }
      FORCE_FORMAT=rpm ;;
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
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  echo "error: do not run this installer with sudo: it installs into your own home directory and asks for sudo itself when a package manager needs it" >&2
  exit 1
fi
[ "$PURGE" -eq 1 ] && [ "$UNINSTALL" -eq 0 ] && { echo "error: --purge only applies to --uninstall" >&2; exit 1; }
[ -n "$FORCE_FORMAT" ] && [ "$UNINSTALL" -eq 1 ] && { echo "error: --appimage/--deb/--rpm only apply when installing" >&2; exit 1; }

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
CFG_MACOS_EXECUTABLE_NAME="${CFG_MACOS_EXECUTABLE_NAME:-}"
COMMAND_NAME="${CFG_COMMAND_NAME:-$CFG_PROJECT_NAME}"
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
case "$COMMAND_NAME" in
  .|..) echo "error: invalid command_name: $COMMAND_NAME" >&2; exit 1 ;;
  *[!A-Za-z0-9._-]*) echo "error: command_name may contain only letters, digits, '.', '_', '-'" >&2; exit 1 ;;
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
  '') ;;
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
[ -z "$CFG_PUBKEY" ] || have base64 || err "base64 is required for signature verification"

# Flattens a JSON document to one "path<TAB>value" line per scalar, arrays
# indexed numerically. Deliberately narrow: only \" \\ \/ are decoded, every
# other escape (\n \t \uXXXX ...) is kept as its escaped text, and raw control
# characters are rejected, so a value can never contain a newline or a tab and
# forge another line or split a path. Keys are joined with "." — the paths the
# engine looks up never contain one. Malformed or truncated input exits 2.
json_flat() {
  awk '
    function ws() { while (substr(s, i, 1) ~ /[ \t\r\n]/) i++ }
    function str(   c, r) {
      i++; r = ""
      while ((c = substr(s, i, 1)) != "\"") {
        if (c == "" || c ~ /[\001-\037]/) exit 2
        if (c == "\\") {
          i++; c = substr(s, i, 1)
          if (c == "u") {
            if (substr(s, i + 1, 4) !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) exit 2
            c = "\\u" substr(s, i + 1, 4); i += 4
          } else if (c ~ /^[bfnrt]$/) c = "\\" c
          else if (c != "\"" && c != "\\" && c != "/") exit 2
        }
        r = r c; i++
      }
      i++; return r
    }
    function val(p,   c, k, n) {
      ws(); c = substr(s, i, 1)
      if (c == "{") {
        i++; ws()
        while (substr(s, i, 1) != "}") {
          if (substr(s, i, 1) != "\"") exit 2
          k = str(); ws(); if (substr(s, i, 1) != ":") exit 2
          i++; val(p == "" ? k : p "." k); ws()
          if (substr(s, i, 1) == ",") { i++; ws(); if (substr(s, i, 1) == "}") exit 2 } else if (substr(s, i, 1) != "}") exit 2
        }
        i++
      } else if (c == "[") {
        i++; n = 0; ws()
        while (substr(s, i, 1) != "]") {
          val(p "." n); n++; ws()
          if (substr(s, i, 1) == ",") { i++; ws(); if (substr(s, i, 1) == "]") exit 2 } else if (substr(s, i, 1) != "]") exit 2
        }
        i++
      } else if (c == "\"") print p "\t" str()
      else {
        n = ""; while (substr(s, i, 1) ~ /[-+.0-9A-Za-z]/) { n = n substr(s, i, 1); i++ }
        if (n !~ /^(true|false|null|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?)$/) exit 2
        print p "\t" n
      }
    }
    { s = s $0 "\n" }
    END { i = 1; val(""); ws(); if (i <= length(s)) exit 2 }
  ' "$1"
}

flat_get() { awk -F '\t' -v k="$2" '$1 == k { v = substr($0, length(k) + 2); f = 1 } END { if (f) print v }' "$1"; }

# In the common curl-pipe-to-sh invocation, fd 0 (stdin) is the piped script
# source, not the terminal — reading a prompt from it would consume script
# bytes as the answer. /dev/tty is the real terminal regardless of how stdin
# is wired.
confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local reply=""
  if [ -t 0 ]; then
    printf '%s [y/N] ' "$1" >&2
    read -r reply || reply=""
  elif (: </dev/tty) 2>/dev/null; then
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

# Asks the user to pick between a resolved native package and the AppImage
# alternative, when both exist for this platform. Sets VARIANT_CHOICE to
# "native" or "appimage". Same /dev/tty fallback as confirm() so it still
# works when stdin is the piped curl|sh script body — but unlike confirm(),
# no reachable terminal at all just silently defaults to native rather than
# erroring, since a scripted/non-interactive install must never hang or fail
# on this.
VARIANT_CHOICE=""
choose_variant() {
  local ext manager reply read_from_stdin
  ext="$1"; manager="$2"
  if [ -t 0 ]; then
    read_from_stdin=1
  elif (: </dev/tty) 2>/dev/null; then
    read_from_stdin=0
  else
    VARIANT_CHOICE=native
    return
  fi
  {
    printf '\n%s %s — choose install format:\n\n' "$CFG_PROJECT_NAME" "$VERSION"
    printf '  1) .%s (%s)  [default]\n' "$ext" "$manager"
    printf '  2) .AppImage\n'
    printf 'Choice [1]: '
  } >&2
  if [ "$read_from_stdin" -eq 1 ]; then
    read -r reply || reply=""
  else
    read -r reply </dev/tty || reply=""
  fi
  case "$reply" in
    2) VARIANT_CHOICE=appimage ;;
    *) VARIANT_CHOICE=native ;;
  esac
}

# True (and prompts) only when a native package was actually found, an
# AppImage alternative also exists, and neither -y nor an explicit
# --deb/--rpm/--appimage flag already settled the question.
APPIMAGE_KEY=""
maybe_prefer_appimage() {
  local base_key ext manager
  base_key="$1"; ext="$2"; manager="$3"
  [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] || return 1
  APPIMAGE_KEY=$(appimage_key "$base_key")
  [ -n "$APPIMAGE_KEY" ] || return 1
  choose_variant "$ext" "$manager"
  [ "$VARIANT_CHOICE" = appimage ]
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

# Native package manager, when present, is preferred over a raw AppImage.
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
  json_flat "$WORK_DIR/manifest.json" > "$WORK_DIR/manifest.flat" \
    || err "release manifest is not valid JSON: $CFG_MANIFEST_URL"
}

platform_field() { flat_get "$WORK_DIR/manifest.flat" "platforms.$1.$2"; }

# Tauri's bare {os}-{arch} key is the AppImage, but a project that publishes
# per-format variants (…-deb/…-rpm/…-appimage) may omit the bare key entirely.
# Resolve to whichever key actually carries the AppImage, or empty if neither.
appimage_key() {
  if [ -n "$(platform_field "$1" url)" ]; then
    echo "$1"
  elif [ -n "$(platform_field "${1}-appimage" url)" ]; then
    echo "${1}-appimage"
  fi
}

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

# Resolves a --appimage/--deb/--rpm flag directly, bypassing all
# auto-detection (and the interactive prompt) since the user already
# answered the question on the command line.
resolve_forced_format() {
  local base_key
  base_key="$1"
  case "$FORCE_FORMAT" in
    appimage)
      [ "$OS" = linux ] || err "--appimage is only meaningful on Linux"
      ASSET_KEY=$(appimage_key "$base_key")
      [ -n "$ASSET_KEY" ] || err "no AppImage asset published for $base_key"
      ;;
    deb|rpm)
      [ "$OS" = linux ] || err "--$FORCE_FORMAT is only meaningful on Linux"
      ASSET_KEY="${base_key}-${FORCE_FORMAT}"
      [ -n "$(platform_field "$ASSET_KEY" url)" ] || err "no .$FORCE_FORMAT asset published for $CFG_PROJECT_NAME (manifest key '$ASSET_KEY')"
      ;;
  esac
}

# Precedence: an explicit --appimage/--deb/--rpm flag wins outright; then an
# explicit preferred_variant manifest key; then, on Linux with a detected
# package manager, the manifest's .deb/.rpm key — offered interactively
# against the AppImage alternative when both exist (see choose_variant); then
# the bare {os}-{arch} manifest key (AppImage on Linux, .app on macOS). The
# manifest is the only source of assets: a package it does not declare is not
# installed.
resolve_asset_source() {
  local base_key variant ext
  base_key="${OS}-${ARCH}"

  if [ -n "$FORCE_FORMAT" ]; then
    resolve_forced_format "$base_key"
    return
  fi

  variant=$(preferred_variant_for "$OS")
  if [ -n "$variant" ] && [ -n "$(platform_field "${base_key}-${variant}" url)" ]; then
    ASSET_KEY="${base_key}-${variant}"; return
  fi
  # Tauri's bare Linux key is the AppImage. Honor an explicit AppImage
  # preference before native package discovery when no suffixed alias exists.
  if [ "$OS:$variant" = "linux:appimage" ] && [ -n "$(platform_field "$base_key" url)" ]; then
    ASSET_KEY="$base_key"; return
  fi

  case "$PKG_MANAGER" in apt) ext=deb ;; dnf|zypper) ext=rpm ;; *) ext="" ;; esac
  if [ -n "$ext" ] && [ -n "$(platform_field "${base_key}-${ext}" url)" ]; then
    if maybe_prefer_appimage "$base_key" "$ext" "$PKG_MANAGER"; then ASSET_KEY="$APPIMAGE_KEY"; else ASSET_KEY="${base_key}-${ext}"; fi
    return
  fi

  ASSET_KEY="$base_key"
  if [ "$OS" = linux ]; then
    variant=$(appimage_key "$base_key")
    if [ -n "$variant" ]; then
      ASSET_KEY="$variant"
    fi
  fi
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

# Runs before anything is downloaded: a missing verifier is knowable upfront,
# and installing it needs the same consent and sudo the native package path
# already asks for. Nothing is installed without the prompt (or -y).
ensure_minisign() {
  local install
  [ -n "$CFG_PUBKEY" ] && [ "$DRY_RUN" -eq 0 ] || return 0
  have minisign && return 0
  case "$PKG_MANAGER" in
    apt) install="apt-get install -y minisign" ;;
    dnf) install="dnf install -y minisign" ;;
    zypper) install="zypper --non-interactive install minisign" ;;
    *) if have pacman; then install="pacman -S --noconfirm minisign"; elif have brew; then install="brew install minisign"; else install=""; fi ;;
  esac
  [ -n "$install" ] || err "minisign is required to verify $CFG_PROJECT_NAME's signature (e.g. 'apt install minisign' / 'dnf install minisign' / 'pacman -S minisign' / 'brew install minisign')"
  info "minisign is required to verify $CFG_PROJECT_NAME's signature; it can be installed with: $install"
  confirm "Install minisign now?" || err "minisign is required to verify $CFG_PROJECT_NAME's signature — install it and re-run"
  case "$install" in brew*) ;; *) require_sudo ;; esac
  $SUDO $install || err "installing minisign failed — install it manually and re-run"
  have minisign || err "minisign is still not on PATH after installation — install it manually and re-run"
}

verify_signature() {
  if [ -z "$CFG_PUBKEY" ]; then
    warn "no pubkey configured — skipping signature verification"
    return
  fi
  [ -n "$ASSET_SIG" ] || err "release manifest has no signature for this asset"

  printf '%s' "$ASSET_SIG" | base64 -d > "$ASSET_FILE.minisig" 2>/dev/null \
    || err "invalid base64 signature in updater manifest"
  minisign -V -P "$CFG_PUBKEY" -m "$ASSET_FILE" -x "$ASSET_FILE.minisig" \
    || err "signature verification FAILED — refusing to install"
  info "signature verified"
}

INSTALLED_FILES=""

# Extracts the .desktop/icon pair AppImages carry internally and registers
# them under the XDG user dirs.
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

# The package's own version is compared with the manifest's: a mismatch means
# the manifest points at a package from another release. A loose prefix match
# (rather than exact) tolerates rpm's "-1" release suffixes and similar
# formatting that don't indicate an actual version mismatch.
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
  local dest app_bundle app_count staged pkg_name macos_executable f
  DESKTOP_FILES=""
  INSTALLED_PATH=""
  PROVIDED_BINS=""
  case "$ASSET_FILE" in *.deb|*.rpm) ;; *) mkdir -p "$INSTALL_DIR" ;; esac
  case "$ASSET_FILE" in
    *.AppImage)
      have fusermount || have fusermount3 \
        || warn "neither fusermount nor fusermount3 is installed; the AppImage may not start until your distribution's fuse package is installed"
      dest="$INSTALL_DIR/$COMMAND_NAME"
      staged="$INSTALL_DIR/.${COMMAND_NAME}.new.$$"
      cp "$ASSET_FILE" "$staged"; chmod +x "$staged"
      [ "$OS" = linux ] && integrate_appimage_desktop "$staged" "$dest"
      mv -f "$staged" "$dest"
      INSTALLED_PATH="$dest"
      INSTALLED_FILES="$dest"
      [ -n "$DESKTOP_FILES" ] && INSTALLED_FILES="$INSTALLED_FILES
$DESKTOP_FILES"
      ;;
    *.app.tar.gz)
      tar -xzf "$ASSET_FILE" -C "$WORK_DIR"
      app_count=$(find "$WORK_DIR" -maxdepth 1 -name '*.app' | wc -l)
      [ "$app_count" -eq 1 ] || err "expected exactly one .app bundle in the archive, found $app_count"
      app_bundle=$(find "$WORK_DIR" -maxdepth 1 -name '*.app')
      macos_executable="$CFG_MACOS_EXECUTABLE_NAME"
      [ -n "$macos_executable" ] \
        || macos_executable=$(plutil -extract CFBundleExecutable raw -o - "$app_bundle/Contents/Info.plist" 2>/dev/null) \
        || macos_executable=$(defaults read "$app_bundle/Contents/Info" CFBundleExecutable 2>/dev/null) \
        || err "could not read CFBundleExecutable from the app bundle (set macos_executable_name in config)"
      # Validated on the extracted bundle before it ever replaces the working
      # install — catching a bad bundle here means the old version (and its
      # backup) is never touched, instead of being discarded first and only
      # discovering the problem afterward.
      [ -x "$app_bundle/Contents/MacOS/$macos_executable" ] \
        || err "macOS executable not found at Contents/MacOS/$macos_executable"
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
      ln -sf "$dest/Contents/MacOS/$macos_executable" "$INSTALL_DIR/$COMMAND_NAME"
      INSTALLED_PATH="$INSTALL_DIR/$COMMAND_NAME"
      INSTALLED_FILES="$dest
$INSTALL_DIR/$COMMAND_NAME"
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
      PROVIDED_BINS=$(dpkg -L "$pkg_name" 2>/dev/null | grep -E '^/usr/bin/[^/]+$' || true)
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
      PROVIDED_BINS=$(rpm -ql "$pkg_name" 2>/dev/null | grep -E '^/usr/bin/[^/]+$' || true)
      ;;
    *)
      err "don't know how to install asset type: $ASSET_FILE"
      ;;
  esac
  for f in $PROVIDED_BINS; do
    if [ "$f" = "/usr/bin/$COMMAND_NAME" ]; then INSTALLED_PATH="$f"; fi
  done
}

command_copies() {
  local rest d p seen q
  rest="$PATH:"; seen=""
  while [ -n "$rest" ]; do
    d="${rest%%:*}"; rest="${rest#*:}"; p="$d/$COMMAND_NAME"
    [ -n "$d" ] && [ -x "$p" ] && [ ! -d "$p" ] || continue
    for q in $seen; do [ "$q" -ef "$p" ] && continue 2; done
    seen="$seen $p"; printf '%s\n' "$p"
  done
}

load_record() {
  : > "$WORK_DIR/record.flat"
  [ -f "$CFG_UNINSTALL_MANIFEST" ] || return 0
  json_flat "$CFG_UNINSTALL_MANIFEST" > "$WORK_DIR/record.flat" || { : > "$WORK_DIR/record.flat"; return 1; }
}
record_get() { flat_get "$WORK_DIR/record.flat" "$1"; }
recorded_files() { awk -F '\t' '$1 ~ /^files\.[0-9]+$/ { print substr($0, index($0, "\t") + 1) }' "$WORK_DIR/record.flat"; }

recorded() {
  local owner
  recorded_files | grep -qxF -- "$1" && return 0
  owner=$(dpkg -S "$1" 2>/dev/null | sed 's/[,:].*//' | head -n 1)
  [ -n "$owner" ] || owner=$(rpm -qf --queryformat '%{NAME}' "$1" 2>/dev/null || true)
  [ -n "$owner" ] && recorded_files | sed -n 's/^pkg:[a-z]*://p' | grep -qxF -- "$owner"
}

owner_label() {
  if recorded "$1"; then echo "recorded by this installer"; else echo "not installed by this installer"; fi
}

report_install() {
  local manager resolved p
  case "$INSTALLED_FILES" in
    pkg:*)
      manager="${INSTALLED_FILES#pkg:}"; manager="${manager%%:*}"
      info "installed $CFG_PROJECT_NAME $VERSION via $manager (provides: $(printf '%s' "$PROVIDED_BINS" | tr '\n' ' '))"
      [ -n "$INSTALLED_PATH" ] || warn "this package does not provide a '$COMMAND_NAME' command"
      ;;
    *) info "installed $INSTALLED_PATH" ;;
  esac
  resolved=$(command_copies | head -n 1)
  if [ -n "$INSTALLED_PATH" ] && [ -n "$resolved" ] && [ "$resolved" -ef "$INSTALLED_PATH" ]; then
    info "'$COMMAND_NAME' is available in this terminal"
  elif [ -n "$resolved" ]; then
    warn "'$COMMAND_NAME' currently runs $resolved ($(owner_label "$resolved")), not the copy just installed"
  elif [ -n "$INSTALLED_PATH" ]; then
    info "'$COMMAND_NAME' is not on your PATH in this terminal. Launch $CFG_PROJECT_NAME from your application menu, or use it as a terminal command by adding $INSTALL_DIR to your shell's PATH, or by exposing it system-wide:"
    info "  sudo ln -s $INSTALLED_PATH /usr/local/bin/$COMMAND_NAME"
  fi
  command_copies | while IFS= read -r p; do
    [ -n "$INSTALLED_PATH" ] && [ "$p" -ef "$INSTALLED_PATH" ] && continue
    warn "another '$COMMAND_NAME' is on PATH: $p ($(owner_label "$p"))"
  done
  if recorded_files | grep -q '^pkg:' && recorded_files | grep -q '^/'; then
    warn "$CFG_PROJECT_NAME is installed both as a package and in $INSTALL_DIR; --uninstall removes both"
  fi
}

target_present() {
  case "$1" in
    pkg:apt:*|pkg:dpkg:*) dpkg-query -W -f='${Status}' "${1##*:}" 2>/dev/null | grep -q 'install ok installed' ;;
    pkg:*) rpm -q "${1##*:}" >/dev/null 2>&1 ;;
    *) [ -e "$1" ] || [ -L "$1" ] ;;
  esac
}

json_string() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

write_uninstall_manifest() {
  local tmp f sep
  tmp="$CFG_UNINSTALL_MANIFEST.tmp.$$"
  mkdir -p "$(dirname "$CFG_UNINSTALL_MANIFEST")"
  load_record || true
  {
    if [ "$(record_get project)" = "$CFG_PROJECT_NAME" ] && [ "$(record_get install_dir)" = "$INSTALL_DIR" ]; then
      recorded_files | while IFS= read -r f; do
        if target_present "$f"; then printf '%s\n' "$f"; fi
      done
    fi
    printf '%s\n' "$INSTALLED_FILES"
  } | grep -v '^$' | sort -u > "$tmp.files"
  ! LC_ALL=C grep -q '[[:cntrl:]]' "$tmp.files" || err "cannot record a path containing control characters"
  {
    printf '{"project":%s,"version":%s,"install_dir":%s,"files":[' \
      "$(json_string "$CFG_PROJECT_NAME")" "$(json_string "$VERSION")" "$(json_string "$INSTALL_DIR")"
    sep=""
    while IFS= read -r f; do printf '%s%s' "$sep" "$(json_string "$f")"; sep=","; done < "$tmp.files"
    printf ']}\n'
  } > "$tmp"
  rm -f "$tmp.files"
  mv -f "$tmp" "$CFG_UNINSTALL_MANIFEST"
  load_record
}

# Exact matches only — every path this script can ever install to is a fixed,
# known value, so there's no need for a wildcard (a "$INSTALL_DIR"/* prefix
# match is a textual match, not a resolved-path check: a manifest entry like
# "$INSTALL_DIR/../../victim" passes that test even though rm then acts on
# the escaped path). The uninstall manifest is treated as data, not as
# trusted rm targets.
safe_remove() {
  case "$1" in
    "$INSTALL_DIR/$COMMAND_NAME"| \
    "$INSTALL_DIR/$CFG_PROJECT_NAME"| \
    "$HOME/Applications/$CFG_MACOS_BUNDLE_NAME.app"| \
    "$HOME/.local/share/applications/$CFG_PROJECT_NAME.desktop"| \
    "$HOME/.local/share/icons/$CFG_PROJECT_NAME.png"| \
    "$HOME/.local/share/icons/$CFG_PROJECT_NAME.svg")
      if [ -e "$1" ] || [ -L "$1" ]; then rm -rf -- "$1"; info "removed $1"; else info "already removed: $1"; fi ;;
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
  load_record || err "uninstall manifest is corrupt: $CFG_UNINSTALL_MANIFEST"

  manifest_project=$(record_get project)
  [ -n "$manifest_project" ] || err "uninstall manifest is corrupt: $CFG_UNINSTALL_MANIFEST"
  [ "$manifest_project" = "$CFG_PROJECT_NAME" ] \
    || err "uninstall manifest belongs to '$manifest_project', not '$CFG_PROJECT_NAME'"

  # Catches --install-dir or a config change since install with one clear
  # message, rather than letting every recorded path fail individually in
  # safe_remove further down.
  manifest_install_dir=$(record_get install_dir)
  [ "$manifest_install_dir" = "$INSTALL_DIR" ] \
    || err "install_dir ('$INSTALL_DIR') differs from what was recorded at install time ('$manifest_install_dir') — uninstall would not find the real files. Re-run without --install-dir, or with the same install_dir used to install."

  confirm "Remove $CFG_PROJECT_NAME ($INSTALL_DIR/$COMMAND_NAME and related files)?" || err "aborted"

  files_list="$WORK_DIR/uninstall-files"
  recorded_files > "$files_list"

  info "removing $CFG_PROJECT_NAME"
  while IFS= read -r f; do
    case "$f" in
      pkg:*) if target_present "$f"; then remove_package "$f"; else info "already removed: ${f##*:}"; fi ;;
      *) safe_remove "$f" ;;
    esac
  done < "$files_list"

  rm -f "$CFG_UNINSTALL_MANIFEST"
  report_leftovers

  if [ "$PURGE" -eq 1 ]; then
    confirm "Also remove settings, cache, and data (\$HOME/.config/$CFG_PROJECT_NAME, \$HOME/.cache/$CFG_PROJECT_NAME, \$HOME/.local/share/$CFG_PROJECT_NAME)?" \
      || err "aborted"
    for dir in "$HOME/.config/$CFG_PROJECT_NAME" "$HOME/.cache/$CFG_PROJECT_NAME" "$HOME/.local/share/$CFG_PROJECT_NAME"; do
      [ -d "$dir" ] || continue
      rm -rf -- "$dir"
      info "removed $dir"
    done
  fi

  info "done"
}

report_leftovers() {
  local rest d p
  rest="$PATH:"
  while [ -n "$rest" ]; do
    d="${rest%%:*}"; rest="${rest#*:}"; p="$d/$COMMAND_NAME"
    if [ -n "$d" ] && [ -L "$p" ] && [ ! -e "$p" ] && [ "$(readlink "$p")" = "$INSTALL_DIR/$COMMAND_NAME" ]; then
      warn "$p is a symlink to the removed file; remove it with: $([ -w "$d" ] || printf 'sudo ')rm $p"
    fi
  done
  command_copies | while IFS= read -r p; do
    warn "'$COMMAND_NAME' is still on PATH: $p (not installed by this installer)"
  done
}

main() {
  local uninstall_hint
  if [ "$UNINSTALL" -eq 1 ]; then do_uninstall; exit 0; fi
  [ -z "$VERSION_OVERRIDE" ] || err "--version is not supported yet (this installer always installs latest)"

  detect_platform
  detect_pkg_manager
  ensure_minisign
  fetch_manifest
  VERSION=$(flat_get "$WORK_DIR/manifest.flat" version)
  [ -n "$VERSION" ] && [ "$VERSION" != "null" ] || err "manifest did not report a version"

  resolve_asset_source
  info "resolved platform: $ASSET_KEY"
  ASSET_URL=$(platform_field "$ASSET_KEY" url)

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would install $CFG_PROJECT_NAME $VERSION"
    echo "  asset:   $ASSET_URL"
    case "$ASSET_URL" in
      *.deb|*.rpm) echo "  method:  ${ASSET_URL##*.} package" ;;
      *) echo "  target:  $INSTALL_DIR/$COMMAND_NAME" ;;
    esac
    exit 0
  fi

  download_asset "$ASSET_KEY"
  verify_signature
  install_asset
  write_uninstall_manifest
  report_install

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
  info "Uninstall: $uninstall_hint"
}

main "$@"
