# Curve

<img src="Resources/AppIcon-1024.png" width="96" height="96" alt="Curve app icon">

A small native macOS browser built around a sidebar, spaces, and keyboard navigation. Curve uses SwiftUI, AppKit, and the WebKit engine supplied by macOS. It has no bundled Chromium runtime, third-party package dependencies, or required browser account.

[Download Curve for macOS](https://github.com/THE-TOYMAKERS/curve/releases/latest/download/Curve-macOS.zip) · [Releases](https://github.com/THE-TOYMAKERS/curve/releases) · [Source](https://github.com/THE-TOYMAKERS/curve)

## Download

The release ZIP contains **Curve.app**, a universal app for **Apple silicon and Intel Macs running macOS 14 or later**. Expand it and move Curve.app to Applications. Release notes include the version and SHA-256 checksum. The Apple silicon build has been tested locally; Intel has been cross-compiled but has not been run on an Intel Mac.

**Curve 0.3.0 is experimental.** The download is ad hoc signed and has no Developer ID signature or Apple notarization. macOS may decline to open it. A Developer ID signed, notarized release is required for normal trusted public distribution.

Curve is an independent project inspired by Arc. It is not affiliated with Arc or The Browser Company and does not require an Arc service.

## Everyday use

- **⌘T** opens the command bar for a new address, search, existing tab, or action.
- **⌘L** edits the current address; **⌘S** shows or hides the sidebar.
- **⌘D** pins or unpins; **⌘W** closes a Today tab or resets a pinned tab.
- **⇧⌘T** restores the last archived tab; **⇧⌘K** clears Today tabs.
- **⌘1–⌘8** selects a tab; **⌘9** selects the last tab. **⌃1–⌃9** selects a space.
- **⌥⌘↑ / ⌥⌘↓** moves between tabs; **⌥⌘← / ⌥⌘→** moves between spaces.
- **⇧⌘C** copies the address; **⌥⇧⌘C** copies it as Markdown.
- **⌘F**, **⌘R**, **⌘+ / ⌘− / ⌘0**, and native Edit commands work in the focused page.

Right-click tabs, folders, or spaces for editing actions. Drag tabs to reorder them, move them into folders or spaces, or create a split. Split View supports two panes. Use the File menu for normal, private, and Little Curve windows, and Settings for appearance, search, archiving, and the live-tab budget.

Run **Import from Arc** in the command bar to import local sidebar spaces, tabs, folders, and themes. The importer reads sidebar JSON; it does not transfer passwords, cookies, history, extensions, or login sessions.

## Build from source

Use a Mac with Apple Command Line Tools and Swift 5.9 or later. No package installation is required by this project.

```sh
git clone https://github.com/THE-TOYMAKERS/curve.git
cd curve
./build.sh
open Curve.app
```

The script makes an optimized app for the host architecture and signs it ad hoc. The published app contains both `arm64` and `x86_64` executables. Intel compilation passes, but Intel runtime behavior remains unverified.

To reproduce the universal ZIP and its checksum with Apple's local toolchain:

```sh
./Scripts/package-release.sh
```

The output is `dist/Curve-macOS.zip` and `dist/SHA256SUMS.txt`. Generated builds and archives are ignored by Git.

For development or the Foundation-only checks:

```sh
swift run --disable-sandbox Curve
swift run --disable-sandbox CoreChecks
```

`--disable-sandbox` applies to Swift Package Manager's build process. WebKit website process isolation and TLS certificate validation remain enabled.

## Local data and tab memory

Normal session metadata is stored in `~/Library/Application Support/Curve/`, with atomic saves and a previous-valid-save backup. History is bounded to 2,000 recent addresses. Normal windows share website cookies and save their window sessions separately. Incognito uses a separate nonpersistent WebKit store and does not save session metadata or history; files deliberately downloaded by the user remain on disk.

Curve was previously named Aperture. Quit Aperture before Curve's first default launch so its latest session has been saved. Curve then copies the previous app's session/history files and saved per-window session folders into its own data directory. It leaves the Aperture directory unchanged and does not overwrite an existing Curve directory; this is a one-time copy, with no ongoing sync. Saved `aperture://start` addresses become `curve://start`. Explicit development/QA data-directory overrides bypass migration. The new bundle identity uses separate WebKit website data, so cookies and existing website logins are not transferred. Prior extra-window metadata is retained, but automatic restoration of all old native windows is not promised. Keep the previous app and its data until you have checked the migrated session.

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
