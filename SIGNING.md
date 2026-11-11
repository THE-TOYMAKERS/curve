# Sign and notarize Curve outside the Mac App Store

Developer ID distribution does not require a Mac App Store listing. It requires an Apple Developer Program membership, a **Developer ID Application** certificate with its matching private key in the local keychain, and notarization credentials. An Apple Development or Mac App Distribution certificate is not a substitute.

## One-time local setup

1. In Xcode, open **Settings → Accounts**, choose the intended Apple Developer team, open **Manage Certificates**, and create/install a **Developer ID Application** certificate. Alternatively follow [Apple's Developer ID certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates). Creating a new local certificate requires the appropriate Account Holder role; cloud-managed certificates have different role requirements.
2. Confirm the certificate appears with its private key in Keychain Access → My Certificates. A downloaded `.cer` without its matching private key cannot sign the app. Keep private keys in Keychain; never add a private key, `.p12`, password or API key to this repository.
3. Create an Apple app-specific password and save notarization credentials using your own Terminal:

   ```sh
   xcrun notarytool store-credentials CurveNotary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```

   The command prompts securely for the app-specific password and validates it before storing it in Keychain. Do not add `--password` to scripts or paste passwords into chat. See [Apple's notarytool credential guidance](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).

## Build the final download

Run the checks before packaging:

```sh
./run-checks.sh
./Checks/SandboxChecks.sh
```

Use the intended certificate name or its 40-character certificate fingerprint. The Team ID must be the certificate's actual ten-character Apple Developer Team ID:

```sh
CURVE_SIGNING_IDENTITY='Developer ID Application: YOUR PUBLISHER (YOURTEAMID)' \
CURVE_TEAM_ID='YOURTEAMID' \
CURVE_NOTARY_PROFILE='CurveNotary' \
CURVE_NOTARIZE=1 \
./Scripts/package-release.sh
```

The script checks the local identity before building, creates both CPU architectures, signs with Hardened Runtime and the reviewed App Sandbox entitlements, verifies the publisher, submits to Apple, requires an **Accepted** result, staples the ticket, and checks Gatekeeper before producing the final ZIP and SHA-256 checksum. Missing identity/profile information fails rather than silently producing a preview in a requested notarized workflow. The default local preview remains explicitly ad hoc and unnotarized.

## Verify the artifact people actually download

Extract `dist/Curve-macOS.zip` to a temporary directory with `ditto`, then run the verifier against the **extracted** Curve.app:

```sh
CURVE_TEAM_ID='YOURTEAMID' \
CURVE_REQUIRE_DEVELOPER_ID=1 \
CURVE_REQUIRE_NOTARIZATION=1 \
CURVE_EXPECT_UNIVERSAL=1 \
./Scripts/verify-app.sh /path/to/extracted/Curve.app
```

This checks the sealed signature, publisher, secure timestamp, runtime/sandbox entitlements, bundled filters, both architectures, stapled ticket and Gatekeeper assessment. Compare the ZIP's SHA-256 with `dist/SHA256SUMS.txt` after uploading it. Never replace a versioned release asset silently after publishing its checksum.

Notarization is Apple's automated signature/malware screening. It is not an independent security audit of a browser. Current adversarial-test limitations remain documented in SECURITY.md and VALIDATION.md.
