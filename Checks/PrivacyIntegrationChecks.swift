import AppKit
import Foundation
import WebKit
import BrowserCore

/// Synthetic profiles, injected in-memory WebKit stores and a disposable
/// preference suite. Never clears the user's normal WebKit store or profile.
@main
@MainActor
struct PrivacyIntegrationChecks {
    private static var assertions = 0
    private static var failures: [String] = []
    private static let fm = FileManager.default

    private struct Fixture {
        var state: BrowserState
        let pin: UUID
        let favorite: UUID
        let today: UUID
        let folder: UUID
    }
    private final class InterruptedRetirement: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.cancel)
        }
    }

    private static func check(_ passed: Bool, _ name: String) {
        assertions += 1
        if !passed { failures.append(name); print("FAIL: \(name)") }
    }
    private static func fixture(_ name: String, historyMarker: String) -> Fixture {
        let space = BrowserSpace(name: name, emoji: "T", colorHex: "BDB6DD")
        var state = BrowserState(spaces: [space], autoArchiveHours: 0)
        let folder = state.addFolder(name: "Retained pins", spaceID: space.id)
        let pin = state.open(url: "https://pin.privacy-fixture.invalid/\(name)", title: "\(name) pin", kind: .pinned, folderID: folder)
        let favorite = state.open(url: "https://favorite.privacy-fixture.invalid/\(name)", title: "\(name) favorite", kind: .favorite)
        let today = state.open(url: "https://today.privacy-fixture.invalid/\(name)", title: "\(name) Today")
        let archived = BrowserTab(title: historyMarker, url: "https://archive.privacy-fixture.invalid/?secret=\(historyMarker)", spaceID: space.id)
        state.archive = [ArchivedTab(tab: archived)]
        return Fixture(state: state, pin: pin, favorite: favorite, today: today, folder: folder)
    }
    private static func cookie(_ name: String) throws -> HTTPCookie {
        guard let result = HTTPCookie(properties: [.domain: "privacy-fixture.invalid", .path: "/", .name: name, .value: "synthetic-secret", .expires: Date().addingTimeInterval(3600)]) else {
            throw NSError(domain: "PrivacyIntegrationChecks.Cookie", code: 1)
        }
        return result
    }
    private static func containsCookie(_ name: String, in store: WKWebsiteDataStore) async -> Bool {
        await store.httpCookieStore.allCookies().contains { $0.name == name }
    }
    private static func evaluate(_ script: String, in view: WKWebView) async -> Any? {
        await withCheckedContinuation { continuation in
            view.evaluateJavaScript(script) { value, _ in continuation.resume(returning: value) }
        }
    }
    private static func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await predicate()
    }
    private static func metadataContains(_ marker: String, in root: URL) throws -> Bool {
        guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        for case let url as URL in entries where url.pathExtension == "json" {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
               let text = String(data: try Data(contentsOf: url), encoding: .utf8), text.contains(marker) { return true }
        }
        return false
    }
    private static func writeStateWithBackup(_ state: BrowserState, at directory: URL) throws {
        let persistence = StatePersistence(directory: directory)
        try persistence.save(state)
        try persistence.save(state)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task.detached {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            fputs("FAIL: Privacy integration checks timed out.\n", stderr)
            fflush(stderr)
            exit(1)
        }
        Task { @MainActor in
            do { try await runChecks() }
            catch { failures.append("fixture failed: \(error)"); print("FAIL: \(error)") }
            print("\(failures.isEmpty ? "PASS" : "FAIL"): Privacy integration checks: \(assertions) assertions; \(failures.count) failures")
            fflush(stdout)
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }

    private static func runChecks() async throws {
        let parent = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) : fm.temporaryDirectory
        let root = parent.appendingPathComponent("PrivacyIntegration-" + UUID().uuidString, isDirectory: true)
        let profile = root.appendingPathComponent("Profile", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let priorDirectory = ProcessInfo.processInfo.environment["CURVE_DATA_DIR"]
        setenv("CURVE_DATA_DIR", profile.path, 1)
        let suiteName = "test.curve.privacy." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw NSError(domain: "PrivacyIntegrationChecks.Defaults", code: 1) }
        defaults.removePersistentDomain(forName: suiteName)
        let preferenceKeys = ["privacy.privateByDefault", "privacy.protectionLevel", "privacy.httpsOnly", "privacy.blockJavaScript", "privacy.gpc"]
        let realPreferencesBefore = preferenceKeys.map { String(describing: UserDefaults.standard.object(forKey: $0)) }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            if let priorDirectory { setenv("CURVE_DATA_DIR", priorDirectory, 1) } else { unsetenv("CURVE_DATA_DIR") }
            try? fm.removeItem(at: root)
        }
        let settings = PrivacySettings(defaults: defaults)
        let sharedNormalData = WKWebsiteDataStore.nonPersistent()
        let coordinator = BrowserCoordinator(privacySettings: settings, persistentWebsiteDataStore: sharedNormalData)
        let ruleStoreDirectory = root.appendingPathComponent("RuleStore", isDirectory: true)
        try fm.createDirectory(at: ruleStoreDirectory, withIntermediateDirectories: true)
        guard let ruleStore = WKContentRuleListStore(url: ruleStoreDirectory) else { throw ContentProtectionError.unavailableRuleStore }
        let resourceDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Resources/Protection", isDirectory: true)
        let protection = ContentProtection(resourceDirectory: resourceDirectory, ruleStore: ruleStore)
        check(settings.privateByDefault && settings.httpsOnly && settings.protectionLevel == .strict && settings.sendGlobalPrivacyControl, "fresh preferences enable private-by-default and strict protection")
        let defaultWindow = coordinator.makeStore(mode: .normal)
        check(defaultWindow.mode == .incognito && defaultWindow.engine.isPrivate, "ordinary new windows honor private-by-default")
        defaultWindow.saveNow()
        check(!fm.fileExists(atPath: profile.appendingPathComponent("state.json").path), "private-by-default window does not write normal session data")
        defaultWindow.shutdown(); coordinator.unregister(defaultWindow)
        check(coordinator.nextPersistentSessionID() == BrowserCoordinator.mainID, "first explicit persistent window reuses the main saved profile")
        let explicitNormal = coordinator.makeStore(mode: .normal, respectPrivateDefault: false)
        check(explicitNormal.mode == .normal && !explicitNormal.engine.isPrivate, "explicit persistent window bypasses private default")
        check(coordinator.nextPersistentSessionID() != BrowserCoordinator.mainID, "additional persistent windows use separate saved window identities")
        explicitNormal.shutdown(); coordinator.unregister(explicitNormal)
        settings.privateByDefault = false
        let selectedNormal = coordinator.makeStore(mode: .normal)
        check(selectedNormal.mode == .normal, "private default can be deliberately disabled")
        selectedNormal.shutdown(); coordinator.unregister(selectedNormal)
        let requestedPrivate = coordinator.makeStore(mode: .incognito)
        check(requestedPrivate.mode == .incognito, "explicit private windows remain private with preference disabled")
        requestedPrivate.shutdown(); coordinator.unregister(requestedPrivate)
        let little = coordinator.makeStore(mode: .little)
        check(little.engine.isPrivate, "Little Curve stays private even when ordinary windows are persistent")
        little.shutdown(); coordinator.unregister(little)

        let marker = "HISTORY-TO-ERASE-" + UUID().uuidString
        let first = fixture("First", historyMarker: marker)
        let second = fixture("Second", historyMarker: marker)
        let closed = fixture("Closed", historyMarker: marker)
        let privateFixtureA = fixture("PrivateA", historyMarker: marker)
        let privateFixtureB = fixture("PrivateB", historyMarker: marker)
        let secondDirectory = profile.appendingPathComponent("Windows/" + UUID().uuidString, isDirectory: true)
        let closedDirectory = profile.appendingPathComponent("Windows/" + UUID().uuidString, isDirectory: true)
        try writeStateWithBackup(first.state, at: profile)
        try writeStateWithBackup(second.state, at: secondDirectory)
        try writeStateWithBackup(closed.state, at: closedDirectory)
        let visits = [HistoryEntry(title: marker, url: "https://history.privacy-fixture.invalid/?secret=\(marker)")]
        for directory in [profile, secondDirectory, closedDirectory] {
            try BrowsingHistory(directory: directory).save(visits)
            try BrowsingHistory(directory: directory).save(visits)
        }

        let privateDataA = WKWebsiteDataStore.nonPersistent()
        let privateDataB = WKWebsiteDataStore.nonPersistent()
        let normalA = BrowserStore(mode: .normal, directory: profile, seed: first.state, engine: WebEngine(websiteDataStore: sharedNormalData, privacySettings: settings, contentProtection: protection))
        let normalB = BrowserStore(mode: .normal, directory: secondDirectory, seed: second.state, engine: WebEngine(websiteDataStore: sharedNormalData, privacySettings: settings, contentProtection: protection))
        let privateA = BrowserStore(mode: .incognito, directory: root.appendingPathComponent("PrivateA"), engine: WebEngine(isPrivate: true, websiteDataStore: privateDataA, privacySettings: settings, contentProtection: protection))
        let privateB = BrowserStore(mode: .incognito, directory: root.appendingPathComponent("PrivateB"), engine: WebEngine(isPrivate: true, websiteDataStore: privateDataB, privacySettings: settings, contentProtection: protection))
        privateA.state = privateFixtureA.state; privateB.state = privateFixtureB.state
        privateA.recordHistory(title: marker, url: "https://private-a.privacy-fixture.invalid")
        privateB.recordHistory(title: marker, url: "https://private-b.privacy-fixture.invalid")
        var stores = [normalA, normalB, privateA, privateB]
        for store in stores { coordinator.register(store) }
        var windows: [NSWindow] = []
        for store in stores {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            store.window = window
            if let id = store.state.selectedTabID {
                let view = store.engine.webView(for: id, url: URL(string: "about:blank")!)
                view.frame = window.contentView?.bounds ?? .zero
                window.contentView?.addSubview(view)
            }
            windows.append(window)
        }
        defer {
            for store in stores { store.shutdown(); coordinator.unregister(store) }
            for window in windows { window.close() }
        }
        for store in stores { store.query = marker; store.findQuery = marker; store.toast = marker }
        normalA.saveSoon(); normalB.saveSoon()
        try await coordinator.eraseBrowsingData(history: true, websiteData: false, savedTabs: false)
        check(!coordinator.isErasingData, "global erasure exits its guarded state")
        check(stores.allSatisfy { $0.history.isEmpty && $0.state.archive.isEmpty }, "history and archives clear in every normal/private window")
        check(stores.allSatisfy { $0.query.isEmpty && $0.findQuery.isEmpty && $0.toast == nil }, "clearing removes old address/search/find text and transient messages")
        check(normalA.state.tabs == first.state.tabs && normalB.state.tabs == second.state.tabs, "history-only clearing retains live tabs, pins and favorites")
        check(normalA.state.folders == first.state.folders && normalB.state.folders == second.state.folders, "history-only clearing retains folders")
        check(BrowsingHistory(directory: profile).load().isEmpty, "shared persisted history is empty")
        check(!fm.fileExists(atPath: BrowsingHistory(directory: profile).backupURL.path), "shared history recovery backup is removed")
        let preservedClosed = StatePersistence(directory: closedDirectory).load()
        check(preservedClosed.tabs == closed.state.tabs && preservedClosed.folders == closed.state.folders, "history-only clearing preserves closed-window tabs, pins and folders")
        check(preservedClosed.archive.isEmpty, "closed-window archives are scrubbed")
        check(!fm.fileExists(atPath: closedDirectory.appendingPathComponent("state.backup.json").path), "closed-window old state backup cannot resurrect archives")
        check(!fm.fileExists(atPath: closedDirectory.appendingPathComponent("history.json").path) && !fm.fileExists(atPath: closedDirectory.appendingPathComponent("history.backup.json").path), "closed-window history and backup are erased")
        normalA.engine.onPageChanged?(first.today, "Late old redirect", "https://late.privacy-fixture.invalid/?stale=preclear")
        normalB.engine.onPageChanged?(second.today, "Late old title", second.state.tabs.first { $0.id == second.today }!.url)
        try? await Task.sleep(nanoseconds: 650_000_000)
        check(normalA.history.isEmpty && normalB.history.isEmpty && BrowsingHistory(directory: profile).load().isEmpty, "old title/redirect callbacks and deferred saves do not repopulate history")
        check(try !metadataContains(marker, in: profile), "old history/archive markers are absent from all saved metadata and backups")

        normalA.open("curve://start")
        let newVisitID = normalA.currentID!
        normalA.engine.onPageChanged?(newVisitID, "New deliberate visit", "https://new-visit.privacy-fixture.invalid")
        check(normalA.history.contains { $0.url == "https://new-visit.privacy-fixture.invalid" }, "an explicit new navigation can record new history after clearing")
        var retainedVisit = normalA.history
        let normalCookie = try cookie("normal-" + UUID().uuidString)
        let privateCookieA = try cookie("private-a-" + UUID().uuidString)
        let privateCookieB = try cookie("private-b-" + UUID().uuidString)
        let viewA = normalA.engine.webView(for: first.pin, url: URL(string: "about:blank")!)
        let viewB = normalB.engine.webView(for: second.pin, url: URL(string: "about:blank")!)
        let viewPrivateA = privateA.engine.webView(for: privateFixtureA.pin, url: URL(string: "about:blank")!)
        let viewPrivateB = privateB.engine.webView(for: privateFixtureB.pin, url: URL(string: "about:blank")!)
        check(viewA.configuration.websiteDataStore === viewB.configuration.websiteDataStore, "normal test windows share the injected website store")
        check(viewPrivateA.configuration.websiteDataStore !== viewPrivateB.configuration.websiteDataStore, "private test windows have separate website stores")
        check(!viewA.isInspectable && !viewPrivateA.isInspectable, "normal and private views disable production web inspection")
        await sharedNormalData.httpCookieStore.setCookie(normalCookie)
        await privateDataA.httpCookieStore.setCookie(privateCookieA)
        await privateDataB.httpCookieStore.setCookie(privateCookieB)
        check(await containsCookie(normalCookie.name, in: viewB.configuration.websiteDataStore), "normal cookie is shared across normal windows")
        check(await containsCookie(privateCookieA.name, in: privateDataA), "private window cookie fixture exists")
        let isolatedFromOtherPrivate = await !containsCookie(privateCookieA.name, in: privateDataB)
        let isolatedFromNormal = await !containsCookie(privateCookieA.name, in: sharedNormalData)
        check(isolatedFromOtherPrivate && isolatedFromNormal, "private cookie is isolated from other private and normal windows")
        let keptArchive = ArchivedTab(tab: BrowserTab(title: "Kept archive", url: "https://kept.privacy-fixture.invalid", spaceID: normalA.state.activeSpaceID))
        normalA.state.archive = [keptArchive]; normalA.saveNow()
        // A still-retained WKWebView represents old SwiftUI hosts or a pending
        // native callback. Detaching it must not leave its JavaScript timer able
        // to recreate cookies after global website-data removal.
        let writerCookieName = "writer-" + UUID().uuidString
        let writerHTML = "<html><head><title>Cookie writer</title></head><body><script>window.writerTicks=0;function write(){window.writerTicks++;document.cookie='\(writerCookieName)='+window.writerTicks+'; Path=/; SameSite=Lax; Secure';}write();window.writerTimer=setInterval(write,10);</script></body></html>"
        viewA.frame = windows[0].contentView?.bounds ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        windows[0].contentView?.addSubview(viewA)
        normalA.engine.openHTML(id: first.pin, html: writerHTML, baseURL: URL(string: "https://privacy-fixture.invalid")!)
        let writerStarted = await waitUntil {
            let ticks = await evaluate("window.writerTicks", in: viewA) as? NSNumber
            return (ticks?.intValue ?? 0) > 0 && normalA.engine.state(id: first.pin).protectionReady
        }
        check(writerStarted, "actual JavaScript cookie writer loads behind verified protection rules")
        check(await containsCookie(writerCookieName, in: sharedNormalData), "live document creates its synthetic cookie before erasure")

        let lateData = WKWebsiteDataStore.nonPersistent()
        let lateCookie = try cookie("late-normal-" + UUID().uuidString)
        await lateData.httpCookieStore.setCookie(lateCookie)
        let lateFixture = fixture("LateNormal", historyMarker: "Kept late archive")
        let lateStore = BrowserStore(mode: .normal, directory: profile.appendingPathComponent("Windows/" + UUID().uuidString), seed: lateFixture.state,
                                     engine: WebEngine(websiteDataStore: lateData, privacySettings: settings, contentProtection: protection))
        _ = lateStore.engine.webView(for: lateFixture.today, url: URL(string: "about:blank")!)
        let registration = Task { @MainActor () -> Bool in
            for _ in 0..<1000 {
                if coordinator.isErasingData { coordinator.register(lateStore); return true }
                await Task.yield()
            }
            return false
        }
        retainedVisit = normalA.history
        try await coordinator.eraseBrowsingData(history: false, websiteData: true, savedTabs: false)
        let joinedErasure = await registration.value
        check(joinedErasure, "new normal window registers while asynchronous erasure is in progress")
        if !joinedErasure { coordinator.register(lateStore) }
        stores.append(lateStore)
        check(lateStore.engine.liveCount == 0 && !lateStore.state.tabs.contains { $0.id == lateFixture.today }, "window joining erasure is quiesced with the same options")
        check(await !containsCookie(lateCookie.name, in: lateData), "window joining erasure has its website data cleared before completion")
        check(await !containsCookie(normalCookie.name, in: sharedNormalData), "website-data erasure clears shared normal cookies")
        let firstPrivateCleared = await !containsCookie(privateCookieA.name, in: privateDataA)
        let secondPrivateCleared = await !containsCookie(privateCookieB.name, in: privateDataB)
        check(firstPrivateCleared && secondPrivateCleared, "website-data erasure clears every private cookie store")
        check(stores.allSatisfy { $0.engine.liveCount == 0 }, "website-data erasure releases all old live documents")
        check(normalA.state.tabs.contains { $0.id == first.pin } && normalA.state.tabs.contains { $0.id == first.favorite } && normalB.state.tabs.contains { $0.id == second.pin }, "website-only erasure retains unselected pins and favorites")
        check(!normalA.state.tabs.contains { $0.id == first.today || $0.id == newVisitID } && !normalB.state.tabs.contains { $0.id == second.today }, "website-data erasure closes old Today tabs")
        check(normalA.state.tabs.contains { $0.url == "curve://start" }, "website-data erasure creates a clean local start tab")
        check(normalA.history == retainedVisit && normalA.state.archive == [keptArchive], "website-only erasure preserves unselected history and archives")
        let ticksImmediatelyAfterClearing = await evaluate("window.writerTicks", in: viewA) as? NSNumber
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        let ticksAfterSettling = await evaluate("window.writerTicks", in: viewA) as? NSNumber
        check(await !containsCookie(writerCookieName, in: sharedNormalData), "retained old document cannot recreate a cleared cookie")
        check(ticksAfterSettling == nil || ticksAfterSettling == ticksImmediatelyAfterClearing, "erased document JavaScript cannot continue its old timer")
        let freshView = normalA.engine.webView(for: first.pin, url: URL(string: "about:blank")!)
        check(freshView !== viewA, "an erased document cannot be reused")
        check(await !containsCookie(normalCookie.name, in: freshView.configuration.websiteDataStore), "fresh normal document cannot recover an erased cookie")

        try await coordinator.eraseBrowsingData(history: false, websiteData: false, savedTabs: true)
        check(stores.allSatisfy { $0.state.tabs.count == 1 && $0.state.tabs.first?.url == "curve://start" && $0.state.folders.isEmpty && $0.state.archive.isEmpty && $0.history.isEmpty }, "saved-tab erasure removes tabs, pins, folders, archives and history in all windows")
        check(stores.allSatisfy { $0.state.spaces.allSatisfy { $0.splitTabID == nil } }, "saved-tab erasure clears split references")
        check(!fm.fileExists(atPath: closedDirectory.appendingPathComponent("state.json").path) && !fm.fileExists(atPath: closedDirectory.appendingPathComponent("state.backup.json").path), "saved-tab erasure removes closed-window primary and recovery sessions")
        try? await Task.sleep(nanoseconds: 650_000_000)
        check(try !metadataContains(marker, in: profile), "erased data stays absent after pending save tasks settle")
        check(!fm.fileExists(atPath: root.appendingPathComponent("PrivateA/state.json").path) && !fm.fileExists(atPath: root.appendingPathComponent("PrivateB/state.json").path), "private windows never persist their session during global clearing")

        // A corrupt closed session must stop history-only clearing rather than
        // silently deleting the user's unselected saved tabs and pins.
        let corruptDirectory = profile.appendingPathComponent("Windows/" + UUID().uuidString, isDirectory: true)
        try SecureProfileStorage.writeData(Data("broken primary".utf8), named: "state.json", in: corruptDirectory)
        try SecureProfileStorage.writeData(Data("broken backup".utf8), named: "state.backup.json", in: corruptDirectory)
        try BrowsingHistory(directory: profile).save(visits)
        let beforeRoot = try Data(contentsOf: profile.appendingPathComponent("state.json"))
        let beforeHistory = try Data(contentsOf: profile.appendingPathComponent("history.json"))
        do { try ProfilePrivacy.eraseHistory(in: profile); check(false, "corrupt closed sessions must reject history-only clearing") }
        catch { check(true, "corrupt closed sessions reject history-only clearing") }
        check(try Data(contentsOf: profile.appendingPathComponent("state.json")) == beforeRoot && Data(contentsOf: profile.appendingPathComponent("history.json")) == beforeHistory, "failed preservation preflight leaves root content unchanged")
        try fm.removeItem(at: corruptDirectory)
        let recoveryDirectory = profile.appendingPathComponent("Windows/" + UUID().uuidString, isDirectory: true)
        try writeStateWithBackup(closed.state, at: recoveryDirectory)
        try Data("broken primary".utf8).write(to: recoveryDirectory.appendingPathComponent("state.json"))
        try ProfilePrivacy.eraseHistory(in: profile)
        let recovered = StatePersistence(directory: recoveryDirectory).load()
        check(recovered.tabs == closed.state.tabs && recovered.archive.isEmpty, "history-only clearing recovers and preserves pins from a valid backup")

        // Fault injection: intercept the retirement's native completion so its
        // bounded barrier cannot establish that the document was neutralized.
        // Clearing must fail before deleting cookies/history, and a later retry
        // must recover rather than leaving the global eraser stuck forever.
        let faultConfiguration = WKWebViewConfiguration()
        faultConfiguration.websiteDataStore = .nonPersistent()
        let interruptedView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: faultConfiguration)
        let interruption = InterruptedRetirement()
        let mustSurvive = try cookie("must-survive-failed-clear-" + UUID().uuidString)
        await sharedNormalData.httpCookieStore.setCookie(mustSurvive)
        try BrowsingHistory(directory: profile).save(visits)
        let beforeFailedClear = try Data(contentsOf: profile.appendingPathComponent("history.json"))
        WebDocumentRetirement.retire(interruptedView)
        interruptedView.navigationDelegate = interruption
        do {
            try await coordinator.eraseBrowsingData(history: true, websiteData: true, savedTabs: false)
            check(false, "unproven retirement must fail global clearing")
        } catch {
            check(true, "unproven retirement fails global clearing")
        }
        withExtendedLifetime(interruption) { }
        check(!coordinator.isErasingData, "failed retirement releases the global erasure guard")
        check(await containsCookie(mustSurvive.name, in: sharedNormalData), "failed retirement leaves website data untouched")
        check(try Data(contentsOf: profile.appendingPathComponent("history.json")) == beforeFailedClear, "failed retirement leaves persisted history untouched")
        try await WebDocumentRetirement.waitForAll()
        try await coordinator.eraseBrowsingData(history: true, websiteData: true, savedTabs: false)
        check(await !containsCookie(mustSurvive.name, in: sharedNormalData), "retry retires the interrupted view and successfully clears data")

        // Clearing from private windows must also clear a parked normal profile
        // after its last persistent window has closed, even while stale native
        // code still retains the old view that had a cookie-writing timer.
        let parked = try cookie("parked-normal-" + UUID().uuidString)
        await sharedNormalData.httpCookieStore.setCookie(parked)
        let closedWriterID = UUID()
        let closedWriterCookieName = "closed-writer-" + UUID().uuidString
        let closedWriterView = normalA.engine.webView(for: closedWriterID, url: URL(string: "about:blank")!)
        closedWriterView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        windows[0].contentView?.addSubview(closedWriterView)
        normalA.engine.openHTML(id: closedWriterID,
                               html: "<html><script>window.writerTicks=0;function write(){window.writerTicks++;document.cookie='\(closedWriterCookieName)='+window.writerTicks+'; Path=/; SameSite=Lax; Secure';}write();setInterval(write,10);</script></html>",
                               baseURL: URL(string: "https://privacy-fixture.invalid")!)
        let closedWriterStarted = await waitUntil {
            let ticks = await evaluate("window.writerTicks", in: closedWriterView) as? NSNumber
            return (ticks?.intValue ?? 0) > 0
        }
        let closedWriterCookieExists = await containsCookie(closedWriterCookieName, in: sharedNormalData)
        check(closedWriterStarted && closedWriterCookieExists, "closed-window cookie-writer fixture executes before shutdown")
        for store in stores where store.mode == .normal {
            store.shutdown(); coordinator.unregister(store)
        }
        check(await containsCookie(parked.name, in: sharedNormalData), "closed normal profile retains a synthetic cookie before clearing")
        try await coordinator.eraseBrowsingData(history: false, websiteData: true, savedTabs: false)
        check(await !containsCookie(parked.name, in: sharedNormalData), "private-only global clearing also erases the parked normal website profile")
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        check(await !containsCookie(closedWriterCookieName, in: sharedNormalData), "already-closed retained document cannot repopulate normal cookies")
        let closedWriterTicks = await evaluate("window.writerTicks", in: closedWriterView) as? NSNumber
        check(closedWriterTicks == nil, "already-closed retained document has been replaced with inert content")
        check(preferenceKeys.map { String(describing: UserDefaults.standard.object(forKey: $0)) } == realPreferencesBefore, "injected test preferences leave the real privacy preference keys unchanged")
    }
}
