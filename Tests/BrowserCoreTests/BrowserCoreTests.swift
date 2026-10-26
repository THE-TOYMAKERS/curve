import Foundation
import BrowserCore

final class BrowserCoreTests {
    func testURLResolutionAndUnsafeSchemes() {
        XCTAssertEqual(URLResolver.resolve(" example.com/path ")?.absoluteString, "https://example.com/path")
        XCTAssertEqual(URLResolver.resolve("localhost:8080/demo")?.absoluteString, "http://localhost:8080/demo")
        XCTAssertEqual(URLResolver.resolve("127.0.0.1:3000")?.scheme, "http")
        XCTAssertEqual(URLResolver.resolve("curve://start")?.absoluteString, "curve://start")
        XCTAssertEqual(URLResolver.resolve("aperture://start")?.absoluteString, "curve://start")
        XCTAssertEqual(URLComponents(url: URLResolver.resolve("light & space")!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "light & space")
        XCTAssertEqual(URLResolver.resolve("search terms", searchEngine: "google")?.host, "www.google.com")
        for value in ["javascript:alert(1)", "data:text/html,test", "file:///etc/passwd", "ftp://example.com", "curve://evil", "aperture://evil", "curve:evil", "aperture:evil"] { XCTAssertNil(URLResolver.resolve(value), value) }
    }
    func testLegacyStartLinksPreserveSessionIdentity() {
        var state = BrowserState.initial
        let id = state.open(url: "aperture://start", title: "Saved home", kind: .pinned)
        let archivedID = UUID()
        state.archive.append(ArchivedTab(id: archivedID, tab: BrowserTab(title: "Old home", url: "aperture://start", kind: .pinned, spaceID: state.activeSpaceID)))
        let selected = state.selectedTabID
        let spaceIDs = state.spaces.map(\.id)
        state.repair()
        XCTAssertEqual(state.tabs.first(where: { $0.id == id })?.url, "curve://start")
        XCTAssertEqual(state.tabs.first(where: { $0.id == id })?.savedURL, "curve://start")
        XCTAssertEqual(state.selectedTabID, selected)
        XCTAssertEqual(state.spaces.map(\.id), spaceIDs)
        XCTAssertEqual(state.archive.first?.id, archivedID)
        XCTAssertEqual(state.archive.first?.tab.url, "curve://start")
        XCTAssertEqual(state.archive.first?.tab.savedURL, "curve://start")
    }
    func testLegacyProfileCopyPreservesFilesAndExistingCurve() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("Aperture", isDirectory: true)
        let destination = root.appendingPathComponent("Curve", isDirectory: true)
        var original = BrowserState.initial
        original.autoArchiveHours = 0
        let oldPersistence = StatePersistence(directory: old)
        try oldPersistence.save(original)
        let originalBytes = try Data(contentsOf: oldPersistence.stateURL)
        let windowID = UUID()
        var windowState = original
        _ = windowState.open(url: "https://window.example", title: "Window session")
        try StatePersistence(directory: old.appendingPathComponent("Windows/" + windowID.uuidString)).save(windowState)
        let history = [HistoryEntry(title: "History", url: "https://history.example")]
        try BrowsingHistory(directory: old).save(history)
        try Data("Unrelated file stays behind".utf8).write(to: old.appendingPathComponent("private-notes.txt"))
        try fm.createDirectory(at: old.appendingPathComponent("WebKit"), withIntermediateDirectories: true)
        try Data("Cookie data is not migrated".utf8).write(to: old.appendingPathComponent("WebKit/cookies"))
        XCTAssertTrue(try ProfileMigration.copyLegacyProfile(from: old, to: destination))
        XCTAssertEqual(StatePersistence(directory: destination).load(), original)
        XCTAssertEqual(BrowsingHistory(directory: destination).load(), history)
        XCTAssertEqual(StatePersistence(directory: destination.appendingPathComponent("Windows/" + windowID.uuidString)).load(), windowState)
        XCTAssertEqual(try Data(contentsOf: oldPersistence.stateURL), originalBytes)
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("private-notes.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("WebKit").path))
        var replacement = original
        _ = replacement.addSpace(name: "New Curve work")
        try StatePersistence(directory: destination).save(replacement)
        XCTAssertFalse(try ProfileMigration.copyLegacyProfile(from: old, to: destination))
        XCTAssertEqual(StatePersistence(directory: destination).load(), replacement)
        XCTAssertEqual(try Data(contentsOf: oldPersistence.stateURL), originalBytes)
    }
    func testLegacyProfileCopyRejectsLinksAndRollsBack() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let old = root.appendingPathComponent("Aperture", isDirectory: true)
        let destination = root.appendingPathComponent("Curve", isDirectory: true)
        XCTAssertFalse(try ProfileMigration.copyLegacyProfile(from: old, to: destination))
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        try StatePersistence(directory: old).save(.initial)
        let unrelated = root.appendingPathComponent("unrelated.json")
        try Data("Do not follow this file".utf8).write(to: unrelated)
        try fm.createSymbolicLink(at: old.appendingPathComponent("history.json"), withDestinationURL: unrelated)
        XCTAssertThrowsError(try ProfileMigration.copyLegacyProfile(from: old, to: destination))
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        XCTAssertTrue(fm.fileExists(atPath: old.appendingPathComponent("state.json").path))
        XCTAssertEqual(try String(contentsOf: unrelated), "Do not follow this file")
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".Curve-migration-") }))
    }
    func testSpaceSelectionAndGlobalFavorites() {
        var state = BrowserState.initial
        let first = state.activeSpaceID
        let favorite = state.tabs.first(where: { $0.kind == .favorite })!.id
        let firstTab = state.open(url: "https://first.example", title: "First")
        let second = state.spaces[1].id
        state.switchSpace(second)
        let secondTab = state.open(url: "https://second.example", title: "Second")
        state.select(favorite)
        XCTAssertEqual(state.activeSpaceID, second)
        XCTAssertEqual(state.selectedTabID, favorite)
        XCTAssertTrue(state.visibleTabs.contains(where: { $0.id == favorite }))
        XCTAssertFalse(state.visibleTabs.contains(where: { $0.id == firstTab }))
        state.switchSpace(first)
        XCTAssertEqual(state.selectedTabID, firstTab)
        state.select(secondTab)
        XCTAssertEqual(state.activeSpaceID, second)
    }
    func testPinnedCloseResetAndExplicitRemovalRestore() {
        var state = BrowserState.initial
        let id = state.open(url: "https://original.example", title: "Original", kind: .pinned)
        let index = state.tabs.firstIndex(where: { $0.id == id })!
        state.tabs[index].url = "https://navigated.example"
        state.close(id)
        XCTAssertEqual(state.tabs.first(where: { $0.id == id })?.url, "https://original.example")
        XCTAssertTrue(state.archive.isEmpty)
        state.removeTab(id)
        XCTAssertNil(state.tabs.first(where: { $0.id == id }))
        let archivedID = state.archive[0].id
        state.restore(archivedID)
        XCTAssertEqual(state.selectedTabID, id)
        XCTAssertEqual(state.tabs.first(where: { $0.id == id })?.kind, .pinned)
        XCTAssertTrue(state.archive.isEmpty)
    }
    func testArchiveProtectsSelectedPinsAndFavorites() {
        var state = BrowserState.initial
        let expired = state.open(url: "https://expired.example")
        let split = state.open(url: "https://split.example")
        let protected = state.open(url: "https://media.example")
        let selected = state.open(url: "https://selected.example")
        state.spaces[0].splitTabID = split
        let old = Date(timeIntervalSinceNow: -48 * 3600)
        for i in state.tabs.indices { state.tabs[i].lastAccessed = old }
        state.archiveExpired(protectedIDs: [protected])
        XCTAssertFalse(state.tabs.contains(where: { $0.id == expired }))
        XCTAssertTrue(state.tabs.contains(where: { $0.id == selected }))
        XCTAssertTrue(state.tabs.contains(where: { $0.id == split }))
        XCTAssertTrue(state.tabs.contains(where: { $0.id == protected }))
        XCTAssertEqual(state.tabs.filter { $0.kind == .favorite }.count, 2)
        XCTAssertTrue(state.tabs.contains(where: { $0.kind == .pinned }))
    }
    func testFoldersMovesReorderingAndRepair() {
        var state = BrowserState.initial
        let first = state.open(url: "https://one.example")
        let second = state.open(url: "https://two.example")
        let otherSpace = state.spaces[1].id
        let folder = state.addFolder(name: "Research", spaceID: otherSpace)
        state.moveTab(first, to: otherSpace, folderID: folder)
        XCTAssertEqual(state.tabs.first(where: { $0.id == first })?.kind, .pinned)
        state.reorderTab(second, before: first)
        XCTAssertLessThan(state.tabs.firstIndex(where: { $0.id == second })!, state.tabs.firstIndex(where: { $0.id == first })!)
        state.tabs.append(state.tabs[0]); state.activeSpaceID = UUID(); state.sidebarWidth = .nan; state.maxLiveTabs = -40
        state.spaces[0].splitTabID = UUID()
        state.repair()
        XCTAssertEqual(Set(state.tabs.map(\.id)).count, state.tabs.count)
        XCTAssertTrue(state.spaces.contains(where: { $0.id == state.activeSpaceID }))
        XCTAssertEqual(state.sidebarWidth, 224)
        XCTAssertEqual(state.maxLiveTabs, 2)
        XCTAssertNil(state.spaces[0].splitTabID)
    }
    func testPersistenceRecoversBackupAfterCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = StatePersistence(directory: directory)
        let original = BrowserState.initial
        try persistence.save(original)
        var changed = original; _ = changed.addSpace(name: "Extra")
        try persistence.save(changed)
        XCTAssertEqual(persistence.load(), changed)
        try Data("broken".utf8).write(to: persistence.stateURL)
        XCTAssertEqual(persistence.load(), original)
        // A new save must retain the valid backup rather than replacing it with corrupt JSON.
        try persistence.save(changed)
        try Data("broken again".utf8).write(to: persistence.stateURL)
        XCTAssertEqual(persistence.load(), original)
    }
    func testArcImportPreservesSpaceFolderPinsFavoritesAndIsIdempotent() throws {
        let space = UUID(), pinnedRoot = UUID(), todayRoot = UUID(), favoritesRoot = UUID(), folder = UUID(), pin = UUID(), today = UUID(), favorite = UUID()
        let fixture: [String: Any] = ["sidebar": ["containers": [["global": [:]], [
            "spaces": [space.uuidString, ["id": space.uuidString, "title": "Studio", "customInfo": ["iconType": ["emoji_v2": "🌱"]], "containerIDs": ["pinned", pinnedRoot.uuidString, "unpinned", todayRoot.uuidString]]],
            "topAppsContainerIDs": [["default": true], favoritesRoot.uuidString],
            "items": [
                folder.uuidString, ["id": folder.uuidString, "parentID": pinnedRoot.uuidString, "title": "Reading", "childrenIds": [pin.uuidString], "data": ["list": [:]]],
                pin.uuidString, ["id": pin.uuidString, "parentID": folder.uuidString, "data": ["tab": ["savedURL": "https://example.com/pin", "savedTitle": "A pin"]]],
                today.uuidString, ["id": today.uuidString, "parentID": todayRoot.uuidString, "data": ["tab": ["savedURL": "https://example.com/today", "savedTitle": "Today"]]],
                favorite.uuidString, ["id": favorite.uuidString, "parentID": favoritesRoot.uuidString, "data": ["tab": ["savedURL": "https://example.com/favorite", "savedTitle": "Favorite"]]]
            ]
        ]]]]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        let imported = try ArcSidebarImporter.importData(data, into: .initial)
        XCTAssertEqual(imported.activeSpaceID, space)
        XCTAssertEqual(imported.spaces.first(where: { $0.id == space })?.emoji, "🌱")
        XCTAssertEqual(imported.folders.first(where: { $0.id == folder })?.name, "Reading")
        XCTAssertEqual(imported.tabs.first(where: { $0.id == pin })?.folderID, folder)
        XCTAssertEqual(imported.tabs.first(where: { $0.id == pin })?.kind, .pinned)
        XCTAssertEqual(imported.tabs.first(where: { $0.id == today })?.kind, .today)
        XCTAssertEqual(imported.tabs.first(where: { $0.id == favorite })?.kind, .favorite)
        let repeated = try ArcSidebarImporter.importData(data, into: imported)
        XCTAssertEqual(repeated, imported)
    }
    func testCustomTitleAndPinHomeSurviveSessionRoundTrip() throws {
        var state = BrowserState.initial
        let id = state.open(url: "https://home.example", title: "Site title", kind: .pinned)
        let index = state.tabs.firstIndex(where: { $0.id == id })!
        state.tabs[index].customTitle = "My research desk"
        state.tabs[index].url = "https://home.example/article"
        state.tabs[index].title = "Article title changed by navigation"
        var restored = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.tabs[index].customTitle, "My research desk")
        XCTAssertEqual(restored.tabs[index].savedURL, "https://home.example")
        XCTAssertEqual(restored.tabs[index].url, "https://home.example/article")
        restored.close(id)
        XCTAssertEqual(restored.tabs[index].url, "https://home.example")
        XCTAssertEqual(restored.tabs[index].customTitle, "My research desk")
        // Older sessions omit optional customTitle/savedURL; decoding remains compatible.
        let spaceID = UUID()
        let legacy: [String: Any] = ["id": UUID().uuidString, "title": "Legacy", "url": "https://example.com", "kind": "today", "spaceID": spaceID.uuidString, "lastAccessed": 0.0, "createdAt": 0.0]
        let tab = try JSONDecoder().decode(BrowserTab.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(tab.customTitle)
        XCTAssertNil(tab.savedURL)
    }
    func testArcImportPreservesCompleteThemeAndRoundTrips() throws {
        let space = UUID()
        let rawTheme = syntheticArcTheme()
        let fixture: [String: Any] = ["sidebar": ["containers": [[
            "spaces": [["value": ["id": space.uuidString, "title": "Synthetic theme", "customInfo": ["windowTheme": rawTheme]]]],
            "items": []
        ]]]]
        let imported = try ArcSidebarImporter.importData(JSONSerialization.data(withJSONObject: fixture), into: .initial)
        let expected = syntheticBrowserTheme()
        let theme = imported.spaces.first(where: { $0.id == space })?.theme
        XCTAssertEqual(theme, expected)
        XCTAssertEqual(theme?.baseColors.count, 2)
        XCTAssertEqual(theme?.overlayColors.count, 2)
        XCTAssertEqual(theme?.intensity, 0.64)
        XCTAssertEqual(theme?.noise, 0.17)
        XCTAssertEqual(theme?.isVibrant, false)
        XCTAssertEqual(theme?.isDark, true)
        XCTAssertEqual(theme?.ink, ThemeColor(red: 0.93, green: 0.87, blue: 0.76, alpha: 0.91))
        // This differs substantially from the pale primaryColorPalette tint.
        XCTAssertEqual(imported.spaces.first(where: { $0.id == space })?.colorHex, "2E4775")
        let restored = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(imported))
        XCTAssertEqual(restored, imported)
        XCTAssertEqual(restored.spaces.first(where: { $0.id == space })?.theme, expected)
    }
    func testArcThemeRefreshChangesOnlyMatchingSpaceAppearance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("synthetic-sidebar.json")
        var original = BrowserState.initial
        let matching = original.spaces[0].id
        let unmatched = original.spaces[1].id
        let tab = original.open(url: "https://fixture.invalid/selected", title: "Keep selected")
        let split = original.open(url: "https://fixture.invalid/split", title: "Keep split")
        original.select(tab)
        original.spaces[0].splitTabID = split
        original.spaces[0].splitVertical = true
        original.spaces[1].theme = BrowserTheme(baseColors: [ThemeColor(red: 0.7, green: 0.2, blue: 0.1)])
        let folder = original.addFolder(name: "Keep folder", spaceID: matching)
        _ = original.open(url: "https://fixture.invalid/pin", title: "Keep pin", kind: .pinned, folderID: folder)
        original.select(tab)
        let archived = original.open(url: "https://fixture.invalid/archived", title: "Keep archive")
        original.close(archived)
        original.select(tab)
        original.appearanceVersion = nil
        let fixture: [String: Any] = ["sidebar": ["containers": [
            ["spaces": [["value": ["id": matching.uuidString, "title": "Must not rename", "customInfo": ["windowTheme": syntheticArcTheme()]]]]],
            ["spaces": [
                ["id": unmatched.uuidString, "title": "Must not rename either", "customInfo": ["windowTheme": ["background": [:]]]],
                ["id": UUID().uuidString, "title": "Must not add", "customInfo": ["windowTheme": syntheticArcTheme()]],
                ["id": "invalid-id", "customInfo": ["windowTheme": syntheticArcTheme()]]
            ], "items": [["id": UUID().uuidString, "data": ["tab": ["savedURL": "https://fixture.invalid/must-not-import"]]]]]
        ]]]
        try JSONSerialization.data(withJSONObject: fixture).write(to: url)
        let refreshed = try ArcSidebarImporter.refreshThemes(from: url, into: original)
        var expected = original
        expected.spaces[0].theme = syntheticBrowserTheme()
        expected.spaces[0].colorHex = "2E4775"
        // Whole-state equality covers names, order, tabs, folders, archive,
        // split panes, selection, active space, settings and migration version.
        XCTAssertEqual(refreshed, expected)
        XCTAssertEqual(refreshed.tabs, original.tabs)
        XCTAssertEqual(refreshed.folders, original.folders)
        XCTAssertEqual(refreshed.archive, original.archive)
        XCTAssertEqual(refreshed.selectedTabID, tab)
        XCTAssertEqual(refreshed.spaces[0].splitTabID, split)
        XCTAssertEqual(refreshed.spaces[1], original.spaces[1])
        XCTAssertEqual(try ArcSidebarImporter.refreshThemes(from: url, into: refreshed), refreshed)
        try Data("{}".utf8).write(to: url)
        XCTAssertThrowsError(try ArcSidebarImporter.refreshThemes(from: url, into: original))
    }
    func testLegacyAppearanceFieldsRemainOptional() throws {
        let spaceID = UUID(), selectedID = UUID()
        let legacySpace: [String: Any] = ["id": spaceID.uuidString, "name": "Legacy space", "emoji": "◈", "colorHex": "BDB6DD", "selectedTabID": selectedID.uuidString]
        let space = try JSONDecoder().decode(BrowserSpace.self, from: JSONSerialization.data(withJSONObject: legacySpace))
        XCTAssertNil(space.theme)
        XCTAssertEqual(space.selectedTabID, selectedID)
        XCTAssertEqual(space.splitVertical, false)
        var original = BrowserState.initial
        original.spaces[0].theme = syntheticBrowserTheme()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        object.removeValue(forKey: "appearanceVersion")
        var spaces = object["spaces"] as! [[String: Any]]
        for index in spaces.indices { spaces[index].removeValue(forKey: "theme") }
        object["spaces"] = spaces
        let restored = try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.appearanceVersion)
        XCTAssertTrue(restored.spaces.allSatisfy { $0.theme == nil })
        XCTAssertEqual(restored.tabs, original.tabs)
        XCTAssertEqual(restored.activeSpaceID, original.activeSpaceID)
        XCTAssertEqual(restored.selectedTabID, original.selectedTabID)
        object["appearanceVersion"] = NSNull()
        XCTAssertNil(try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: object)).appearanceVersion)
    }
    func testHistoryPersistenceBoundsAndBackupRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = BrowsingHistory(directory: directory)
        XCTAssertEqual(history.load().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let earlier = [HistoryEntry(title: "Earlier visit", url: "https://example.com/earlier", visitedAt: Date(timeIntervalSince1970: 100))]
        try history.save(earlier)
        XCTAssertEqual(history.load(), earlier)
        let newestFirst = (0..<2005).map { index in
            HistoryEntry(title: "Visit \(index)", url: "https://example.com/\(index)", visitedAt: Date(timeIntervalSince1970: Double(10000 - index)))
        }
        try history.save(newestFirst)
        let loaded = history.load()
        XCTAssertEqual(loaded.count, 2000)
        XCTAssertEqual(loaded.first?.id, newestFirst.first?.id)
        XCTAssertEqual(loaded.last?.id, newestFirst[1999].id)
        XCTAssertEqual(loaded.first?.visitedAt, newestFirst.first?.visitedAt)
        try Data("incomplete JSON".utf8).write(to: history.historyURL)
        XCTAssertEqual(history.load(), earlier)
        // Saving after a corrupt primary must not overwrite the valid backup with corruption.
        try history.save(newestFirst)
        try Data("broken again".utf8).write(to: history.historyURL)
        XCTAssertEqual(history.load(), earlier)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))
    }
    func testMalformedImportThrowsWithoutChangingState() {
        XCTAssertThrowsError(try ArcSidebarImporter.importData(Data("{}".utf8), into: .initial))
    }
}

// Synthetic Arc-shaped metadata only; no user sidebar or profile is read.
private func syntheticArcTheme() -> [String: Any] {
    func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> [String: Double] {
        ["red": r, "green": g, "blue": b, "alpha": a]
    }
    return [
        "background": ["gradientStyle": [
            "blendedGradient": ["_0": [
                "baseColors": [color(0.18, 0.28, 0.46), color(0.49, 0.24, 0.57, 0.86)],
                "overlayColors": [color(0.09, 0.73, 0.61, 0.42), color(0.82, 0.31, 0.23, 0.21)],
                "modifiers": ["intensityFactor": 0.64, "noiseFactor": 0.17]
            ]], "contentOverBackgroundAppearance": "dark", "isVibrant": false
        ]],
        "primaryColorPalette": ["tintedLight": color(0.91, 0.93, 0.97)],
        "semanticColorPalette": ["appearanceBased": [
            "dark": ["title": color(0.93, 0.87, 0.76, 0.91)],
            "light": ["title": color(0.11, 0.12, 0.13)]
        ]]
    ]
}
private func syntheticBrowserTheme() -> BrowserTheme {
    BrowserTheme(
        baseColors: [ThemeColor(red: 0.18, green: 0.28, blue: 0.46), ThemeColor(red: 0.49, green: 0.24, blue: 0.57, alpha: 0.86)],
        overlayColors: [ThemeColor(red: 0.09, green: 0.73, blue: 0.61, alpha: 0.42), ThemeColor(red: 0.82, green: 0.31, blue: 0.23, alpha: 0.21)],
        intensity: 0.64, noise: 0.17, isVibrant: false, isDark: true,
        ink: ThemeColor(red: 0.93, green: 0.87, blue: 0.76, alpha: 0.91))
}


private var failures = 0
private var assertionCount = 0
private func check(_ passed: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    if !passed { failures += 1; print("FAIL \(file):\(line) \(message)") }
}
private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    check(actual == expected, "\(message) expected \(expected), got \(actual)", file: file, line: line)
}
private func XCTAssertNil<T>(_ actual: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    check(actual == nil, "\(message) expected nil", file: file, line: line)
}
private func XCTAssertTrue(_ actual: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    check(actual, message, file: file, line: line)
}
private func XCTAssertFalse(_ actual: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    check(!actual, message, file: file, line: line)
}
private func XCTAssertLessThan<T: Comparable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    check(actual < expected, "Expected \(actual) < \(expected)", file: file, line: line)
}
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); check(false, "Expected error", file: file, line: line) }
    catch { check(true, "", file: file, line: line) }
}

@main struct CoreChecks {
    static func main() {
        let suite = BrowserCoreTests()
        let checks: [(String, () throws -> Void)] = [
            ("URL resolution and unsafe schemes", suite.testURLResolutionAndUnsafeSchemes),
            ("Legacy start links retain session identities", suite.testLegacyStartLinksPreserveSessionIdentity),
            ("Legacy profile copy and existing Curve protection", suite.testLegacyProfileCopyPreservesFilesAndExistingCurve),
            ("Legacy profile copy symlink rejection and rollback", suite.testLegacyProfileCopyRejectsLinksAndRollsBack),
            ("Space selection and global favorites", suite.testSpaceSelectionAndGlobalFavorites),
            ("Pinned reset, removal and restore", suite.testPinnedCloseResetAndExplicitRemovalRestore),
            ("Archive protections", suite.testArchiveProtectsSelectedPinsAndFavorites),
            ("Folders, moves, ordering and repair", suite.testFoldersMovesReorderingAndRepair),
            ("Atomic persistence and corrupt-state recovery", suite.testPersistenceRecoversBackupAfterCorruption),
            ("Arc structure import and repeated-import dedupe", suite.testArcImportPreservesSpaceFolderPinsFavoritesAndIsIdempotent),
            ("Arc complete theme import and persistence", suite.testArcImportPreservesCompleteThemeAndRoundTrips),
            ("Arc theme-only refresh preserves all other state", suite.testArcThemeRefreshChangesOnlyMatchingSpaceAppearance),
            ("Legacy optional theme and appearance version decode", suite.testLegacyAppearanceFieldsRemainOptional),
            ("Custom title and pinned home roundtrip", suite.testCustomTitleAndPinHomeSurviveSessionRoundTrip),
            ("History bounds, atomic persistence and backup recovery", suite.testHistoryPersistenceBoundsAndBackupRecovery),
            ("Malformed import", suite.testMalformedImportThrowsWithoutChangingState)
        ]
        for (name, run) in checks {
            let before = failures
            do { try run() } catch { failures += 1; print("FAIL \(name): \(error)") }
            print("\(failures == before ? "PASS" : "FAIL") \(name)")
        }
        print("\(checks.count) checks, \(assertionCount) assertions, \(failures) failures")
        if let index = CommandLine.arguments.firstIndex(of: "--arc-sidebar"), CommandLine.arguments.indices.contains(index + 1) {
            do {
                let base = BrowserState.initial
                let imported = try ArcSidebarImporter.importFile(URL(fileURLWithPath: CommandLine.arguments[index + 1]), into: base)
                let repeated = try ArcSidebarImporter.importFile(URL(fileURLWithPath: CommandLine.arguments[index + 1]), into: imported)
                check(imported == repeated, "Real sidebar import must be idempotent")
                let roundTrip = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(imported))
                check(roundTrip == imported, "Imported sidebar must survive persistence")
                print("Sidebar inspection: \(imported.spaces.count - base.spaces.count) spaces, \(imported.folders.count - base.folders.count) folders, \(imported.tabs.count - base.tabs.count) tabs. No state saved.")
            } catch { failures += 1; print("FAIL Sidebar inspection: \(error)") }
        }
        if failures != 0 { exit(1) }
    }
}
