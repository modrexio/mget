#!/bin/sh
set -u
ENGINE=$(cd "$(dirname "$0")/.." && pwd)/install.sh
OUT=$(mktemp)
FAILED=0
SYS_PATH=/usr/local/bin:/usr/bin:/bin
MODREX_PUBKEY=RWTX2KsFhWADAjKhVxTe/CxS/HT+S3iMqrQorXSP/QUE20RjzISVRUbV
REFRACT_PUBKEY=RWQkukf1kBwQ/86ivJEv75SqjTY69a/ygF8HPb9ZXNwQoi+A2L/dY875
SHELL_FILES='.profile .bashrc .bash_profile .bash_login .zshrc .zshenv .zprofile .config/fish/config.fish .config/fish/fish_variables'

if command -v apt-get >/dev/null 2>&1; then PKG=apt; PKG_QUERY='dpkg -s'; NATIVE_EXT=deb
elif command -v dnf >/dev/null 2>&1; then PKG=dnf; PKG_QUERY='rpm -q'; NATIVE_EXT=rpm
else echo "tests need apt-get or dnf" >&2; exit 1; fi

as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }
fail() { echo "  FAIL: $*"; FAILED=1; }
expect() { grep -qF -- "$1" "$OUT" || fail "expected output: $1"; }
refute() { ! grep -qF -- "$1" "$OUT" || fail "unexpected output: $1"; }
run() { sh "$ENGINE" "$@" >"$OUT" 2>&1; STATUS=$?; }

new_home() {
  HOME=$(mktemp -d); export HOME
  mkdir -p "$HOME/.config/fish"
  for f in $SHELL_FILES; do printf '# untouched\n' > "$HOME/$f"; done
}
shell_digest() {
  (cd "$HOME" && for f in $SHELL_FILES; do sha256sum "$f"; done; find . -maxdepth 1 -name '.*' ! -name .local ! -name .config ! -name ".$1" | sort)
}
modrex_env() {
  export CFG_SCHEMA_VERSION=1 CFG_PROJECT_NAME=modrex CFG_GITHUB_REPO=modrexio/modrex \
    CFG_MANIFEST_URL=https://github.com/modrexio/modrex/releases/latest/download/latest.json \
    CFG_PUBKEY=$MODREX_PUBKEY CFG_INSTALL_DIR='$HOME/.local/bin'
}
refract_1_4_0_env() {
  export CFG_SCHEMA_VERSION=1 CFG_PROJECT_NAME=refract CFG_GITHUB_REPO= \
    CFG_MANIFEST_URL=https://github.com/RefractMC/Refract_MC/releases/download/v1.4.0/latest.json \
    CFG_PUBKEY=$REFRACT_PUBKEY CFG_INSTALL_DIR='$HOME/.local/bin'
}
manifest_files() { jq -r '.files[]' "$HOME/.$CFG_PROJECT_NAME/uninstall.json" | sort; }

t_appimage_not_on_path() {
  new_home; modrex_env; PATH=$SYS_PATH
  local before; before=$(shell_digest modrex)
  run --appimage
  [ "$STATUS" -eq 0 ] || fail "exit $STATUS"
  expect "installed $HOME/.local/bin/modrex"
  expect "'modrex' is not on your PATH in this terminal"
  expect "sudo ln -s $HOME/.local/bin/modrex /usr/local/bin/modrex"
  refute "available in this terminal"
  [ "$(shell_digest modrex)" = "$before" ] || fail "shell startup files changed"
  [ -x "$HOME/.local/bin/modrex" ] || fail "AppImage missing"
  grep -q "^Exec=$HOME/.local/bin/modrex " "$HOME/.local/share/applications/modrex.desktop" || fail "desktop entry Exec is not absolute"
  ! command -v modrex >/dev/null 2>&1 || fail "modrex resolves in the installing environment"
}

t_appimage_on_path_is_idempotent() {
  modrex_env; PATH="$HOME/.local/bin:$SYS_PATH"
  local before; before=$(manifest_files)
  run --appimage
  [ "$STATUS" -eq 0 ] || fail "exit $STATUS"
  expect "'modrex' is available in this terminal"
  refute "not on your PATH"
  [ "$(manifest_files)" = "$before" ] || fail "manifest changed on reinstall"
}

t_shadowing_is_reported() {
  modrex_env; mkdir -p "$HOME/shadow"; printf '#!/bin/sh\n' > "$HOME/shadow/modrex"; chmod +x "$HOME/shadow/modrex"
  PATH="$HOME/shadow:$SYS_PATH"
  run --appimage
  expect "'modrex' currently runs $HOME/shadow/modrex (not installed by this installer), not the copy just installed"
  PATH="$HOME/.local/bin:$HOME/shadow:$SYS_PATH"
  run --appimage
  expect "'modrex' is available in this terminal"
  expect "another 'modrex' is on PATH: $HOME/shadow/modrex (not installed by this installer)"
}

t_native_accumulates_with_appimage() {
  modrex_env; PATH=$SYS_PATH
  run -y
  [ "$STATUS" -eq 0 ] || fail "exit $STATUS"
  expect "via $PKG (provides: /usr/bin/modrex"
  expect "'modrex' is available in this terminal"
  expect "modrex is installed both as a package and in $HOME/.local/bin; --uninstall removes both"
  manifest_files | grep -q "^pkg:$PKG:modrex$" || fail "package not recorded"
  manifest_files | grep -q "^$HOME/.local/bin/modrex$" || fail "AppImage record lost"
}

t_uninstall_removes_recorded_reports_foreign() {
  modrex_env; PATH=$SYS_PATH
  printf '#!/bin/sh\n' > "$OUT.foreign"; as_root install -m755 "$OUT.foreign" /usr/local/bin/modrex
  run --uninstall -y
  as_root rm -f /usr/local/bin/modrex
  [ "$STATUS" -eq 0 ] || fail "exit $STATUS"
  expect "removed package modrex via $PKG"
  expect "removed $HOME/.local/bin/modrex"
  expect "'modrex' is still on PATH: /usr/local/bin/modrex (not installed by this installer)"
  ! $PKG_QUERY modrex >/dev/null 2>&1 || fail "package still installed"
  [ ! -e "$HOME/.local/bin/modrex" ] || fail "AppImage still present"
  [ ! -e "$HOME/.modrex/uninstall.json" ] || fail "manifest still present"
}

t_dangling_symlink_is_reported() {
  new_home; modrex_env; PATH=$SYS_PATH
  run --appimage
  as_root ln -s "$HOME/.local/bin/modrex" /usr/local/bin/modrex
  run --uninstall -y
  as_root rm -f /usr/local/bin/modrex
  expect "/usr/local/bin/modrex is a symlink to the removed file; remove it with:"
  expect "rm /usr/local/bin/modrex"
}

t_v1_manifest_is_honoured() {
  new_home; modrex_env; PATH=$SYS_PATH
  run --appimage
  jq -n --arg h "$HOME" '{project:"modrex", version:"0.14.0", install_dir:($h+"/.local/bin"),
    files:[($h+"/.local/bin/modrex"), ($h+"/.local/share/applications/modrex.desktop"), ($h+"/.local/share/icons/modrex.png")]}' \
    > "$HOME/.modrex/uninstall.json"
  run --uninstall -y
  [ "$STATUS" -eq 0 ] || fail "exit $STATUS"
  [ ! -e "$HOME/.local/bin/modrex" ] || fail "AppImage still present"
  [ ! -e "$HOME/.local/share/applications/modrex.desktop" ] || fail "desktop entry still present"
}

t_missing_owned_files_are_tolerated() {
  new_home; modrex_env; PATH=$SYS_PATH
  run --appimage
  rm -f "$HOME/.local/bin/modrex"
  run --uninstall -y
  [ "$STATUS" -eq 0 ] || fail "exit $STATUS"
  expect "already removed: $HOME/.local/bin/modrex"
}

t_package_without_command_is_reported_not_rejected() {
  new_home; refract_1_4_0_env; PATH=$SYS_PATH
  run -y
  [ "$STATUS" -eq 0 ] || fail "exit $STATUS"
  expect "via $PKG (provides: /usr/bin/refract-tauri"
  expect "this package does not provide a 'refract' command"
  run --uninstall -y
  expect "removed package refract via $PKG"
}

t_sudo_is_refused_before_network() {
  new_home; modrex_env; PATH=$SYS_PATH
  if [ "$(id -u)" -eq 0 ]; then SUDO_USER=someone sh "$ENGINE" --dry-run -y >"$OUT" 2>&1; else sudo sh "$ENGINE" --dry-run -y >"$OUT" 2>&1; fi
  STATUS=$?
  [ "$STATUS" -ne 0 ] || fail "sudo install was accepted"
  expect "do not run this installer with sudo"
  refute "fetching release manifest"
}

t_dry_run_never_prompts() {
  new_home; modrex_env; PATH=$SYS_PATH
  sh "$ENGINE" --dry-run >"$OUT" 2>&1 </dev/null & pid=$!
  ( sleep 60; kill $pid 2>/dev/null ) & watchdog=$!
  wait $pid; STATUS=$?; kill $watchdog 2>/dev/null
  [ "$STATUS" -eq 0 ] || fail "exit $STATUS"
  expect "would install modrex"
  expect "method:  $NATIVE_EXT package"
  refute "Choice"
  refute "target:"
}

ALL="t_appimage_not_on_path t_appimage_on_path_is_idempotent t_shadowing_is_reported
  t_native_accumulates_with_appimage t_uninstall_removes_recorded_reports_foreign
  t_dangling_symlink_is_reported t_v1_manifest_is_honoured t_missing_owned_files_are_tolerated
  t_package_without_command_is_reported_not_rejected t_sudo_is_refused_before_network t_dry_run_never_prompts"
for t in ${TESTS:-$ALL}; do
  echo "$t"
  before=$FAILED; $t
  [ "$FAILED" -eq "$before" ] || { echo "--- output:"; sed 's/^/    /' "$OUT"; }
done
rm -f "$OUT" "$OUT.foreign"
[ "$FAILED" -eq 0 ] && echo "all tests passed" || { echo "some tests failed"; exit 1; }
