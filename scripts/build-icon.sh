#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ICONSET="$PWD/.build/AppIcon.iconset"
if [[ -f "$PWD/.build/AppIcon.icns" && "$PWD/.build/AppIcon.icns" -nt "$PWD/Assets/AppIcon.png" ]]; then
    exit 0
fi
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o .build/AppIcon.icns
