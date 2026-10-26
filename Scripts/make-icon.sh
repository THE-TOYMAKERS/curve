#!/bin/sh
# Package the approved Ribbon C artwork using tools supplied by macOS.
set -eu
cd "$(dirname "$0")/.."
icon_tmp=$(mktemp -d "${TMPDIR:-/tmp}/curve-icon.XXXXXX")
trap 'rm -rf "$icon_tmp"' EXIT HUP INT TERM
sips -z 1024 1024 Resources/Curve-Ribbon-C.png --out Resources/AppIcon-1024.png >/dev/null
mkdir "$icon_tmp/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon-1024.png --out "$icon_tmp/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  twice=$((size * 2))
  sips -z "$twice" "$twice" Resources/AppIcon-1024.png --out "$icon_tmp/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_tmp/AppIcon.iconset" -o Resources/AppIcon.icns
printf '%s\n' 'Rebuilt Resources/AppIcon-1024.png and Resources/AppIcon.icns'
