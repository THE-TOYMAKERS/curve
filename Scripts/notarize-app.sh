#!/bin/zsh
# Submit only on explicit request, using credentials already stored in Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
if (( $# != 1 )); then
  print -u2 'Usage: CURVE_NOTARIZE=1 CURVE_NOTARY_PROFILE=profile Scripts/notarize-app.sh /path/to/Curve.app'
  exit 2
fi
if [[ "${CURVE_NOTARIZE-0}" != 1 ]]; then
  print -u2 'Notarization requires explicit CURVE_NOTARIZE=1.'
  exit 1
fi
./Scripts/sign-app.sh --check
curve_app="${1:A}"
CURVE_REQUIRE_DEVELOPER_ID=1 ./Scripts/verify-app.sh "$curve_app"
curve_notary_tmp=$(mktemp -d "${TMPDIR:-/tmp}/curve-notary.XXXXXX")
trap 'rm -rf "$curve_notary_tmp"' EXIT HUP INT TERM
COPYFILE_DISABLE=1 ditto -c -k --keepParent --noextattr --norsrc "$curve_app" "$curve_notary_tmp/Curve-upload.zip"
xcrun notarytool submit "$curve_notary_tmp/Curve-upload.zip" \
  --keychain-profile "$CURVE_NOTARY_PROFILE" --wait --output-format json > "$curve_notary_tmp/result.json"
curve_notary_status=$(plutil -extract status raw -o - "$curve_notary_tmp/result.json")
if [[ "$curve_notary_status" != Accepted ]]; then
  print -u2 "Apple notarization did not return Accepted (status: $curve_notary_status). No release ZIP will be produced."
  exit 1
fi
xcrun stapler staple "$curve_app"
CURVE_REQUIRE_DEVELOPER_ID=1 CURVE_REQUIRE_NOTARIZATION=1 ./Scripts/verify-app.sh "$curve_app"
print 'Apple accepted the submission; the app ticket was stapled and Gatekeeper assessment passed.'
