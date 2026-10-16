#!/bin/bash
# Regenerates bundled icons from Resources/Logo SVGs. Requires rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")/.."

# Menu bar: vector template image.
rsvg-convert -f pdf Resources/Logo/menu-bar.svg -o Resources/MenuBarIcon.pdf

# App icon (also shown in notifications): .icns from every iconset size.
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    rsvg-convert -w "$size" -h "$size" Resources/Logo/app-icon.svg -o "$iconset/icon_${size}x${size}.png"
    rsvg-convert -w $((size * 2)) -h $((size * 2)) Resources/Logo/app-icon.svg -o "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
printf 'Built Resources/MenuBarIcon.pdf and Resources/AppIcon.icns\n'
