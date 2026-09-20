#!/bin/sh
set -eu
repo="$1"; cmd="$2"; tag="${3:-}"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work"
api="https://api.github.com/repos/$repo/releases/${tag:+tags/}${tag:-latest}"
curl -fsSL -H 'User-Agent: mget-consumer-check' ${GITHUB_TOKEN:+-H} ${GITHUB_TOKEN:+"Authorization: Bearer $GITHUB_TOKEN"} "$api" > release.json
echo "checking $repo $(jq -r .tag_name release.json) for /usr/bin/$cmd"
failed=0
for url in $(jq -r '.assets[].browser_download_url' release.json); do
  name=${url##*/}
  case "$name" in
    *.deb)
      curl -fsSL -o "$name" "$url"
      dpkg-deb -c "$name" | grep -qE " (\./)?usr/bin/$cmd$" && echo "  ok   $name" || { echo "  FAIL $name: no usr/bin/$cmd"; failed=1; } ;;
    *.rpm)
      curl -fsSL -o "$name" "$url"
      rpm -qlp "$name" 2>/dev/null | grep -qx "/usr/bin/$cmd" && echo "  ok   $name" || { echo "  FAIL $name: no /usr/bin/$cmd"; failed=1; } ;;
    *.AppImage)
      curl -fsSL -o "$name" "$url"; chmod +x "$name"; rm -rf squashfs-root
      ./"$name" --appimage-extract "usr/bin/$cmd" >/dev/null 2>&1 || true
      [ -x "squashfs-root/usr/bin/$cmd" ] && echo "  ok   $name" || { echo "  FAIL $name: no usr/bin/$cmd"; failed=1; } ;;
    *.app.tar.gz)
      curl -fsSL -o "$name" "$url"
      tar -tzf "$name" | grep -qE "^[^/]+\.app/Contents/MacOS/$cmd$" && echo "  ok   $name" || { echo "  FAIL $name: no Contents/MacOS/$cmd"; failed=1; } ;;
  esac
done
exit $failed
