# Curve

<img src="Resources/AppIcon-1024.png" width="96" height="96" alt="Curve app icon">

A small native macOS browser built around a sidebar, spaces, keyboard navigation, and private browsing. Curve uses SwiftUI, AppKit, and the WebKit engine supplied by macOS. It has no bundled Chromium runtime, third-party package dependencies, required browser account, or analytics client.

[Download Curve for macOS](https://github.com/THE-TOYMAKERS/curve/releases/latest/download/Curve-macOS.zip) · [Releases](https://github.com/THE-TOYMAKERS/curve/releases) · [Source](https://github.com/THE-TOYMAKERS/curve)

## Download

The release ZIP contains **Curve.app**, a universal app for **Apple silicon and Intel Macs running macOS 14 or later**. Expand it and move Curve.app to Applications. Release notes include the version and SHA-256 checksum. The Apple silicon build has been tested locally; Intel has been cross-compiled but has not been run on an Intel Mac.

**Curve 0.4.0 is an experimental privacy release candidate in this branch.** It enables App Sandbox and Hardened Runtime. Its public release is pending Developer ID signing and Apple notarization. The stable download above remains **0.3.1** and does **not** include the 0.4 privacy changes described below. These hardening changes and automated checks are not an independent security audit or a claim of Chrome, Safari, or Brave security parity.

Curve is an independent project inspired by Arc. It is not affiliated with Arc or The Browser Company and does not require an Arc service.

### First launch of the current preview

The current ZIP is an unnotarized preview. If macOS says Apple cannot verify Curve or check it for malicious software:

1. Expand the ZIP and move **Curve.app** to **Applications**.
2. Try opening Curve once, then choose **Done** or **Cancel** in the warning.
3. Open **System Settings → Privacy & Security**, scroll to the security section, and click **Open Anyway** for Curve.
4. Confirm **Open** and authenticate if asked. macOS saves an exception for that app.

Starting with macOS Sequoia, **Control-click → Open** no longer overrides Gatekeeper for incorrectly signed or unnotarized apps. The Terminal command `open "/Applications/Curve.app"` also does not grant an exception; it launches Curve normally after approval. See [Apple's opening instructions](https://support.apple.com/en-us/102445) and [the Sequoia change](https://developer.apple.com/news/?id=saqachfa).

If the warning instead says the app **is damaged** or **will damage your computer**, do not treat it as this ordinary verification warning. Re-download from the release page, compare the published SHA-256, and report the exact message.

For a download that opens under normal Gatekeeper settings, Curve needs a **Developer ID Application** signature and **Apple notarization** with a stapled ticket. This distribution method does not require a Mac App Store listing. The current preview has not completed that process; see [Apple's Developer ID distribution guidance](https://developer.apple.com/developer-id/).


## Privacy and Shields

- **Private windows by default.** New windows and startup use a temporary website-data store and do not save tabs or history. File → New Persistent Window deliberately enables saved sessions and website logins. Change the default in Curve Shields.
- **Strict native blocking.** A pinned, bundled Unlicense list covers 38,212 ad/tracker domains. WebKit applies network rules before requests and hides common ad placements. Strict also blocks recognized first-party ad paths and strips third-party cookies. Balanced limits domain network blocking to third-party requests and uses fewer cosmetic rules.
- **No unfiltered first load.** A page waits for verified blocking lists. Missing, altered, or uncompileable lists stop the page instead of silently disabling protection. Cold compilation can take several seconds; WebKit caches the compiled rules.
- **HTTPS by default.** Public HTTP navigations upgrade to HTTPS without falling back if TLS fails. Explicit loopback addresses retain HTTP for local tools. Insecure public form submissions are rejected rather than replayed. Normal certificate checks and WebKit fraudulent-site warnings stay enabled.
- **Optional script blocking and Global Privacy Control.** GPC is sent on initial native page requests and exposed through `navigator.globalPrivacyControl`; it is not injected into every subresource request. Sites may ignore it. No fingerprint-spoofing or anonymity claim is made.
- **Coordinated data clearing.** Shields clears selected history, archives, recovery files, cookies/cache/site data, and optionally saved tabs across windows. Clearing website data closes Today tabs and signs sites out; retained pins are intentional bookmarks. The operation does not erase exported/downloaded files, old unsandboxed profiles, external backups, or filesystem snapshots.

Open **Curve Shields** beside the address field or from the Privacy menu. Changing protection settings destroys and reloads open documents, so save unfinished forms first. Protection is not globally disabled by a saved preference. No ads are replaced with Curve ads or a rewards program. Filtering happens locally; browsing addresses are not uploaded to a blocking service.

**Ads can still appear.** First-party content, server-inserted video ads, new ad domains, and site changes can evade these rules. Strict blocking can also break sites. Bundled lists are updated through app releases; see [Resources/Protection](Resources/Protection/README.md) for the exact source, snapshot and license. Curve does not promise an ad-free internet.

**Private browsing is not anonymity.** Websites, the selected search engine and the network provider can still observe traffic. Private downloads, exports and clipboard contents can remain after the window closes. Normal Spaces share one website profile and are not isolated accounts.

## Everyday use

- **⌘T** opens the command bar for a new address, search, existing tab, or action.
- **⌘L** edits the current address; **⌘S** shows or hides the sidebar.
- **⌘D** pins or unpins; **⌘W** closes a Today tab or resets a pinned tab.
- **⇧⌘T** restores the last archived tab; **⇧⌘K** clears Today tabs.
- **⌘1–⌘8** selects a tab; **⌘9** selects the last tab. **⌃1–⌃9** selects a space.
- **⌥⌘↑ / ⌥⌘↓** moves between tabs; **⌥⌘← / ⌥⌘→** moves between spaces.
- **⇧⌘C** copies the address; **⌥⇧⌘C** copies it as Markdown.
- **⌘F**, **⌘R**, **⌘+ / ⌘− / ⌘0**, and native Edit commands work in the focused page.

Right-click tabs, folders, or spaces for editing actions. Drag tabs to reorder them, move them into folders or spaces, or create a split. Split View supports two panes. Use the File menu for private, persistent, and Little Curve windows, and Settings for appearance, search, archiving, and the live-tab budget. Little Curve is temporary and uses its own private website store.

Run **Import from Arc** in the command bar to import local sidebar spaces, tabs, folders, and themes. The importer reads sidebar JSON; it does not transfer passwords, cookies, history, extensions, or login sessions.

App Sandbox no longer grants automatic access to earlier unsandboxed Curve or Arc profiles. Use **File → Import Saved Curve Session…** to select an earlier `state.json` or exported session, or choose Arc's sidebar file through its import dialog. A private-window import remains temporary; use a persistent window to retain it. Previous profile files are not modified or deleted.

## Build from source

Use a Mac with Apple Command Line Tools and Swift 5.9 or later. No package installation is required by this project.

```sh
git clone https://github.com/THE-TOYMAKERS/curve.git
cd curve
./build.sh
open Curve.app
```

The script makes an optimized app for the host architecture, signs it ad hoc with Hardened Runtime and least-privilege sandbox entitlements, and verifies the bundle and blocking assets. The published app contains both `arm64` and `x86_64` executables. Intel compilation passes, but Intel runtime behavior remains unverified.

To reproduce the universal ZIP and its checksum with Apple's local toolchain:

```sh
./Scripts/package-release.sh
```

The output is `dist/Curve-macOS.zip` and `dist/SHA256SUMS.txt`. Generated builds and archives are ignored by Git.

For Developer ID distribution, provision the certificate/private key in the local keychain and an existing `notarytool` keychain profile, then set `CURVE_SIGNING_IDENTITY`, `CURVE_TEAM_ID`, `CURVE_NOTARY_PROFILE`, and `CURVE_NOTARIZE=1` before running the packaging script. The script fails if those requirements are missing, verifies the publisher and runtime entitlements, submits to Apple, and staples the accepted ticket before making the final ZIP. Credentials are never stored in the repository. An Apple Developer Program account is required; a Mac App Store listing is not.

See [SIGNING.md](SIGNING.md) for the local certificate/keychain setup and verification of the extracted final download.

The approved Ribbon C artwork is saved in `Resources/Curve-Ribbon-C.png`. Run `./Scripts/make-icon.sh` to regenerate the app's PNG preview and complete macOS ICNS sizes from that source. See [Resources/README.md](Resources/README.md) for the asset record.

For development or the Foundation-only checks:

```sh
swift run --disable-sandbox Curve
swift run --disable-sandbox CoreChecks
```

`--disable-sandbox` applies to Swift Package Manager's build process. The `swift run` development executable is not the signed App Sandbox bundle; use `./build.sh` and Curve.app when testing actual release containment. WebKit website process isolation and TLS certificate validation remain enabled.

## Local data and tab memory

Persistent session metadata is stored inside the sandbox, normally `~/Library/Containers/com.toymakers.curve/Data/Library/Application Support/Curve/`, with atomic saves and a previous-valid-save backup. Profile directories have owner-only permissions (`0700`); metadata and backups use `0600` with extended ACL grants removed. Descriptor-relative operations reject symlink/hardlink substitutions. These controls do not encrypt history: persistent records still contain full URLs and titles. History is bounded to 2,000 recent addresses. Private windows use separate nonpersistent WebKit stores and do not save session metadata or history.

Curve was previously named Aperture. Version 0.3 used an unsandboxed data location; those old files and any exports remain outside 0.4's clear-data operation. Keep the previous files until you have explicitly imported and checked the tabs you want. No website passwords or cookies are transferred by session import.

The update checker is user-triggered, uses an ephemeral connection to the official GitHub release endpoint, and opens only a constructed release-page URL. It never downloads, executes or installs an update. Automatic installation is not implemented.

Web views are created when needed. The default soft live-tab budget is six; eligible background documents above that budget unload and reload when selected. Selected tabs, split panes, Peek, detected unfinished forms, and media may remain live. Detection is best effort, and unloaded documents lose their in-memory state and back/forward history. The budget is not a hard RAM limit.

The small app bundle does not represent total browser memory: macOS also launches WebKit rendering and networking processes. This release makes no universal speed or RAM superiority claim.

## Validation and limitations

```sh
./run-checks.sh
```

The full suite covers core state, keyboard routing, shortcut actions, drag logic, browser-store behavior, and native WebKit smoke/private tests. WebKit checks need a logged-in macOS desktop session in which the operating system can launch its website helpers. CI performs the build, Foundation checks, keyboard-router checks, and bundle verification; it does not replace live-window testing.

[VALIDATION.md](VALIDATION.md) separates predecessor test evidence from Curve release checks. [E2E-CHECKLIST.md](E2E-CHECKLIST.md) keeps partial and unverified interactions visible. [Checks/QA-Fixture](Checks/QA-Fixture/README.md) provides synthetic local pages and an isolated QA profile; generated apps, profiles, caches, and personal browser data are excluded from the repository.

Curve does not provide full Arc feature or visual parity. Chrome extensions, Arc sync, Boosts, Easels, Arc AI features, arbitrary split groups, and Chromium-specific DRM/media behavior are not implemented. There is one regular website profile plus isolated private windows, with no cross-device sync. Website compatibility, accessibility, motion, and native interaction variants need broader daily-use testing before relying on Curve as a production replacement.

## Source layout

| Path | Contents |
| --- | --- |
| `Sources/BrowserCore` | Models, URL handling, Arc sidebar import, session persistence, and history |
| `Sources/Curve` | Native windows, sidebar, command bar, panels, WebKit lifecycle, and interaction handling |
| `Tests/BrowserCoreTests` | Foundation-only executable checks |
| `Checks` | Keyboard, store, drag, WebKit, and isolated browser fixtures |
| `Resources` | App icon assets |
