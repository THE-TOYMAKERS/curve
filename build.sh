#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
./Scripts/sign-app.sh --check
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build --disable-sandbox -c release --product Curve
curve_bundle_tmp=$(mktemp -d "$PWD/.build/curve-bundle.XXXXXX")
trap 'rm -rf "$curve_bundle_tmp"' EXIT HUP INT TERM
curve_app="$curve_bundle_tmp/Curve.app"
mkdir -p "$curve_app/Contents/MacOS" "$curve_app/Contents/Resources"
cp .build/release/Curve "$curve_app/Contents/MacOS/Curve"
strip -S "$curve_app/Contents/MacOS/Curve"
cp Info.plist "$curve_app/Contents/Info.plist"
cp Resources/AppIcon.icns "$curve_app/Contents/Resources/"
if [[ ! -d Resources/Protection ]]; then
  print -u2 'The bundled protection resources are missing; refusing to build an unprotected app.'
  exit 1
fi
cp -R Resources/Protection "$curve_app/Contents/Resources/Protection"
./Scripts/sign-app.sh "$curve_app"
rm -rf "$PWD/Curve.app"
mv "$curve_app" "$PWD/Curve.app"
print "Built $PWD/Curve.app"
