#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/scripts/bundle.sh")"
DIST="$ROOT/dist"
APP="$ROOT/build/Kuma.app"

"$ROOT/scripts/bundle.sh" --universal

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> zip"
ditto -c -k --keepParent "$APP" "$DIST/Kuma-$VERSION.zip"

echo "==> dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Kuma.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Kuma $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DIST/Kuma-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
codesign --force -s - "$DIST/Kuma-$VERSION.dmg"

echo "==> checksums"
(cd "$DIST" && shasum -a 256 "Kuma-$VERSION.dmg" "Kuma-$VERSION.zip" > SHA256SUMS.txt)
cat "$DIST/SHA256SUMS.txt"
echo "==> release files in $DIST"
