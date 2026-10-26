# Security

Curve is experimental browser software. It has not received an independent security audit. The current downloadable build is ad hoc signed and is not notarized by Apple.

Website execution uses the WebKit runtime supplied by macOS. Keep macOS updated to receive WebKit fixes. Curve's native interaction bridge is isolated from ordinary website scripts, and private windows use nonpersistent website-data stores; these design choices do not constitute a security or privacy certification.

For a non-sensitive bug, open a repository issue with a reproducible synthetic example. Do not include passwords, cookies, browser profile files, authentication tokens, private website URLs, or unfinished personal documents in public reports. Security-sensitive findings should be shared through an existing private channel with the Toymakers maintainers rather than posted publicly.
