#!/usr/bin/env bash
#
# Regenerates the app icon from packaging/AppIcon.svg: packaging/AppIcon.icns for the app bundle,
# and packaging/AppIcon.png (rounded like the Dock) for the README. Needs rsvg-convert
# (brew install librsvg).
#
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" packaging/AppIcon.svg -o "$ICONSET/icon_${size}x${size}.png"
  rsvg-convert -w "$((size * 2))" -h "$((size * 2))" packaging/AppIcon.svg -o "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o packaging/AppIcon.icns

# macOS masks the full-bleed square itself. The README copy gets the rounded corners here.
rsvg-convert -w 512 -h 512 packaging/AppIcon.svg -o "$WORK/square.png"
cat > "$WORK/rounded.svg" << SVG
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512">
  <clipPath id="mask"><rect width="512" height="512" rx="115"/></clipPath>
  <image clip-path="url(#mask)" width="512" height="512" href="square.png"/>
</svg>
SVG
rsvg-convert "$WORK/rounded.svg" -o packaging/AppIcon.png
rm -rf "$WORK"
echo "Wrote packaging/AppIcon.icns and packaging/AppIcon.png"
