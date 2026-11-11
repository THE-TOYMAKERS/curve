#!/bin/zsh
# Build a universal macOS release with only Apple's local toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/sign-app.sh --check
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
CURVE_EXPECT_UNIVERSAL=1 ./Scripts/sign-app.sh "$app"
if [[ "${CURVE_NOTARIZE-0}" == 1 ]]; then
  ./Scripts/notarize-app.sh "$app"
fi
CURVE_EXPECT_UNIVERSAL=1 ./Scripts/verify-app.sh "$app"
lipo -info "$app/Contents/MacOS/Curve"
mkdir -p dist
curve_archive_tmp=$(mktemp -d "$PWD/dist/.curve-release.XXXXXX")
trap 'rm -rf "$curve_archive_tmp"' EXIT HUP INT TERM
COPYFILE_DISABLE=1 ditto -c -k --keepParent --noextattr --norsrc \
  "$app" "$curve_archive_tmp/Curve-macOS.zip"
python3 - "$curve_archive_tmp/Curve-macOS.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    if archive.testzip() is not None or not all(name.startswith('Curve.app/') for name in archive.namelist()):
        raise SystemExit('Release ZIP integrity/content validation failed.')
PY
(cd "$curve_archive_tmp" && shasum -a 256 Curve-macOS.zip > SHA256SUMS.txt)
mv "$curve_archive_tmp/Curve-macOS.zip" "$PWD/dist/Curve-macOS.zip"
mv "$curve_archive_tmp/SHA256SUMS.txt" "$PWD/dist/SHA256SUMS.txt"
print "Release: $PWD/dist/Curve-macOS.zip"
if [[ "${CURVE_NOTARIZE-0}" != 1 ]]; then
  print 'PREVIEW: this archive has not completed Apple notarization. Do not describe it as a notarized or Gatekeeper-approved release.'
fi
