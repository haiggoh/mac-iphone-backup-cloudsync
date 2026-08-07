#!/bin/bash
# Renders the icon and packs it into Resources/AppIcon.icns.
# Run this only after changing Tools/render-icon.swift; build.sh consumes the
# committed .icns and does not need to re-render.
set -euo pipefail

cd "$(dirname "$0")/.."

PNG="Resources/icon-1024.png"
ICONSET="build/AppIcon.iconset"
ICNS="Resources/AppIcon.icns"

# render-icon.swift takes [variant] [output]. The variant MUST be passed
# explicitly: omitting it makes the renderer read the output path as a variant
# name and exit 2, which silently leaves the previous .icns in place.
VARIANT="${1:-triangle}"

mkdir -p Resources build

echo "==> Rendering $PNG (variant: $VARIANT)"
xcrun swift Tools/render-icon.swift "$VARIANT" "$PNG"

echo "==> Building iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# name:pixels — @2x entries are the same pixel size as the next tier up.
for spec in \
	icon_16x16:16 icon_16x16@2x:32 \
	icon_32x32:32 icon_32x32@2x:64 \
	icon_128x128:128 icon_128x128@2x:256 \
	icon_256x256:256 icon_256x256@2x:512 \
	icon_512x512:512 icon_512x512@2x:1024
do
	name="${spec%:*}"
	px="${spec#*:}"
	sips -z "$px" "$px" "$PNG" --out "$ICONSET/$name.png" >/dev/null
done

echo "==> Packing $ICNS"
iconutil --convert icns "$ICONSET" --output "$ICNS"
rm -rf "$ICONSET"

ls -l "$ICNS"
echo "==> Done. Run ./build.sh --install to pick it up."
