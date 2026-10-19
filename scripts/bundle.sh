#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="0.1.2"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
INSTALL=0
UNIVERSAL=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --universal) UNIVERSAL=1 ;;
    -h|--help)
      echo "usage: scripts/bundle.sh [--install] [--universal]"
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

cd "$ROOT"

ARCH_FLAGS=()
if [ "$UNIVERSAL" = 1 ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> swift build -c release ${ARCH_FLAGS[*]:-}"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product Kuma
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product kuma-hook
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="$ROOT/build/Kuma.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$RES"

cp "$BIN_DIR/Kuma" "$CONTENTS/MacOS/Kuma"
cp "$BIN_DIR/kuma-hook" "$CONTENTS/Helpers/kuma-hook"
chmod +x "$CONTENTS/MacOS/Kuma" "$CONTENTS/Helpers/kuma-hook"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" "$ROOT/scripts/Info.plist" > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> app icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
if command -v rsvg-convert >/dev/null; then
  swift "$ROOT/scripts/render-icon.swift" "$ROOT/Assets/app-icon.svg" "$ICONSET"
else
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT/Assets/app-icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ROOT/Assets/app-icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
fi
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "==> menu bar glyph"
GLYPH_SRC="$ROOT/Assets/menubar-glyph.svg"
if command -v rsvg-convert >/dev/null && command -v magick >/dev/null; then
  TMP_GLYPH="$(mktemp -d)"
  rsvg-convert -w 1024 -h 1024 "$GLYPH_SRC" -o "$TMP_GLYPH/g.png"
  for spec in "18:MenuBarGlyph.png" "36:MenuBarGlyph@2x.png"; do
    px="${spec%%:*}"
    name="${spec#*:}"
    magick "$TMP_GLYPH/g.png" -trim +repage -background none -gravity center -extent 960x960 \
      -filter Lanczos -resize "${px}x${px}" -channel RGB -fill black -colorize 100 +channel "$RES/$name"
  done
  rm -rf "$TMP_GLYPH"
else
  cp "$ROOT/Assets/MenuBarGlyph.png" "$ROOT/Assets/MenuBarGlyph@2x.png" "$RES/"
fi
cp "$ROOT/Assets/menubar-glyph.png" "$ROOT/Assets/menubar-glyph.svg" "$ROOT/Assets/app-icon.png" "$RES/"

if [ -d "$ROOT/Resources/voice" ]; then
  echo "==> voice resources"
  mkdir -p "$RES/voice"
  rsync -a --exclude '__pycache__' --exclude '.venv' "$ROOT/Resources/voice/" "$RES/voice/"
fi

if [ -d "$ROOT/Integrations" ]; then
  echo "==> integrations"
  mkdir -p "$RES/Integrations"
  rsync -a "$ROOT/Integrations/" "$RES/Integrations/"
fi

echo "==> codesign (ad hoc)"
codesign --force --deep -s - "$APP"
codesign --verify --deep "$APP"

echo "==> built $APP"

if [ "$INSTALL" = 1 ]; then
  DEST="$HOME/Applications/Kuma.app"
  mkdir -p "$HOME/Applications"
  pkill -x Kuma 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "==> installed to $DEST"
fi
