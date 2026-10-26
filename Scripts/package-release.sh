#!/bin/zsh
# Build a universal macOS release with only Apple's local toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh
native_arch=$(uname -m)
case "$native_arch" in
  arm64) cross_arch=x86_64; cross_scratch=.build-intel ;;
  x86_64) cross_arch=arm64; cross_scratch=.build-arm64 ;;
  *) print -u2 "Unsupported host architecture: $native_arch"; exit 1 ;;
esac
export CLANG_MODULE_CACHE_PATH="$PWD/$cross_scratch/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/$cross_scratch/swift-cache"
cross_triple="$cross_arch-apple-macosx14.0"
swift build --disable-sandbox -c release --product Curve \
  --triple "$cross_triple" --scratch-path "$cross_scratch"
cross_bin=$(swift build --disable-sandbox -c release --show-bin-path \
  --triple "$cross_triple" --scratch-path "$cross_scratch")
app="$PWD/Curve.app"
lipo -create "$PWD/.build/release/Curve" "$cross_bin/Curve" \
  -output "$app/Contents/MacOS/Curve"
strip -S "$app/Contents/MacOS/Curve"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
lipo -info "$app/Contents/MacOS/Curve"
mkdir -p dist
COPYFILE_DISABLE=1 ditto -c -k --keepParent --noextattr --norsrc \
  "$app" "$PWD/dist/Curve-macOS.zip"
(cd dist && shasum -a 256 Curve-macOS.zip > SHA256SUMS.txt)
print "Release: $PWD/dist/Curve-macOS.zip"
