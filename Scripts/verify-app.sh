#!/bin/zsh
# Verify the production app's actual signature, entitlements and bundled filters.
set -euo pipefail
cd "$(dirname "$0")/.."
if (( $# != 1 )); then
  print -u2 'Usage: Scripts/verify-app.sh /path/to/Curve.app'
  exit 2
fi
curve_app="${1:A}"
codesign --verify --deep --strict "$curve_app"
python3 - "$curve_app" <<'PY'
import hashlib, json, os, pathlib, plistlib, re, subprocess, sys
app = pathlib.Path(sys.argv[1])
def fail(message):
    raise SystemExit(message)
with (app / 'Contents/Info.plist').open('rb') as handle:
    info = plistlib.load(handle)
if info.get('CFBundleIdentifier') != 'com.toymakers.curve' or info.get('CFBundleExecutable') != 'Curve':
    fail('Not the production Curve bundle identity/executable.')
if info.get('LSFileQuarantineEnabled') is not True:
    fail('LSFileQuarantineEnabled must be true in the released app.')
details = subprocess.run(['/usr/bin/codesign', '-dvvv', str(app)], capture_output=True, text=True, check=True).stderr
if not re.search(r'flags=0x[0-9a-fA-F]+\([^\n)]*\bruntime\b', details):
    fail('Hardened Runtime is missing from the actual code signature.')
entitlement_data = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)], capture_output=True, check=True).stdout
entitlements = plistlib.loads(entitlement_data)
required = {
    'com.apple.security.app-sandbox',
    'com.apple.security.network.client',
    'com.apple.security.files.user-selected.read-write',
    'com.apple.security.device.camera',
    'com.apple.security.device.microphone',
    'com.apple.security.device.audio-input',
}
if any(entitlements.get(key) is not True for key in required):
    fail('A required App Sandbox or resource entitlement is missing.')
identity_keys = {'com.apple.application-identifier', 'com.apple.developer.team-identifier'}
if set(entitlements) - required - identity_keys:
    fail('Unexpected production entitlements; inspect before distribution.')
developer_id = bool(re.search(r'^Authority=Developer ID Application:', details, re.M))
require_id = os.environ.get('CURVE_REQUIRE_DEVELOPER_ID') == '1' or os.environ.get('CURVE_NOTARIZE') == '1' or os.environ.get('CURVE_REQUIRE_NOTARIZATION') == '1' or os.environ.get('CURVE_SIGNING_IDENTITY', '-') != '-'
if require_id and not developer_id:
    fail('Developer ID Application signing was required but the actual signature does not have it.')
if developer_id:
    expected_team = os.environ.get('CURVE_TEAM_ID', '')
    if not re.fullmatch(r'[A-Z0-9]{10}', expected_team):
        fail('CURVE_TEAM_ID is required to verify the intended publisher.')
    if f'TeamIdentifier={expected_team}' not in details.splitlines():
        fail('The signed publisher does not match CURVE_TEAM_ID.')
    if not re.search(r'^Timestamp=', details, re.M):
        fail('A trusted signing timestamp is required for Developer ID distribution.')
protection = app / 'Contents/Resources/Protection'
manifest_path = protection / 'manifest.json'
if protection.is_symlink() or not protection.is_dir() or manifest_path.is_symlink() or not manifest_path.is_file():
    fail('Protection resources must be ordinary bundled files, not symlinks.')
with manifest_path.open('r', encoding='utf-8') as handle:
    manifest = json.load(handle)
if manifest.get('schemaVersion') != 1:
    fail('Unsupported protection manifest schema.')
entries = manifest.get('files')
if not isinstance(entries, list) or len(entries) != 2 or {e.get('path') for e in entries if isinstance(e, dict)} != {'ads.txt', 'trackers.txt'}:
    fail('Protection manifest must describe exactly ads.txt and trackers.txt.')
for entry in entries:
    asset = protection / entry['path']
    if asset.is_symlink() or not asset.is_file():
        fail('A protection asset is missing or is an unexpected symlink.')
    data = asset.read_bytes()
    if type(entry.get('bytes')) is not int or len(data) != entry['bytes'] or hashlib.sha256(data).hexdigest() != entry.get('sha256'):
        fail('A protection asset does not match its manifest checksum/size.')
if os.environ.get('CURVE_EXPECT_UNIVERSAL') == '1':
    architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(app / 'Contents/MacOS/Curve')], text=True).split()
    if set(architectures) != {'arm64', 'x86_64'}:
        fail('The public download must contain arm64 and x86_64 slices.')
print('Verified: sealed app, Hardened Runtime, least-privilege App Sandbox, quarantine flag, and protection asset integrity.')
print('Publisher: Developer ID Application.' if developer_id else 'Publisher: ad hoc preview; not Apple-verified.')
PY
if [[ "${CURVE_REQUIRE_NOTARIZATION-0}" == 1 ]]; then
  xcrun stapler validate "$curve_app"
  spctl --assess --type execute --verbose=2 "$curve_app"
fi
