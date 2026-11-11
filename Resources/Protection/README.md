# Curve protection data

Curve bundles the **Wild_Ads** and **Wild_Tracking** domain lists maintained by [ShadowWhisperer/BlockLists](https://github.com/ShadowWhisperer/BlockLists), pinned to revision `3a0c0fcd8b22163e4d295eea1a6bca580518227e` (November 11, 2026). The upstream **Unlicense** permits modification and redistribution; its complete text is included in `LICENSE-ShadowWhisperer.txt`.

- `ads.txt` is an unchanged copy of upstream `RAW/Wild_Ads` (20,411 domains).
- `trackers.txt` is an unchanged copy of upstream `RAW/Wild_Tracking` (17,801 domains).
- `manifest.json` records their local filenames, sizes and SHA-256 hashes. `ContentProtection.swift` pins the same hashes and revision so missing or changed assets stop a protected load rather than silently disabling protection.

The combined 38,212 domains are about 553 KiB of source data. Only the ad and tracking categories are included; Curve does not silently add political, adult-content, AI, VPN, DNS, or other unrelated category filters. The source lists are data, not executable code. The app compiles them locally into WebKit content rules and makes no runtime network requests to update filters or report browsing.

Balanced mode blocks listed domains on third-party resource loads and hides common advertising slots. Strict mode also blocks those domains on first-party loads, strips third-party cookies, blocks a small set of ad-delivery resource paths, and applies additional cosmetic selectors. Strict mode can break a site, including advertising/analytics providers' own sites; switching to Balanced permits first-party requests for compatibility. The current UI has no per-site off exceptions.

These lists and cosmetic rules reduce ads and tracking. They cannot guarantee an ad-free web: first-party sponsored posts, changing ad delivery, server-inserted video ads, and newly created domains can evade filters. Cosmetic hiding does not itself prove a resource was prevented from loading. No request-count claim should be inferred from the number of bundled domains.

Filter updates are shipped through reviewed app releases. To refresh a snapshot, review the upstream category changes and license at an exact revision, replace the two raw files, update the manifest and the pins/count in `ContentProtection.swift`, increment `ProtectionRules.formatVersion` if rule logic changes, then run the real WebKit protection checks. Never replace an asset with an unreviewed runtime fetch or reuse the same rule-cache identifier for different rule contents.
