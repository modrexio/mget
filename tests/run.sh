#!/bin/sh
set -u
ENGINE_DIR=$(cd "$(dirname "$0")/.." && pwd)
ENGINE=$ENGINE_DIR/install.sh
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
  expect "signature verified"
  refute "no manifest signature"
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
  printf '#!/bin/sh
' > "$OUT.foreign"; as_root install -m755 "$OUT.foreign" /usr/bin/refract
  run -y
  as_root rm -f /usr/bin/refract
  [ "$STATUS" -eq 0 ] || fail "exit $STATUS"
  expect "via $PKG (provides: /usr/bin/refract-tauri"
  expect "signature verified"
  expect "this package does not provide a 'refract' command"
  expect "'refract' currently runs /usr/bin/refract (not installed by this installer)"
  run --uninstall -y
  expect "removed package refract via $PKG"
}

t_install_dir_change_starts_a_fresh_record() {
  new_home; modrex_env; PATH=$SYS_PATH
  run --appimage
  run --appimage --install-dir "$HOME/alt"
  [ "$STATUS" -eq 0 ] || fail "exit $STATUS"
  manifest_files | grep -q "^$HOME/alt/modrex$" || fail "new location not recorded"
  ! manifest_files | grep -q "^$HOME/.local/bin/modrex$" || fail "old location carried into a manifest with another install_dir"
  run --uninstall -y --install-dir "$HOME/alt"
  [ "$STATUS" -eq 0 ] || fail "uninstall exit $STATUS"
  [ ! -e "$HOME/alt/modrex" ] || fail "AppImage still present"
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

engine_functions() { sed -n "/^$1() {/,/^}/p" "$ENGINE"; }

t_json_reader_matches_jq_and_rejects_bad_input() {
  local d f k bad
  d=$(mktemp -d)
  eval "$(engine_functions json_flat); $(engine_functions flat_get)"
  curl -fsSL https://github.com/modrexio/modrex/releases/latest/download/latest.json -o "$d/modrex.json"
  curl -fsSL https://github.com/RefractMC/Refract_MC/releases/download/v1.4.0/latest.json -o "$d/refract.json"
  for f in "$d/modrex.json" "$d/refract.json" "$ENGINE_DIR/tests/fixtures/appimage-only.json"; do
    json_flat "$f" > "$d/flat" || fail "reader rejected $f"
    [ "$(flat_get "$d/flat" version)" = "$(jq -r .version "$f")" ] || fail "version differs from jq for $f"
    for k in $(jq -r '.platforms | keys[]' "$f"); do
      [ "$(flat_get "$d/flat" "platforms.$k.url")" = "$(jq -r ".platforms[\"$k\"].url" "$f")" ] || fail "url differs from jq: $k"
      [ "$(flat_get "$d/flat" "platforms.$k.signature")" = "$(jq -r ".platforms[\"$k\"].signature" "$f")" ] || fail "signature differs from jq: $k"
    done
  done
  printf '%s' '{"s":"a\"b\\c\/d\n\t\b\f\u0041\ud83d\ude00","e":"","n":-1.5e3,"t":true,"z":null,"o":{},"a":[],"k":{"x":[1,{"y":"v"}]},"dup":1,"dup":2,"ab":"prefix"}' > "$d/edge.json"
  json_flat "$d/edge.json" > "$d/flat" || fail "reader rejected edge.json"
  [ "$(flat_get "$d/flat" s)" = 'a"b\c/d\n\t\b\f\u0041\ud83d\ude00' ] || fail "escape contract: got $(flat_get "$d/flat" s)"
  grep -q '^e	$' "$d/flat" || fail "empty string not emitted"
  [ "$(flat_get "$d/flat" n)" = "-1.5e3" ] && [ "$(flat_get "$d/flat" t)" = "true" ] && [ "$(flat_get "$d/flat" z)" = "null" ] || fail "literals"
  [ "$(flat_get "$d/flat" k.x.1.y)" = "v" ] && [ "$(flat_get "$d/flat" k.x.0)" = "1" ] || fail "nested array path"
  [ "$(flat_get "$d/flat" dup)" = "2" ] || fail "duplicate key: last must win like jq"
  [ -z "$(flat_get "$d/flat" a)" ] && [ -z "$(flat_get "$d/flat" k.x)" ] || fail "prefix must not match"
  [ "$(grep -c . "$d/flat")" -eq 10 ] || fail "unexpected leaf count $(grep -c . "$d/flat")"
  for bad in '{"a":1' '{"a":1}x' '{"a":"x	y"}' '{"a":nope}' '{"a":"\q"}' '{a:1}' '[1,]' '' "$(printf '\357\273\277{}')"; do
    printf '%s' "$bad" > "$d/bad.json"
    json_flat "$d/bad.json" >/dev/null 2>&1; [ $? -eq 2 ] || fail "accepted malformed input: $bad"
  done
}

t_written_manifest_is_valid_json_with_escapes() {
  new_home; modrex_env; PATH=$SYS_PATH
  run --appimage
  jq -e --arg d "$HOME/.local/bin" '.project == "modrex" and .install_dir == $d and (.files | index($d + "/modrex") != null)' "$HOME/.modrex/uninstall.json" >/dev/null \
    || fail "manifest not readable by jq or missing fields"
  printf '{"project":"modrex","version":"0","install_dir":"%s","files":["%s/.local/bin/modrex","pkg:apt:a\\"b\\\\c"]}' "$HOME/.local/bin" "$HOME" > "$HOME/.modrex/uninstall.json"
  run --appimage
  jq -e . "$HOME/.modrex/uninstall.json" >/dev/null || fail "rewritten manifest is not valid JSON"
  [ "$(jq -r '.files[]' "$HOME/.modrex/uninstall.json" | grep -c 'pkg:apt:')" -eq 0 ] || fail "vanished package entry should be pruned"
  run --uninstall -y
  [ "$STATUS" -eq 0 ] || fail "uninstall exit $STATUS"
}

t_no_github_api_path() {
  ! grep -q 'api.github.com' "$ENGINE" || fail "engine still references the GitHub API"
  ! grep -qw 'jq' "$ENGINE" || fail "engine still references jq"
  new_home; modrex_env; PATH=$SYS_PATH; export CFG_GITHUB_REPO=this/does-not-exist
  run --dry-run -y
  [ "$STATUS" -eq 0 ] || fail "exit $STATUS"
  refute "GitHub"
  expect "method:  $NATIVE_EXT package"
  expect "releases/download/"
}

t_appimage_fallback_when_native_key_absent() {
  [ -n "${FIXTURE_REF:-${GITHUB_SHA:-}}" ] || { echo "  skipped: set FIXTURE_REF (the fixture must be reachable over https)"; return; }
  new_home; modrex_env; PATH=$SYS_PATH
  export CFG_MANIFEST_URL="https://raw.githubusercontent.com/${GITHUB_REPOSITORY:-modrexio/mget}/${FIXTURE_REF:-$GITHUB_SHA}/tests/fixtures/appimage-only.json"
  run --dry-run -y
  [ "$STATUS" -eq 0 ] || fail "exit $STATUS"
  expect "resolved platform: linux-x86_64-appimage"
  expect "target:  $HOME/.local/bin/modrex"
  run --dry-run --$NATIVE_EXT
  [ "$STATUS" -ne 0 ] || fail "--$NATIVE_EXT must fail when the manifest has no such key"
  expect "no .$NATIVE_EXT asset published for modrex (manifest key 'linux-x86_64-$NATIVE_EXT')"
}

has_minisign() { hash -r; command -v minisign >/dev/null 2>&1; }
remove_minisign() { ! has_minisign || as_root $PKG remove -y minisign >/dev/null 2>&1; ! has_minisign || fail "could not remove minisign for the test"; }
restore_minisign() { has_minisign || as_root $PKG install -y minisign >/dev/null 2>&1; }

no_tty() { if command -v setsid >/dev/null 2>&1; then setsid "$@"; else "$@"; fi; }

t_dry_run_does_not_offer_to_install_minisign() {
  new_home; modrex_env; PATH=$SYS_PATH; remove_minisign
  run --dry-run -y
  [ "$STATUS" -eq 0 ] || fail "exit $STATUS"
  refute "minisign"
  expect "would install modrex"
  ! has_minisign || fail "dry run installed minisign"
}

t_minisign_offer_accepted_with_yes() {
  new_home; modrex_env; PATH=$SYS_PATH; remove_minisign
  run --appimage -y
  [ "$STATUS" -eq 0 ] || fail "exit $STATUS"
  expect "minisign is required to verify modrex's signature; it can be installed with: $PKG"
  expect "signature verified"
  has_minisign || fail "minisign not installed"
  run --uninstall -y
}

t_minisign_offer_without_consent_refuses() {
  new_home; modrex_env; PATH=$SYS_PATH; remove_minisign
  no_tty sh "$ENGINE" --appimage >"$OUT" 2>&1 </dev/null; STATUS=$?
  [ "$STATUS" -ne 0 ] || fail "proceeded without consent"
  expect "minisign is required to verify modrex's signature"
  expect "rerun with -y"
  refute "fetching release manifest"
}

t_minisign_install_failure_is_explicit() {
  new_home; modrex_env; remove_minisign
  mkdir -p "$HOME/stub"; for c in sudo apt-get dnf zypper; do printf '#!/bin/sh\nexit 1\n' > "$HOME/stub/$c"; chmod +x "$HOME/stub/$c"; done
  PATH="$HOME/stub:$SYS_PATH" sh "$ENGINE" --appimage -y >"$OUT" 2>&1; STATUS=$?
  [ "$STATUS" -ne 0 ] || fail "proceeded after a failed install"
  expect "installing minisign failed"
  refute "fetching release manifest"
}

t_minisign_without_package_manager_keeps_the_plain_error() {
  new_home; modrex_env; remove_minisign
  mkdir -p "$HOME/onlybin"
  for c in sh curl awk sed grep tr head cut sort id uname mktemp rm mkdir dirname basename cat wc ls readlink base64 env; do
    ln -s "$(command -v $c)" "$HOME/onlybin/$c" 2>/dev/null || true
  done
  PATH="$HOME/onlybin" sh "$ENGINE" --appimage -y >"$OUT" 2>&1; STATUS=$?
  restore_minisign
  [ "$STATUS" -ne 0 ] || fail "proceeded without minisign"
  expect "minisign is required to verify modrex's signature (e.g."
  refute "Install minisign now"
}

ALL="t_json_reader_matches_jq_and_rejects_bad_input t_written_manifest_is_valid_json_with_escapes t_no_github_api_path t_appimage_fallback_when_native_key_absent
  t_appimage_not_on_path t_appimage_on_path_is_idempotent t_shadowing_is_reported
  t_native_accumulates_with_appimage t_uninstall_removes_recorded_reports_foreign
  t_dangling_symlink_is_reported t_v1_manifest_is_honoured t_missing_owned_files_are_tolerated
  t_package_without_command_is_reported_not_rejected t_install_dir_change_starts_a_fresh_record t_sudo_is_refused_before_network t_dry_run_never_prompts
  t_dry_run_does_not_offer_to_install_minisign t_minisign_offer_accepted_with_yes t_minisign_offer_without_consent_refuses
  t_minisign_install_failure_is_explicit t_minisign_without_package_manager_keeps_the_plain_error"
for t in ${TESTS:-$ALL}; do
  echo "$t"
  before=$FAILED; $t
  [ "$FAILED" -eq "$before" ] || { echo "--- output:"; sed 's/^/    /' "$OUT"; }
done
rm -f "$OUT" "$OUT.foreign"
[ "$FAILED" -eq 0 ] && echo "all tests passed" || { echo "some tests failed"; exit 1; }
