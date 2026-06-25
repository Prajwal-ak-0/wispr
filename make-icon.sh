#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

SVG="Resources/logo.svg"
ICONSET="build/Murmur.iconset"

command -v rsvg-convert >/dev/null || { echo "rsvg-convert missing (brew install librsvg)"; exit 1; }

rm -rf "$ICONSET"
mkdir -p "$ICONSET" Resources

render() { rsvg-convert -w "$1" -h "$1" "$SVG" -o "$ICONSET/$2"; }
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o Resources/Murmur.icns
echo "wrote Resources/Murmur.icns"
