#!/bin/sh
# Rebuild Curve's PNG and ICNS with tools supplied by macOS Command Line Tools.
set -eu
cd "$(dirname "$0")/.."
icon_tmp=$(mktemp -d "${TMPDIR:-/tmp}/curve-icon.XXXXXX")
trap 'rm -rf "$icon_tmp"' EXIT HUP INT TERM
clang -fobjc-arc -fno-modules -framework AppKit Scripts/MakeIcon.m -o "$icon_tmp/MakeIcon"
"$icon_tmp/MakeIcon" Resources/AppIcon-1024.png
mkdir "$icon_tmp/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon-1024.png --out "$icon_tmp/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  twice=$((size * 2))
  sips -z "$twice" "$twice" Resources/AppIcon-1024.png --out "$icon_tmp/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_tmp/AppIcon.iconset" -o Resources/AppIcon.icns
printf '%s\n' 'Rebuilt Resources/AppIcon-1024.png and Resources/AppIcon.icns'
