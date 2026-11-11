#!/bin/zsh
# Local preview: ad hoc + App Sandbox + Hardened Runtime.
# Developer ID: set CURVE_SIGNING_IDENTITY and CURVE_TEAM_ID explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
curve_identity="${CURVE_SIGNING_IDENTITY--}"
curve_team="${CURVE_TEAM_ID-}"
curve_notarize="${CURVE_NOTARIZE-0}"
curve_require_identity="${CURVE_REQUIRE_DEVELOPER_ID-0}"
if [[ "$curve_notarize" != 0 && "$curve_notarize" != 1 ]] ||
   [[ "$curve_require_identity" != 0 && "$curve_require_identity" != 1 ]]; then
  print -u2 'CURVE_NOTARIZE and CURVE_REQUIRE_DEVELOPER_ID must be 0 or 1.'
  exit 1
fi
if [[ -z "$curve_identity" ]]; then
  print -u2 'CURVE_SIGNING_IDENTITY is empty; use - for an explicit ad hoc preview or a Developer ID Application identity.'
  exit 1
fi
if [[ "$curve_identity" == - ]]; then
  if [[ "$curve_notarize" == 1 || "$curve_require_identity" == 1 ]]; then
    print -u2 'A Developer ID Application signing identity and CURVE_TEAM_ID are required; ad hoc signing cannot satisfy this request.'
    exit 1
  fi
else
  if [[ ! "$curve_team" =~ '^[A-Z0-9]{10}$' ]]; then
    print -u2 'Set CURVE_TEAM_ID to the ten-character Apple Developer Team ID before Developer ID signing.'
    exit 1
  fi
  # Preflight against valid signing identities, without printing keychain data.
  CURVE_SIGNING_IDENTITY="$curve_identity" python3 - <<'PY'
import os, re, subprocess, sys
identity = os.environ['CURVE_SIGNING_IDENTITY']
result = subprocess.run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True, check=True)
matches = []
for line in result.stdout.splitlines():
    match = re.match(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"(.+)"\s*$', line)
    if match and (identity.upper() == match.group(1).upper() or identity == match.group(2)):
        matches.append(match.group(2))
if len(matches) != 1 or not matches[0].startswith('Developer ID Application:'):
    sys.exit('The requested identity is not one unambiguous valid Developer ID Application certificate in the keychain.')
PY
fi
if [[ "$curve_notarize" == 1 ]]; then
  if [[ -z "${CURVE_NOTARY_PROFILE-}" ]]; then
    print -u2 'CURVE_NOTARY_PROFILE must name an existing notarytool keychain profile; credentials are never embedded in source or arguments.'
    exit 1
  fi
  xcrun --find notarytool >/dev/null
  xcrun --find stapler >/dev/null
fi
plutil -lint Curve.entitlements >/dev/null
if [[ "${1-}" == --check ]]; then
  print 'Signing configuration checked.'
  exit 0
fi
if (( $# != 1 )); then
  print -u2 'Usage: Scripts/sign-app.sh /path/to/Curve.app | --check'
  exit 2
fi
curve_app="${1:A}"
if [[ ! -f "$curve_app/Contents/MacOS/Curve" ]]; then
  print -u2 'The Curve app executable is missing.'
  exit 1
fi
if [[ "$curve_identity" == - ]]; then
  codesign --force --sign - --options runtime --entitlements Curve.entitlements --timestamp=none "$curve_app"
else
  codesign --force --sign "$curve_identity" --options runtime --entitlements Curve.entitlements --timestamp "$curve_app"
fi
./Scripts/verify-app.sh "$curve_app"
