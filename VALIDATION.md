# Curve validation record

## Curve 0.3.0 release

Curve 0.3.0 (build 4) was checked on October 26, 2026, on an Apple silicon Mac with macOS 26.6.2 and Swift 6.2.1. It uses bundle identifier `com.toymakers.curve` and the new Curve icon. The prior app and its data were preserved.

- Optimized native build passed. The Intel cross-build also passed; Intel execution was not tested.
- The complete `./run-checks.sh` run exited 0: 16 core cases / 122 assertions, 66 keyboard-router checks, 82 shortcut-action checks, 32 store integration cases, 65 drag checks, and WebKit smoke/private suites. The [release check log](Checks/Results/0.3.0-checks.txt) records the run.
- Migration checks cover legacy start addresses, retained tab/archive identities, copied session/history and per-window metadata, source-byte preservation, protection of an existing Curve directory, and symlink rejection with staging cleanup.
- `Scripts/package-release.sh` produced the universal app with `x86_64` and `arm64` slices. Strict deep code-signature verification and ZIP CRC checks passed. The 3,404,952-byte ZIP contains only Curve.app, with no profiles, history, build cache, or Finder metadata payloads. Its SHA-256 is published beside the download.
- Live native smoke checks passed: the app opened as Curve with migrated spaces/tabs; Command-T opened the focused address field and loaded Example Domain; Command-Shift-N opened **Private · Curve** with `curve://start`; closing that window returned to the normal page, and closing the temporary test tab restored the original Apple page. These are specific smoke checks, not a complete new live interaction matrix.

The download targets macOS 14 or later. It is ad hoc signed, without a Developer ID signature or Apple notarization. Historical tests and pending interaction variants below are not reclassified as new Curve passes.

## Historical predecessor evidence — Aperture 0.2.1

The following predecessor checks were recorded on October 23, 2026, on an Apple silicon Mac running macOS 26.6.2, using Apple Command Line Tools and Swift 6.2.1. The tested application was Aperture 0.2.1 (build 3), targeting macOS 14 or later with a native `arm64` executable. Its release rebuild passed in 9.56 seconds, as did `codesign --verify --deep --strict`. It was ad hoc signed, with no Developer ID signature or Apple notarization. References to Aperture, its QA app identities, earlier fixture paths, and its versions in this historical record are intentional.

These checks establish specific working behavior in this development environment. They do not establish full Arc parity, universal website compatibility, or comparative browser performance.

## Automated and integration checks

The final complete 0.2.1 `./run-checks.sh` run exited 0 with its “All browser checks passed” marker: CoreChecks, the keyboard router, EngineSmoke, EnginePrivate, the 32-case StoreIntegration suite, ShortcutActionChecks, and the 65-case DragChecks suite all passed. The [packaged automated log](Checks/Results/0.2.1-checks.txt) preserves `work/qa-v2/release-021-final-checks.log`. This full run includes the final initial-window geometry regression and supersedes the earlier runs. The latest release rebuild and strict signature verification also passed. The additional WebKit integration, native-click, and failure-regression rows below record earlier development harnesses run separately.

| Check | Result | Coverage |
| --- | --- | --- |
| CoreChecks | V2: 13 checks, 94 assertions passed | URL resolution and blocked schemes; space selection and global favorites; pinned reset and reversible removal; archive protections; folders, moving and ordering; state repair; atomic saves and backup recovery; Arc import and deduplication; custom-name persistence and legacy decoding; history bounds and recovery; full Arc gradient/ink/noise import, theme-only refresh, and older-session appearance decoding. |
| Keyboard router | 66 cases passed | Requested macOS shortcuts, modifier combinations, numbered tabs and spaces, tab/space navigation, copy commands, window modes, split actions, history, find, and zoom routing. Routing a key is separate from implementing arbitrary extra split panes: only panes 1 and 2 currently exist. |
| ShortcutActionChecks | V2: 82 checks passed | Router-to-store actions, focused-pane state, clipboard output, and window callbacks. These exercise action effects without proving live key delivery, WebKit history/zoom behavior, or visible menu state. |
| DragChecks | V2: 65 checks passed | Local tab/folder/space commits, section and split moves, folder-cycle rejection, external URL validation, cross-window fresh-ID copying, cloned-folder path collisions, cancellation restoration, replay protection, drag survival, registered-target geometry, viewport clipping, original row midpoints, outside misses, cross-window release lifecycle, unique/valid folder paths, collision-safe subtree promotion, foreign-favorite menu demotion, and focused-split pin actions. Native pointer evidence is recorded separately below and in the live checklist. |
| StoreIntegration | 32 cases passed | Distinct split panes and focused-pane actions; custom names surviving page callbacks and disk roundtrip; escaped Markdown links; reversible clearing and restore; closing the last tab/window; all three window modes; pinned reset/removal; private session/history writes avoided and private shutdown clearing memory. Added regressions cover space duplication with remapped tab/folder identities and one global favorite, reversible space removal/restoration, stale pane focus after moving tabs, cross-space splits, preventing private tabs from seeding a new normal window or its saved state, restoring the saved Space selection, and safe handling of a missing restored pane. |
| EngineSmoke | Passed | HTML and title, JavaScript result, stable web-view identity, zoom, native find, live-view budget, active-view retention, releasing closed views, zero-size mounting followed by nonzero frame assignment, unmounted-host isolation, newest-mounted ownership, promotion when a host detaches, stale outgoing-host guards, and document retention during page-host handoff. |
| EngineIntegration | 12 groups passed | Public HTTPS page loads; title/URL callbacks; native back and forward; find; one new tab for a target-blank link; isolated page bridge; Peek routing; unsafe JavaScript URL rejection; a two-view budget across seven clean tabs; and edited-form protection. |
| Native WebKit UI harness | 6 cases passed | Actual target-blank click; actual Shift-click Peek; off-site navigation from a pinned tab opening Peek; contenteditable edits protecting a tab; page scripts unable to access the isolated native bridge; and an unsolicited timer-driven popup being blocked. |
| Private WebKit data stores | Passed | Private stores are nonpersistent while normal stores are persistent; tabs in one private engine share its store; separate private engines use distinct stores and isolated synthetic cookies; shutdown purges ephemeral cookies and releases views; a closed engine does not recreate sessions. |
| Failure and retry regression | Passed | First provisional navigation failure reports the error, retains the attempted URL and error state, and supports retry. |

The WebKit harnesses ran in a logged-in GUI session so macOS could launch its normal website and networking helper processes. The command execution sandbox prevented the required storage and LaunchServices operations, so those integration harnesses required execution outside that tool sandbox. Website process isolation and certificate validation remained enabled.

The v2 UI includes native Edit commands and Copy URL/Markdown/Quote actions, browser Find commands, and contextual space/tab/folder editing. Its sidebar uses 14-point San Francisco text, 36-point rows with 4-point gaps, a 224-point content width plus a 4-point divider, a 44-point header, and a 36-point search/address field. Native full-screen notifications adjust titlebar spacing without scaling those metrics. The first-window launch reveal and command-bar/Peek/sidebar/tab transitions have reduced-motion alternatives. Imported full-color themes include base and overlay gradients, intensity, text ink, appearance, and cached static grain. The older-session migration refreshes matching spaces' themes and updates the earlier default sidebar width; it does not reimport tabs or change selection.

The live [E2E-CHECKLIST.md](E2E-CHECKLIST.md) records observed key delivery and visible outcomes separately, including build-specific partial results and pending variants. On the earlier 0.2.0 52-check direct-gesture build, ten consecutive actual pointer drags retained the original 14 tab identities while exercising reorder, Today/Pinned/Favorite moves, collapsed-folder membership, folder nesting, descendant-cycle rejection, cross-space moves, and space ordering. Both page split-drop sides subsequently produced the expected real HTML panes without creating duplicates, and dragging the divider changed its accessibility value from 521.5 to 596.5. Quit/relaunch preserved reordered spaces, the moved Reading folder and its two child tabs, and all 14 original tabs.

Focused-pane live checks confirmed the right pane copied its exact Research URL, reloading the right pane retained a left-pane editable marker, reloading the left restored that page's original content, and left-pane Find/next/previous highlighted the actual text while leaving the right pane unchanged. Native full-screen entry retained the intended 228-point total sidebar width, 14-point text, 8-point page inset, and no additional header gap. The brief launch bloom was observed over an already loaded saved page and did not block interaction. These observations establish the specific paths tested; hover dwell, cross-window pointer delivery, separate Escape-drag cancellation, Reduce Motion, full geometry restoration, intermediate motion/feedback, and remaining menu/shortcut variants are still pending live. They do not establish full Arc feature or visual parity.

The exact sidebar resize retest passed after manual unlock. In a 1280×820-point window on a 2× display, a 60-physical-pixel handle drag changed saved width 224 → 254 points and the page edge 456 → 516 pixels; the reverse restored 224. Home's URL/load timestamp and sidebar typography remained intact. This run used the preserved profile after subsequent edits, starting at 12 tabs; the earlier 14-original-ID drag evidence above remains scoped to its recorded run.

Additional post-unlock live checks verified pin 212 returning from Third to its saved Home address with the same identity, Home reload changing timestamp 4:43:50 → 4:43:53 PM, equals-key zoom enlarging the ruler 400 → 440 physical pixels and reset returning it to 400 with unchanged chrome, filtered History opening the actual matching Third page, automatic Peek expansion into exactly one tab, and Shift-click Peek opening two real split panes. Native folder creation, rename/path updates, menu-based tab movement, and remove-while-keeping-tabs effects were verified in saved state.

A deeper split-close test originally left the surviving page white after removing the split. The rebuilt production app resolved that regression: repeated cached Controls 210 → Home 203 → Controls → Home switches showed actual HTML, and opening the existing Find 202 in Split View then closing the split immediately restored Home's real HTML and screenshot. Home's 5:07:27 timestamp and both saved tab IDs were retained. This retest started with nine tabs; it does not alter the separately scoped earlier 14-tab drag results. Sidebar hide/show also retained an edited Quicknote marker, page timestamp, and focus: subsequent typing appended to the same input. Motion quality remains unrecorded.

Further Space duplication/removal/restoration at a two-view budget exposed a related speculative-host ownership case. Version 0.2.1 registers only mounted hosts and promotes a remaining mounted host on detach. Its live retest passed: the copied Space restarted with actual Third HTML; removing the copy and using Spaces → Restore returned the exact copied Space/tab UUIDs and actual Third HTML/screenshot, without a white page. Native folder Open First Tab also displayed actual Alpha 204; creation, hierarchy rename, menu-based movement, and remove-while-keeping-tabs had already preserved their state and identities. Previous/next tab navigation traversed nested folder tabs and wrapped in both directions with URL confirmation.

Settings persistence passed during post-unlock QA. Native controls changed Studio's name to StudioQA, icon to ✦, and color to Peach E7C4AE; the actual chrome became peach and the saved imported theme cleared. Google search, Never auto archive, and a two-view live budget were selected. Full quit/relaunch retained all settings and nine saved tabs, with the Settings UI matching JSON. After QA exit, the original synthetic Studio name, icon, full theme, and preferences were restored from saved fields while keeping the test spaces and tabs.

A final new-window check reproduced an initially white page until native zoom. Immediate child-frame synchronization in WebContentHost's size callbacks, together with the initial native layout pass, fixed that path. A fresh separate `local.aperture.qa.final` instance from a copied synthetic profile then opened Window 2 through ⌘N with actual Third HTML and a screenshot on the next observation, without zooming or resizing. Window 1 retained the editable marker “Window one keeps its own document”; Window 2 initially showed its original text, then accepted “Window two has a separate document”. Native Window → first Aperture returned to Window 1 with its exact original marker; selecting Window 2 again showed actual Third HTML with its exact separate marker. Command-clicking Back to Second opened actual Second HTML, increased the tab count from 11 to 12, and added exactly one record for the intended new address.

The scoped live Incognito sequence also passed: its unique test URL loaded, closing the private window returned to normal Controls HTML with no private window, and quitting exited normally. Rebinding the automation client to the full QA app path resolved the stale accessibility binding; the sampled main thread was idle in the normal application event wait, without recursion or deadlock evidence. The unique private marker was absent from all eight isolated QA JSON files. These are observed results for that synthetic sequence, not a broad privacy certification. Remaining menu, settings, pointer, and motion variants stay recorded separately in the live checklist.

The native download Save panel wrote an 84-byte file exactly matching the synthetic fixture payload. The native upload Open panel selected that file, and the page's file input/text displayed its exact filename; this local fixture has no submit handler or POST. The Downloads panel showed the file as Complete. Native JavaScript Alert accepted Return, Confirm Cancel returned “Cancelled,” and Prompt returned the entered “ApertureQA” value to the page. Camera and microphone capture prompts remain untested, and these fixture results do not establish behavior on every site or device. Native window session restoration uses stable IDs; the observed quit/relaunch persistence is not a full system-restart restoration matrix.

## Arc sidebar inspection

The installed Arc sidebar was read directly and imported in memory: **3 spaces, 14 folders, and 33 web tabs**. Repeating the import produced identical state, and a JSON encode/decode roundtrip preserved that state. The initial inspection did not save imported state. The app’s Import from Arc action was subsequently exercised in the running browser and saved the imported sidebar locally. No imported URLs or titles are included in this report or the synthetic test fixture. Arc account, authentication, cookie, and password files were not read by the importer.

Imported nested folders store paths such as `Parent / Child` and render as collapsible branches in the sidebar. Arc-specific non-web items such as Easels are skipped. Importing addresses does not transfer website login sessions.

## Size and process observation

The final 0.2.1 native app bundle is approximately **5.3 MiB on disk**, including its icon. The distributable source excludes `.build` compiler caches and runtime profiles, including QA and imported personal profile data. The application uses SwiftUI, AppKit, and the WebKit engine shipped with macOS, with no third-party package dependencies or bundled Chromium runtime.

The latest v2 process snapshot observed the main app at approximately **125 MiB RSS** with **0.0% CPU** at that instant. That value describes the main application process only. A previous snapshot observed about 118 MiB for the main app while the visible setup included a two-pane local page and an empty private window; other existing processes were also present. No exclusive ownership of WebKit helper processes was established.

These are process snapshots, not total browser memory accounting or benchmarks. WebKit helpers are not summed into a claimed browser total. Site complexity, activity, media, and WebKit process sharing change resource use. No controlled Arc-versus-Aperture performance comparison was performed.

## Reproduce the portable suite

From the source directory, in a Terminal running in a logged-in macOS desktop account:

```sh
./run-checks.sh
```

The script builds and runs the core, keyboard router, shortcut action, drag, WebKit smoke/private, and browser-store checks. Source harnesses are included under `Checks/`; temporary binaries and caches go under `.build/checks/` and are excluded from the source archive. The portable [QA fixture](Checks/QA-Fixture/README.md) includes only synthetic site/scripts/instructions, with generated profiles and applications outside the packaged source. A passing synthetic or integration case does not automatically complete a row in the live checklist.

For the Foundation core checks alone:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/curve-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/curve-swift-cache \
swift run --disable-sandbox CoreChecks
```

An optional read-only import check accepts `--arc-sidebar /path/to/StorableSidebar.json`. It checks import idempotence and persistence roundtrip in memory without writing the imported session. The README documents the build, shortcuts, local storage, and remaining compatibility limits.
