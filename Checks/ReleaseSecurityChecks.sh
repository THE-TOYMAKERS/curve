#!/bin/zsh
# Exercise real code-signature flags/entitlements and filter tampering checks.
# The synthetic app is never launched and contains no browser/user data.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/security-checks
curve_check_tmp=$(mktemp -d "$PWD/.build/security-checks/release.XXXXXX")
trap 'rm -rf "$curve_check_tmp"' EXIT HUP INT TERM
curve_probe="$curve_check_tmp/Curve.app"
mkdir -p "$curve_probe/Contents/MacOS" "$curve_probe/Contents/Resources"
clang -x c -o "$curve_probe/Contents/MacOS/Curve" - <<'C'
int main(void) { return 0; }
C
python3 - Info.plist "$curve_probe/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
info['LSFileQuarantineEnabled'] = True
with open(sys.argv[2], 'wb') as destination:
    plistlib.dump(info, destination)
PY
cp -R Resources/Protection "$curve_probe/Contents/Resources/Protection"
export CURVE_SIGNING_IDENTITY=- CURVE_NOTARIZE=0 CURVE_REQUIRE_DEVELOPER_ID=0 CURVE_REQUIRE_NOTARIZATION=0 CURVE_EXPECT_UNIVERSAL=0
./Scripts/sign-app.sh "$curve_probe" > "$curve_check_tmp/output.log" 2>&1
print 'PASS: actual ad hoc signature contains Hardened Runtime, sandbox entitlements and sealed filters.'

expect_rejected() {
  local curve_label="$1"
  shift
  if "$@" > "$curve_check_tmp/output.log" 2>&1; then
    print -u2 "FAIL: $curve_label was accepted."
    exit 1
  fi
  print "PASS: $curve_label rejected."
}

expect_rejected 'notarization without Developer ID credentials' env CURVE_NOTARIZE=1 ./Scripts/sign-app.sh --check
expect_rejected 'explicitly required Developer ID with ad hoc identity' env CURVE_REQUIRE_DEVELOPER_ID=1 ./Scripts/sign-app.sh --check
expect_rejected 'missing requested Developer ID identity' env CURVE_SIGNING_IDENTITY='Developer ID Application: Missing Certificate' CURVE_TEAM_ID=ABCDEFGHIJ ./Scripts/sign-app.sh --check

codesign --force --sign - --options 0 --entitlements Curve.entitlements --timestamp=none "$curve_probe" >/dev/null 2>&1
expect_rejected 'app without Hardened Runtime' ./Scripts/verify-app.sh "$curve_probe"

python3 - Curve.entitlements "$curve_check_tmp/unsafe.entitlements" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    value = plistlib.load(source)
value['com.apple.security.cs.disable-library-validation'] = True
with open(sys.argv[2], 'wb') as destination:
    plistlib.dump(value, destination)
PY
codesign --force --sign - --options runtime --entitlements "$curve_check_tmp/unsafe.entitlements" --timestamp=none "$curve_probe" >/dev/null 2>&1
expect_rejected 'app with an unsafe library-validation entitlement' ./Scripts/verify-app.sh "$curve_probe"

python3 - Curve.entitlements "$curve_check_tmp/unsandboxed.entitlements" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    value = plistlib.load(source)
value.pop('com.apple.security.app-sandbox')
with open(sys.argv[2], 'wb') as destination:
    plistlib.dump(value, destination)
PY
codesign --force --sign - --options runtime --entitlements "$curve_check_tmp/unsandboxed.entitlements" --timestamp=none "$curve_probe" >/dev/null 2>&1
expect_rejected 'app missing the App Sandbox entitlement' ./Scripts/verify-app.sh "$curve_probe"

printf '\n# tampered synthetic copy\n' >> "$curve_probe/Contents/Resources/Protection/ads.txt"
codesign --force --sign - --options runtime --entitlements Curve.entitlements --timestamp=none "$curve_probe" >/dev/null 2>&1
expect_rejected 'changed filter payload with a valid code signature but stale manifest' ./Scripts/verify-app.sh "$curve_probe"

print 'PASS: all release security checks.'
