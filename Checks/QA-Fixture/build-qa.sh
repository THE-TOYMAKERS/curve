#!/bin/zsh
# Package the self-authored binary with an isolated synthetic profile.
set -euo pipefail
if (( $# > 0 )); then SOURCE_APP="${1:A}"; else SOURCE_APP=""; fi
if (( $# > 1 )); then QA_RUN_ROOT="${2:A}"; else QA_RUN_ROOT=""; fi
cd "$(dirname "$0")"
QA_ROOT="$PWD"
if [[ -z "$SOURCE_APP" ]]; then SOURCE_APP="$QA_ROOT/../../Curve.app"; fi
if [[ -z "$QA_RUN_ROOT" ]]; then QA_RUN_ROOT="$QA_ROOT/../../.build/qa-fixture"; fi
if [[ ! -f "$SOURCE_APP/Contents/MacOS/Curve" ]]; then
  print -u2 'Build Curve.app first, or pass its path as the first argument.'
  exit 1
fi
mkdir -p "$QA_RUN_ROOT"
QA_RUN_ROOT="$(cd "$QA_RUN_ROOT" && pwd)"
QA_APP="$QA_RUN_ROOT/Curve QA.app"
mkdir -p "$QA_APP/Contents/MacOS" "$QA_APP/Contents/Resources"
cp "$SOURCE_APP/Contents/MacOS/Curve" "$QA_APP/Contents/MacOS/Curve"
cp "$SOURCE_APP/Contents/Info.plist" "$QA_APP/Contents/Info.plist"
if [[ -f "$SOURCE_APP/Contents/Resources/AppIcon.icns" ]]; then cp "$SOURCE_APP/Contents/Resources/AppIcon.icns" "$QA_APP/Contents/Resources/AppIcon.icns"; fi
python3 - "$QA_APP/Contents/Info.plist" "$QA_RUN_ROOT/profile" <<'PY'
import plistlib, sys, time
p=sys.argv[1]
with open(p,'rb') as f: info=plistlib.load(f)
info.update(CFBundleIdentifier='com.toymakers.curve.qa',CFBundleDisplayName='Curve QA',CFBundleName='Curve QA',CFBundleVersion=str(int(time.time())),CurveDataDirectory=sys.argv[2],CurveUITestMode=True)
info.pop('CFBundleURLTypes',None)
with open(p,'wb') as f: plistlib.dump(info,f)
PY
codesign --force --deep --sign - "$QA_APP"
print "$QA_APP"
