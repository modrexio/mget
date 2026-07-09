#!/bin/sh
# Not meant to be curled directly: a project's own endpoint fetches this file
# plus its install.config.json and prepends the config as CFG_* env vars.
set -eu

DRY_RUN=0
UNINSTALL=0
VERSION_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
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

: "${CFG_PROJECT_NAME:?missing CFG_PROJECT_NAME}"
: "${CFG_MANIFEST_URL:?missing CFG_MANIFEST_URL}"
: "${CFG_INSTALL_DIR:?missing CFG_INSTALL_DIR}"
CFG_PUBKEY="${CFG_PUBKEY:-}"
CFG_ADD_TO_PATH="${CFG_ADD_TO_PATH:-true}"
CFG_POST_INSTALL_CMD="${CFG_POST_INSTALL_CMD:-}"
CFG_UNINSTALL_MANIFEST="${CFG_UNINSTALL_MANIFEST:-$HOME/.$CFG_PROJECT_NAME/uninstall.json}"
# Per-OS preferred packaging variant, e.g. "linux:appimage darwin:app" — space-separated
# key:value pairs, since env vars can't carry a nested JSON object.
CFG_PREFERRED_VARIANT="${CFG_PREFERRED_VARIANT:-}"

case "$CFG_MANIFEST_URL" in
  https://*) ;;
  *) echo "error: CFG_MANIFEST_URL must be https://" >&2; exit 1 ;;
esac

# No eval: only $HOME/... and absolute paths are accepted, so config data can
# never be interpreted as shell code.
case "$CFG_INSTALL_DIR" in
  '$HOME'/*) INSTALL_DIR="$HOME/${CFG_INSTALL_DIR#\$HOME/}" ;;
  /*) INSTALL_DIR="$CFG_INSTALL_DIR" ;;
  *) echo "error: CFG_INSTALL_DIR must be an absolute path or start with \$HOME/" >&2; exit 1 ;;
esac

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

info() { [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && printf '\033[1;34m==>\033[0m %s\n' "$*" || printf '==> %s\n' "$*"; }
warn() { [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2 || printf 'warn: %s\n' "$*" >&2; }
err()  { [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && printf '\033[1;31merror:\033[0m %s\n' "$*" >&2 || printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have curl || err "curl is required"
have jq   || err "jq is required (e.g. 'apt install jq' / 'brew install jq')"

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

fetch_manifest() {
  info "fetching release manifest"
  curl -fsSL --connect-timeout 10 --retry 2 "$CFG_MANIFEST_URL" -o "$WORK_DIR/manifest.json" \
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

resolve_platform_key() {
  local variant base_key
  variant=$(preferred_variant_for "$OS")
  base_key="${OS}-${ARCH}"
  if [ -n "$variant" ] && [ -n "$(platform_field "${base_key}-${variant}" url)" ]; then
    echo "${base_key}-${variant}"
  else
    echo "$base_key"
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
  curl -fsSL --connect-timeout 10 --retry 2 "$ASSET_URL" -o "$ASSET_FILE" || err "download failed: $ASSET_URL"
}

verify_signature() {
  if [ -z "$CFG_PUBKEY" ]; then
    warn "no pubkey configured — skipping signature verification"
    return
  fi
  have minisign || err "a pubkey is configured but minisign is not installed — refusing to install unverified"
  [ -n "$ASSET_SIG" ] || err "release manifest has no signature for this asset"

  echo "$ASSET_SIG" | base64 -d > "$ASSET_FILE.minisig"
  minisign -V -P "$CFG_PUBKEY" -m "$ASSET_FILE" -x "$ASSET_FILE.minisig" \
    || err "signature verification FAILED — refusing to install"
  info "signature verified"
}

INSTALLED_FILES=""

install_asset() {
  local dest app_bundle app_count staged
  mkdir -p "$INSTALL_DIR"
  case "$ASSET_FILE" in
    *.AppImage)
      dest="$INSTALL_DIR/$CFG_PROJECT_NAME"
      staged="$INSTALL_DIR/.${CFG_PROJECT_NAME}.new.$$"
      cp "$ASSET_FILE" "$staged"; chmod +x "$staged"
      mv -f "$staged" "$dest"
      INSTALLED_FILES="$dest"
      ;;
    *.app.tar.gz)
      tar -xzf "$ASSET_FILE" -C "$WORK_DIR"
      app_count=$(find "$WORK_DIR" -maxdepth 1 -name '*.app' | wc -l)
      [ "$app_count" -eq 1 ] || err "expected exactly one .app bundle in the archive, found $app_count"
      app_bundle=$(find "$WORK_DIR" -maxdepth 1 -name '*.app')
      dest="$HOME/Applications/$(basename "$app_bundle")"
      mkdir -p "$HOME/Applications"
      rm -rf "$dest.old"
      [ -e "$dest" ] && mv "$dest" "$dest.old"
      mv "$app_bundle" "$dest"
      rm -rf "$dest.old"
      ln -sf "$dest/Contents/MacOS/$CFG_PROJECT_NAME" "$INSTALL_DIR/$CFG_PROJECT_NAME"
      INSTALLED_FILES="$dest
$INSTALL_DIR/$CFG_PROJECT_NAME"
      ;;
    *.deb)
      have dpkg || err "*.deb asset selected but dpkg not found"
      info "installing via dpkg (sudo required)"
      sudo dpkg -i "$ASSET_FILE"
      INSTALLED_FILES="(managed by dpkg — use apt/dpkg to uninstall)"
      ;;
    *.rpm)
      have rpm || err "*.rpm asset selected but rpm not found"
      info "installing via rpm (sudo required)"
      sudo rpm -U "$ASSET_FILE"
      INSTALLED_FILES="(managed by rpm — use rpm/dnf to uninstall)"
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
  rc="$HOME/.profile"
  case "${SHELL:-}" in
    */zsh) rc="$HOME/.zshrc" ;;
    */bash) rc="$HOME/.bashrc" ;;
    */fish) rc="$HOME/.config/fish/config.fish"; mkdir -p "$(dirname "$rc")" ;;
  esac
  line="export PATH=\"$INSTALL_DIR:\$PATH\"  # added by $CFG_PROJECT_NAME installer"
  grep -qF "$INSTALL_DIR" "$rc" 2>/dev/null || { echo "$line" >> "$rc"; info "added $INSTALL_DIR to PATH in $rc (restart your shell)"; }
}

write_uninstall_manifest() {
  mkdir -p "$(dirname "$CFG_UNINSTALL_MANIFEST")"
  printf '%s\n' "$INSTALLED_FILES" | jq -R '.' | jq -s \
    --arg project "$CFG_PROJECT_NAME" --arg version "$VERSION" --arg install_dir "$INSTALL_DIR" \
    '{project:$project, version:$version, install_dir:$install_dir, files:map(select(length>0))}' \
    > "$CFG_UNINSTALL_MANIFEST"
}

# Only ever removes paths under the install dir or a macOS app bundle we
# installed — the uninstall manifest is treated as data, not as trusted rm targets.
safe_remove() {
  case "$1" in
    "$INSTALL_DIR"/*|"$HOME/Applications/"*.app) rm -rf -- "$1"; info "removed $1" ;;
    *) warn "refusing to remove unexpected path: $1" ;;
  esac
}

do_uninstall() {
  [ -f "$CFG_UNINSTALL_MANIFEST" ] || err "no install record found at $CFG_UNINSTALL_MANIFEST"
  info "removing $CFG_PROJECT_NAME"
  jq -r '.files[]' "$CFG_UNINSTALL_MANIFEST" | while IFS= read -r f; do
    case "$f" in "("*) warn "skip: $f (remove manually)" ;; *) safe_remove "$f" ;; esac
  done
  rm -f "$CFG_UNINSTALL_MANIFEST"
  info "done. (PATH entry left in your shell rc file — remove manually if desired)"
}

main() {
  if [ "$UNINSTALL" -eq 1 ]; then do_uninstall; exit 0; fi
  [ -z "$VERSION_OVERRIDE" ] || err "--version is not supported yet (this installer always installs latest)"

  detect_platform
  fetch_manifest
  VERSION=$(json_get version)
  [ -n "$VERSION" ] && [ "$VERSION" != "null" ] || err "manifest did not report a version"

  key=$(resolve_platform_key)
  info "resolved platform: $key"

  if [ "$DRY_RUN" -eq 1 ]; then
    ASSET_URL=$(platform_field "$key" url)
    echo "would install $CFG_PROJECT_NAME $VERSION"
    echo "  asset:   $ASSET_URL"
    echo "  target:  $INSTALL_DIR"
    exit 0
  fi

  download_asset "$key"
  verify_signature
  install_asset
  update_path
  write_uninstall_manifest

  info "$CFG_PROJECT_NAME $VERSION installed to $INSTALL_DIR"
  if [ -n "$CFG_POST_INSTALL_CMD" ] && ! sh -c "$CFG_POST_INSTALL_CMD"; then
    warn "post-install command failed: $CFG_POST_INSTALL_CMD"
  fi
}

main "$@"
