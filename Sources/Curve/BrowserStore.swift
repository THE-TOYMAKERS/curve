import AppKit
import SwiftUI
import Combine
import BrowserCore

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let shortcut: String
    let action: () -> Void
}

enum PaletteMode { case newTab, navigate, split }

@MainActor
final class BrowserStore: ObservableObject {
    @Published var state: BrowserState
    @Published var paletteVisible = false
    @Published var query = ""
    @Published var paletteIndex = 0
    @Published var paletteFocus = UUID()
    @Published var findFocus = UUID()
    @Published var paletteMode: PaletteMode = .newTab
    @Published var archiveVisible = false
    @Published var removedSpace: (BrowserSpace, [BrowserFolder], Set<UUID>)?
    @Published var historyVisible = false
    @Published var history: [HistoryEntry] = []
    @Published var settingsVisible = false
    @Published var helpVisible = false
    @Published var downloadsVisible = false
    @Published var findVisible = false
    @Published var findQuery = ""
    @Published var toast: String?
    @Published var peek: (id: UUID, url: URL)?
    @Published var errors: [UUID: String] = [:]
    @Published var focusedPane: UUID?
    let engine: WebEngine
    let persistence: StatePersistence
    let historyPersistence: BrowsingHistory
    let mode: BrowserWindowMode
    var onNewWindow: ((BrowserWindowMode) -> Void)?
    weak var window: NSWindow? { didSet { keyboard.window = window } }
    let keyboard = BrowserKeyboardRouter()
    let drag = BrowserDragSession()
    private var lastHistoryURL: [UUID: String] = [:]
    private var saveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var archiveTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var monitor: Any?
    private var terminationObserver: NSObjectProtocol?
    private var didShutdown = false
    private var mruCycle: [UUID] = []
    private var mruIndex = 0
    private var cycling = false

    init(mode: BrowserWindowMode = .normal, directory overrideDirectory: URL? = nil, seed: BrowserState? = nil) {
        self.mode = mode
        engine = WebEngine(isPrivate: mode == .incognito)
        let directory = overrideDirectory ?? BrowserCoordinator.dataDirectory
        persistence = StatePersistence(directory: directory)
        let historyDirectory = BrowserCoordinator.dataDirectory
        historyPersistence = BrowsingHistory(directory: historyDirectory)
        if mode == .normal { state = seed ?? persistence.load(); history = historyPersistence.load() }
        else {
            let space = BrowserSpace(name: mode == .incognito ? "Private" : "Little Curve", emoji: mode == .incognito ? "◌" : "◇", colorHex: mode == .incognito ? "C0C1D0" : "C4BEDF")
            state = BrowserState(spaces: [space]); state.sidebarVisible = mode != .little; _ = state.open(url: "curve://start", title: mode == .incognito ? "Private browsing" : "Little Curve")
        }
        if (state.appearanceVersion ?? 0) < 2 {
            if state.sidebarWidth == 248 { state.sidebarWidth = 224 }
            if mode == .normal && !BrowserCoordinator.hasDataDirectoryOverride {
                let arcSidebar = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
                if let refreshed = try? ArcSidebarImporter.refreshThemes(from: arcSidebar, into: state) { state = refreshed }
            }
            state.appearanceVersion = 2
        }
        state.archiveExpired(now: Date())
        engine.onPageChanged = { [weak self] id, title, url in
            guard let self, let i = self.state.tabs.firstIndex(where: { $0.id == id }) else { return }
            var changed = false
            let visibleTitle = self.state.tabs[i].customTitle ?? title
            if !visibleTitle.isEmpty && visibleTitle != self.state.tabs[i].title { self.state.tabs[i].title = visibleTitle; changed = true }
            if !url.isEmpty && url != "about:blank" && self.state.tabs[i].url != url { self.state.tabs[i].url = url; changed = true }
            if self.engine.state(id: id).error == nil && self.errors[id] != nil { self.errors[id] = nil }
            if changed { self.saveSoon() }
            if !self.engine.state(id: id).isLoading && self.lastHistoryURL[id] != url && ["https", "http"].contains(URL(string: url)?.scheme ?? "") {
                self.lastHistoryURL[id] = url; self.recordHistory(title: title, url: url)
            }
        }
        engine.onOpenTab = { [weak self] url in self?.open(url.absoluteString) }
        engine.onPeek = { [weak self] url in self?.showPeek(url) }
        engine.shouldPeekNavigation = { [weak self] id, destination, origin in
            guard let self, self.peek?.id != id, let tab = self.state.tabs.first(where: { $0.id == id }), tab.kind != .today,
                  let from = origin?.host?.replacingOccurrences(of: "www.", with: ""), let to = destination.host?.replacingOccurrences(of: "www.", with: "") else { return false }
            return from != to
        }
        engine.onCloseTab = { [weak self] id in self?.close(id) }
        engine.onError = { [weak self] id, message in self?.errors[id] = message }
        $query.dropFirst().sink { [weak self] _ in self?.paletteIndex = 0 }.store(in: &subscriptions)
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.archiveIdleTabs() }
        }
        keyboard.onAction = { [weak self] action in self?.performKeyAction(action) }
        keyboard.onRecentTabCycleEnded = { [weak self] in
            guard let self, self.cycling else { return }; self.cycling = false
            if let id = self.state.selectedTabID { self.state.select(id); self.saveSoon() }
        }
        keyboard.install()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 && self?.window == NSApp.keyWindow { if self?.dismissTransientUI() == true { return nil } }
            if !event.modifierFlags.contains(.control), let self, self.cycling {
                self.cycling = false
                if let id = self.state.selectedTabID { self.state.select(id); self.saveSoon() }
            }
            return event
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        if mode == .normal, overrideDirectory == nil, BrowserCoordinator.legacyMigrationFailed {
            toast = "Couldn’t copy your saved Aperture session. Its original files are unchanged."
        }
    }

    var activeSpace: BrowserSpace { state.spaces.first(where: { $0.id == state.activeSpaceID }) ?? state.spaces[0] }
    var currentID: UUID? { focusedPane ?? state.selectedTabID }
    var selectedTab: BrowserTab? { state.tabs.first { $0.id == state.selectedTabID } }
    var favorites: [BrowserTab] { state.tabs.filter { $0.kind == .favorite } }
    var pinned: [BrowserTab] { state.tabs.filter { $0.spaceID == state.activeSpaceID && $0.kind == .pinned } }
    var today: [BrowserTab] { state.tabs.filter { $0.spaceID == state.activeSpaceID && $0.kind == .today } }
    var folders: [BrowserFolder] { state.folders.filter { $0.spaceID == state.activeSpaceID } }
    var splitID: UUID? { activeSpace.splitTabID }

    func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }; self?.saveNow()
        }
    }
    func saveNow() {
        guard mode == .normal else { return }
        do { try persistence.save(state) }
        catch { notify("Couldn’t save your session: \(error.localizedDescription)") }
    }
    func notify(_ message: String) {
        toastTask?.cancel(); toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }
    func select(_ id: UUID) {
        state.select(id); focusedPane = nil; saveSoon(); trim()
    }
    func switchSpace(_ id: UUID) {
        state.switchSpace(id); focusedPane = nil; saveSoon(); trim()
    }
    func switchSpace(number: Int) {
        guard state.spaces.indices.contains(number - 1) else { return }; switchSpace(state.spaces[number - 1].id)
    }
    func nextSpace(_ delta: Int) {
        guard let i = state.spaces.firstIndex(where: { $0.id == state.activeSpaceID }) else { return }
        switchSpace(state.spaces[(i + delta + state.spaces.count) % state.spaces.count].id)
    }
    func open(_ input: String, kind: TabKind = .today, inSplit: Bool = false) {
        guard let url = URLResolver.resolve(input, searchEngine: state.searchEngine) else { notify("That address can’t be opened."); return }
        let old = state.selectedTabID
        let id = state.open(url: url.absoluteString, title: url.scheme == "curve" ? "A little room for the internet" : (url.host ?? "New Tab"), kind: kind, spaceID: state.activeSpaceID, folderID: nil)
        errors[id] = nil
        if inSplit, let old, old != id { state.select(old); setSplit(id) }
        else { state.select(id) }
        focusedPane = nil; paletteVisible = false; saveSoon(); trim()
    }
    func newStartTab() {
        open("curve://start")
    }
    func navigate(_ input: String) {
        guard let id = currentID, let i = state.tabs.firstIndex(where: { $0.id == id }) else { open(input); return }
        guard let url = URLResolver.resolve(input, searchEngine: state.searchEngine) else { notify("That address can’t be opened."); return }
        state.tabs[i].url = url.absoluteString; state.tabs[i].title = url.host ?? "New Tab"
        errors[id] = nil
        if url.scheme != "curve" { engine.load(id: id, url: url) } else { engine.close(id: id) }
        paletteVisible = false; saveSoon()
    }
    func close(_ id: UUID? = nil, remove: Bool = false) {
        guard let id = id ?? currentID, let tab = state.tabs.first(where: { $0.id == id }) else { return }
        if tab.kind != .today && !remove {
            if let saved = tab.savedURL, saved != tab.url, let i = state.tabs.firstIndex(where: { $0.id == id }) {
                state.tabs[i].url = saved; engine.close(id: id); errors[id] = nil
                notify("Returned to pinned page")
            } else {
                engine.close(id: id)
                if let next = today.first(where: { $0.id != id }) { select(next.id) }
                else { showPalette(.newTab) }
            }
        } else {
            state.removeTab(id); engine.close(id: id)
            if splitID == id { setSplit(nil) }
            focusedPane = nil
        }
        saveSoon(); trim()
    }
    func restoreLast() {
        guard let archived = state.archive.first else { notify("Your archive is empty"); return }
        state.restore(archived.id); focusedPane = nil; saveSoon()
    }
    func restore(_ id: UUID) { state.restore(id); archiveVisible = false; focusedPane = nil; saveSoon() }
    func togglePin(_ id: UUID? = nil) {
        guard let id = id ?? currentID else { return }
        if state.tabs.first(where: { $0.id == id })?.kind == .favorite {
            _ = commitDrop(dragPayload(for: .tab(id)), from: self, on: .pinned)
        } else { state.togglePin(id); saveSoon() }
    }
    func toggleFavorite(_ id: UUID) {
        if state.tabs.first(where: { $0.id == id })?.kind == .favorite {
            _ = commitDrop(dragPayload(for: .tab(id)), from: self, on: .pinned)
        } else { state.toggleFavorite(id); saveSoon() }
    }
    func duplicate(_ id: UUID) {
        guard let tab = state.tabs.first(where: { $0.id == id }) else { return }; open(tab.url)
    }
    func reset(_ id: UUID) {
        guard let tab = state.tabs.first(where: { $0.id == id }), let home = tab.savedURL, let i = state.tabs.firstIndex(where: { $0.id == id }) else { return }
        state.tabs[i].url = home; engine.close(id: id); select(id)
    }
    func replacePin(_ id: UUID) {
        guard let i = state.tabs.firstIndex(where: { $0.id == id }) else { return }
        state.tabs[i].savedURL = state.tabs[i].url; saveSoon(); notify("Pinned address updated")
    }
    func rename(_ id: UUID) {
        guard let i = state.tabs.firstIndex(where: { $0.id == id }), let name = ask("Rename Tab", value: state.tabs[i].title) else { return }
        state.tabs[i].customTitle = name; state.tabs[i].title = name; saveSoon()
    }
    func renameFolder(_ id: UUID) {
        guard let folder = state.folders.first(where: { $0.id == id }),
              let name = ask("Rename Folder", value: folder.name.components(separatedBy: " / ").last ?? folder.name) else { return }
        _ = renameFolder(id, to: name)
    }
    @discardableResult
    func renameFolder(_ id: UUID, to proposedName: String) -> Bool {
        guard let folder = state.folders.first(where: { $0.id == id }), let name = folderLeaf(proposedName) else { return false }
        let old = folder.name
        let parts = old.components(separatedBy: " / ")
        let prefix = parts.dropLast().joined(separator: " / ")
        let desired = prefix.isEmpty ? name : prefix + " / " + name
        let ids = Set(state.folders.filter { $0.spaceID == folder.spaceID && ($0.id == id || $0.name.hasPrefix(old + " / ")) }.map(\.id))
        let replacement = uniqueFolderPath(desired, in: folder.spaceID, excluding: ids)
        for child in state.folders.indices where ids.contains(state.folders[child].id) {
            state.folders[child].name = replacement + state.folders[child].name.dropFirst(old.count)
        }
        saveSoon(); return true
    }
    func addFolder(parentID: UUID? = nil) {
        guard let name = ask("New Folder", value: "", placeholder: "Folder name") else { return }
        _ = addFolder(named: name, parentID: parentID)
    }
    @discardableResult
    func addFolder(named proposedName: String, parentID: UUID? = nil) -> UUID? {
        guard let name = folderLeaf(proposedName) else { return nil }
        let parent = parentID.flatMap { id in state.folders.first(where: { $0.id == id }) }
        guard parentID == nil || parent != nil else { return nil }
        let space = parent?.spaceID ?? state.activeSpaceID
        let desired = parent.map { $0.name + " / " + name } ?? name
        let path = uniqueFolderPath(desired, in: space)
        let id = state.addFolder(name: path, spaceID: space)
        if let parentID, let i = state.folders.firstIndex(where: { $0.id == parentID }) { state.folders[i].isExpanded = true }
        saveSoon(); return id
    }
    private func folderLeaf(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(" / ") else { notify("Folder names can’t contain “ / ”"); return nil }
        return trimmed
    }
    private func uniqueFolderPath(_ desired: String, in space: UUID, excluding ids: Set<UUID> = []) -> String {
        var occupied = Set<String>()
        for folder in state.folders where folder.spaceID == space && !ids.contains(folder.id) {
            let parts = folder.name.components(separatedBy: " / ")
            for count in 1...parts.count { occupied.insert(parts.prefix(count).joined(separator: " / ").lowercased()) }
        }
        if !occupied.contains(desired.lowercased()) { return desired }
        // There are at most occupied.count reserved names, so one of these
        // occupied.count + 1 candidates is guaranteed to be available.
        let suffix = (2...(occupied.count + 2)).first { !occupied.contains((desired + " \($0)").lowercased()) }!
        return desired + " \(suffix)"
    }
    func toggleFolder(_ id: UUID) {
        guard let i = state.folders.firstIndex(where: { $0.id == id }) else { return }; state.folders[i].isExpanded.toggle(); saveSoon()
    }
    func removeFolder(_ id: UUID) {
        if let removed = state.folders.first(where: { $0.id == id }) {
            let prefix = removed.name + " / "
            let parent = removed.name.components(separatedBy: " / ").dropLast().joined(separator: " / ")
            let descendants = state.folders.filter { $0.spaceID == removed.spaceID && $0.name.hasPrefix(prefix) }
            var excluded = Set(descendants.map(\.id)); excluded.insert(id)
            var branches: [String] = []
            for folder in descendants {
                let leaf = String(folder.name.dropFirst(prefix.count)).components(separatedBy: " / ")[0]
                if !branches.contains(leaf) { branches.append(leaf) }
            }
            for branch in branches {
                let oldPath = prefix + branch
                let desired = parent.isEmpty ? branch : parent + " / " + branch
                let replacement = uniqueFolderPath(desired, in: removed.spaceID, excluding: excluded)
                let bundle = Dictionary(uniqueKeysWithValues: descendants.filter { $0.name == oldPath || $0.name.hasPrefix(oldPath + " / ") }.map { ($0.id, $0.name) })
                for i in state.folders.indices where bundle[state.folders[i].id] != nil {
                    excluded.remove(state.folders[i].id)
                    state.folders[i].name = replacement + bundle[state.folders[i].id]!.dropFirst(oldPath.count)
                }
            }
        }
        state.folders.removeAll { $0.id == id }
        for i in state.tabs.indices where state.tabs[i].folderID == id { state.tabs[i].folderID = nil }
        saveSoon()
    }
    func addSpace() {
        guard let name = ask("New Space", value: "", placeholder: "Space name") else { return }
        let colors = ["B9C6EB", "BCDCCF", "E8C5AE", "C7BDE6", "E2C2D3"]
        let id = state.addSpace(name: name, emoji: "✦", colorHex: colors[state.spaces.count % colors.count]); switchSpace(id)
    }
    func renameSpace() {
        guard let i = state.spaces.firstIndex(where: { $0.id == state.activeSpaceID }), let name = ask("Rename Space", value: activeSpace.name) else { return }
        state.spaces[i].name = name; saveSoon()
    }
    func move(_ id: UUID, space: UUID, folder: UUID? = nil) {
        state.moveTab(id, to: space, folderID: folder); focusedPane = nil; saveSoon(); trim()
    }
    /// Compatibility for plain-string drops from earlier views and URL pasteboards.
    func drop(_ source: String, before target: UUID? = nil, kind: TabKind? = nil, folder: UUID? = nil) {
        if let id = UUID(uuidString: source), state.tabs.contains(where: { $0.id == id }) {
            let destination: BrowserDropTarget = target.map(BrowserDropTarget.tab) ?? folder.map(BrowserDropTarget.folder) ?? (kind == .favorite ? .favorites : kind == .pinned ? .pinned : .today)
            _ = commitDrop(dragPayload(for: .tab(id)), from: self, on: destination, position: target == nil ? .inside : .before)
        } else {
            let destination: BrowserDropTarget = target.map(BrowserDropTarget.tab) ?? folder.map(BrowserDropTarget.folder) ?? (kind == .favorite ? .favorites : kind == .pinned ? .pinned : .today)
            _ = dropExternalURL(source, on: destination, position: target == nil ? .inside : .before)
        }
    }
    func setSplit(_ id: UUID?) {
        if let id, let tab = state.tabs.first(where: { $0.id == id }), tab.spaceID != state.activeSpaceID && tab.kind != .favorite {
            state.moveTab(id, to: state.activeSpaceID)
        }
        guard let i = state.spaces.firstIndex(where: { $0.id == state.activeSpaceID }) else { return }
        state.spaces[i].splitTabID = id; focusedPane = nil; saveSoon(); trim()
    }
    func toggleSplitOrientation() {
        guard let i = state.spaces.firstIndex(where: { $0.id == state.activeSpaceID }) else { return }
        state.spaces[i].splitVertical.toggle(); saveSoon()
    }
    func showPeek(_ url: URL) { dismissPeek(); peek = (UUID(), url); trim() }
    func dismissPeek() { if let peek { engine.close(id: peek.id) }; peek = nil; trim() }
    func expandPeek(split: Bool = false) {
        guard let p = peek else { return }; let address = engine.state(id: p.id).url
        dismissPeek(); open(address.isEmpty ? p.url.absoluteString : address, inSplit: split)
    }
    func trim() {
        var ids = Set([state.selectedTabID, splitID, peek?.id].compactMap { $0 })
        if ids.isEmpty, let id = state.tabs.first?.id { ids.insert(id) }
        engine.activate(ids: ids, limit: max(2, state.maxLiveTabs))
    }
    func archiveIdleTabs() async {
        let protected = await engine.protectedTabIDs()
        let oldIDs = Set(state.tabs.map(\.id)); state.archiveExpired(now: Date(), protectedIDs: protected)
        for id in oldIDs.subtracting(state.tabs.map(\.id)) { engine.close(id: id) }
        if oldIDs.count != state.tabs.count { saveSoon() }
    }
    func clearToday() {
        Task { @MainActor in
            let protected = await engine.protectedTabIDs()
            for tab in today where tab.id != splitID && !protected.contains(tab.id) { state.removeTab(tab.id); engine.close(id: tab.id) }
            focusedPane = nil; saveSoon(); notify("Today’s tabs moved to Archive")
        }
    }
    func showPalette(_ mode: PaletteMode) {
        paletteMode = mode; query = mode == .navigate ? (state.tabs.first { $0.id == currentID }?.url ?? "") : ""
        paletteIndex = 0; paletteFocus = UUID(); paletteVisible = true
    }
    func runPaletteItem() {
        let items = paletteItems
        guard !items.isEmpty else { return }
        items[min(max(paletteIndex, 0), items.count - 1)].action()
        paletteVisible = false
    }
    var paletteItems: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [PaletteItem] = []
        if !q.isEmpty, !q.hasPrefix(">") {
            let direct = URLResolver.resolve(q, searchEngine: state.searchEngine)
            let isSearch = direct?.host?.contains("duckduckgo") == true || direct?.host == "www.google.com"
            items.append(PaletteItem(id: "navigate", title: isSearch ? "Search for “\(q)”" : q, subtitle: paletteMode == .navigate ? "Open in current tab" : paletteMode == .split ? "Open in Split View" : "Open a new tab", symbol: isSearch ? "magnifyingglass" : "globe", shortcut: "↵", action: { [weak self] in
                guard let self else { return }
                if self.paletteMode == .navigate { self.navigate(q) } else { self.open(q, inSplit: self.paletteMode == .split) }
            }))
        }
        let term = q.lowercased().replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
        let tabs = state.tabs.sorted { $0.lastAccessed > $1.lastAccessed }.filter { term.isEmpty || $0.title.lowercased().contains(term) || $0.url.lowercased().contains(term) }
        for tab in tabs.prefix(term.isEmpty ? 4 : 7) {
            items.append(PaletteItem(id: tab.id.uuidString, title: tab.title, subtitle: URL(string: tab.url)?.host ?? "Start page", symbol: tab.kind == .favorite ? "star" : tab.kind == .pinned ? "pin" : "globe", shortcut: "Switch to Tab", action: { [weak self] in
                guard let self else { return }; if self.paletteMode == .split { self.setSplit(tab.id) } else { self.select(tab.id) }
            }))
        }
        let actions: [(String, String, String, () -> Void)] = [
            ("Toggle Sidebar", "sidebar.left", "⌘S", { [weak self] in self?.state.sidebarVisible.toggle(); self?.saveSoon() }),
            ("Pin / Unpin Tab", "pin", "⌘D", { [weak self] in self?.togglePin() }),
            ("Add Split View", "rectangle.split.2x1", "", { [weak self] in DispatchQueue.main.async { self?.showPalette(.split) } }),
            ("Close Split View", "rectangle", "", { [weak self] in self?.setSplit(nil) }),
            ("New Space", "square.stack.3d.up", "", { [weak self] in self?.addSpace() }),
            ("New Folder", "folder.badge.plus", "", { [weak self] in self?.addFolder() }),
            ("Open Archive", "archivebox", "", { [weak self] in self?.archiveVisible = true }),
            ("Restore Last Closed Tab", "arrow.uturn.backward", "⇧⌘T", { [weak self] in self?.restoreLast() }),
            ("Import from Arc", "square.and.arrow.down", "", { [weak self] in self?.importArc() }),
            ("Settings", "gearshape", "⌘,", { [weak self] in self?.settingsVisible = true }),
            ("Keyboard Shortcuts", "keyboard", "", { [weak self] in self?.helpVisible = true })
        ]
        for action in actions where term.isEmpty || action.0.lowercased().contains(term) {
            items.append(PaletteItem(id: action.0, title: action.0, subtitle: "Action", symbol: action.1, shortcut: action.2, action: action.3))
        }
        for space in state.spaces where !term.isEmpty && space.name.lowercased().contains(term) {
            items.append(PaletteItem(id: space.id.uuidString, title: "\(space.emoji)  \(space.name)", subtitle: "Switch Space", symbol: "square.stack", shortcut: "", action: { [weak self] in self?.switchSpace(space.id) }))
        }
        return Array(items.prefix(12))
    }
    func cycleMRU(backward: Bool) {
        if !cycling {
            mruCycle = state.tabs.sorted { $0.lastAccessed > $1.lastAccessed }.map(\.id)
            mruIndex = mruCycle.firstIndex(of: state.selectedTabID ?? UUID()) ?? 0; cycling = true
        }
        guard !mruCycle.isEmpty else { return }
        mruIndex = (mruIndex + (backward ? -1 : 1) + mruCycle.count) % mruCycle.count
        let id = mruCycle[mruIndex]
        guard let tab = state.tabs.first(where: { $0.id == id }) else { return }
        if tab.kind != .favorite { state.activeSpaceID = tab.spaceID }
        if let i = state.spaces.firstIndex(where: { $0.id == state.activeSpaceID }) { state.spaces[i].selectedTabID = id }
        focusedPane = nil; trim()
    }
    func ask(_ title: String, value: String, placeholder: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title
        let input = NSTextField(string: value); input.frame = NSRect(x: 0, y: 0, width: 280, height: 24); input.placeholderString = placeholder
        alert.accessoryView = input; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
    func importArc() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
        if FileManager.default.fileExists(atPath: path.path) { importFile(path); return }
        let panel = NSOpenPanel(); panel.title = "Import Arc Sidebar"; panel.message = "Choose Arc’s StorableSidebar.json. Only spaces, folders, and tab addresses are imported."; panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { importFile(url) }
    }
    private func importFile(_ url: URL) {
        do {
            let oldCount = state.tabs.count
            state = try ArcSidebarImporter.importFile(url, into: state)
            saveNow(); notify("Arc imported · \(max(0, state.tabs.count - oldCount)) tabs added")
        } catch { notify("Import failed: \(error.localizedDescription)") }
    }
    func exportSession() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Curve-session.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(state).write(to: url, options: .atomic); notify("Session exported") }
        catch { notify(error.localizedDescription) }
    }
}


extension BrowserStore {
    func recordHistory(title: String, url: String) {
        if mode == .normal { history = historyPersistence.load() }
        history.removeAll { $0.url == url }
        history.insert(HistoryEntry(title: title.isEmpty ? (URL(string: url)?.host ?? url) : title, url: url), at: 0)
        if history.count > 2000 { history = Array(history.prefix(2000)) }
        if mode == .normal { try? historyPersistence.save(history) }
    }
    func copyURL(markdown: Bool = false) {
        guard let tab = state.tabs.first(where: { $0.id == currentID }) else { return }
        let title = tab.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let value = markdown ? "[\(title)](<\(tab.url)>)" : tab.url
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        notify(markdown ? "Copied as Markdown" : "Copied URL")
    }
    var orderedTabs: [BrowserTab] {
        func descendants(_ folder: BrowserFolder) -> [BrowserTab] {
            let children = folders.filter { $0.name.components(separatedBy: " / ").dropLast().joined(separator: " / ") == folder.name && $0.id != folder.id }
            return pinned.filter { $0.folderID == folder.id } + children.flatMap { descendants($0) }
        }
        let roots = folders.filter { folder in
            let parts = folder.name.components(separatedBy: " / ")
            return parts.count == 1 || !folders.contains(where: { $0.name == parts.dropLast().joined(separator: " / ") })
        }
        return favorites + pinned.filter { $0.folderID == nil } + roots.flatMap { descendants($0) } + today
    }
    func selectNumber(_ number: Int) {
        let tabs = orderedTabs
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }; select(tabs[index].id)
    }
    func stepTab(_ delta: Int) {
        let tabs = orderedTabs
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == currentID } ?? 0
        select(tabs[(index + delta + tabs.count) % tabs.count].id)
    }
    func focusSplit(_ number: Int) {
        let id = number == 1 ? state.selectedTabID : number == 2 ? splitID : nil
        guard let id else { return }; focusedPane = id
        if let tab = state.tabs.first(where: { $0.id == id }), let url = URL(string: tab.url), url.scheme != "curve" {
            window?.makeFirstResponder(engine.webView(for: id, url: url))
        }
    }
    func performKeyAction(_ action: BrowserKeyAction) {
        if case .closeTab = action {
            if paletteVisible { paletteVisible = false; return }
            if archiveVisible || settingsVisible || helpVisible || downloadsVisible || historyVisible { archiveVisible = false; settingsVisible = false; helpVisible = false; downloadsVisible = false; historyVisible = false; return }
        }
        switch action {
        case .newTab: showPalette(.newTab)
        case .newWindow: onNewWindow?(.normal)
        case .incognitoWindow: onNewWindow?(.incognito)
        case .littleArc: onNewWindow?(.little)
        case .closeTab:
            if state.visibleTabs.isEmpty || (state.visibleTabs.count == 1 && selectedTab?.kind == .today) {
                if let id = currentID { close(id) }; window?.performClose(nil)
            } else { close() }
        case .restoreTab: restoreLast()
        case .togglePin: togglePin()
        case .copyURL: copyURL()
        case .copyMarkdown: copyURL(markdown: true)
        case .editURL: showPalette(.navigate)
        case .toggleSidebar: state.sidebarVisible.toggle(); saveSoon()
        case .clearToday: clearToday()
        case .tabNumber(let n): selectNumber(n)
        case .spaceNumber(let n): switchSpace(number: n)
        case .recentTab(let backward): cycleMRU(backward: backward)
        case .tabStep(let delta): stepTab(delta)
        case .spaceStep(let delta): nextSpace(delta)
        case .forward: if let id = currentID { engine.goForward(id) }
        case .back: if let id = currentID { engine.goBack(id) }
        case .addSplit: showPalette(.split)
        case .closeSplit: setSplit(nil)
        case .focusSplit(let number): focusSplit(number)
        case .history: if mode == .normal { history = historyPersistence.load() }; historyVisible = true
        case .zoom(let factor): if let id = currentID { engine.zoom(id: id, factor: factor) }
        case .resetZoom: if let id = currentID, let tab = state.tabs.first(where: { $0.id == id }), let url = URL(string: tab.url), url.scheme != "curve" { engine.webView(for: id, url: url).pageZoom = 1 }
        case .reload: if let id = currentID { errors[id] = nil; engine.reload(id) }
        case .find: findVisible = true; findFocus = UUID()
        }
    }
    func dismissTransientUI() -> Bool {
        if paletteVisible { paletteVisible = false; return true }
        if peek != nil { dismissPeek(); return true }
        if findVisible { findVisible = false; if let id = currentID { engine.clearFind(id: id) }; return true }
        return false
    }
}


extension BrowserStore {
    func shutdown() {
        guard !didShutdown else { return }; didShutdown = true
        drag.finish(cancelled: true)
        saveTask?.cancel(); toastTask?.cancel(); archiveTimer?.invalidate(); archiveTimer = nil
        saveNow(); keyboard.uninstall()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver); self.terminationObserver = nil }
        subscriptions.removeAll(); onNewWindow = nil; lastHistoryURL.removeAll(); engine.shutdown()
        if mode != .normal {
            history.removeAll(); removedSpace = nil; peek = nil; errors.removeAll()
            let empty = BrowserSpace(name: mode == .incognito ? "Private" : "Little Curve", emoji: "◌", colorHex: "C0C1D0")
            state = BrowserState(spaces: [empty])
        }
        if BrowserCoordinator.shared.activeStore === self { BrowserCoordinator.shared.activeStore = nil }
    }
}

extension BrowserStore {
    func editSpaceName(_ id: UUID) {
        guard let i = state.spaces.firstIndex(where: { $0.id == id }), let name = ask("Rename Space", value: state.spaces[i].name) else { return }
        state.spaces[i].name = name; saveSoon()
    }
    func editSpaceIcon(_ id: UUID) {
        guard let i = state.spaces.firstIndex(where: { $0.id == id }), let emoji = ask("Change Space Icon", value: state.spaces[i].emoji, placeholder: "An emoji or symbol") else { return }
        state.spaces[i].emoji = String(emoji.prefix(2)); saveSoon()
    }
    func changeSpaceColor(_ id: UUID, hex: String) {
        guard let i = state.spaces.firstIndex(where: { $0.id == id }) else { return }; state.spaces[i].colorHex = hex; state.spaces[i].theme = nil; saveSoon()
    }
    func duplicateSpace(_ id: UUID) {
        guard let source = state.spaces.first(where: { $0.id == id }) else { return }
        let tabs = state.tabs.filter { $0.spaceID == id && $0.kind != .favorite }
        let folders = state.folders.filter { $0.spaceID == id }
        let newID = state.addSpace(name: source.name + " Copy", emoji: source.emoji, colorHex: source.colorHex)
        if let i = state.spaces.firstIndex(where: { $0.id == newID }) { state.spaces[i].theme = source.theme }
        var folderMap: [UUID: UUID] = [:]
        var tabMap: [UUID: UUID] = [:]
        for folder in folders { folderMap[folder.id] = state.addFolder(name: folder.name, spaceID: newID) }
        for tab in tabs {
            var copy = tab; copy.id = UUID(); tabMap[tab.id] = copy.id; copy.spaceID = newID; copy.folderID = tab.folderID.flatMap { folderMap[$0] }; state.tabs.append(copy)
        }
        switchSpace(newID)
        if let selected = source.selectedTabID.flatMap({ tabMap[$0] }) ?? state.tabs.first(where: { $0.spaceID == newID && $0.kind != .favorite })?.id { select(selected) }
        saveSoon()
    }
    func removeSpace(_ id: UUID) {
        guard state.spaces.count > 1, let space = state.spaces.first(where: { $0.id == id }), let fallback = state.spaces.first(where: { $0.id != id })?.id else { return }
        let folders = state.folders.filter { $0.spaceID == id }
        let tabs = state.tabs.filter { $0.spaceID == id && $0.kind != .favorite }
        removedSpace = (space, folders, Set(tabs.map(\.id)))
        for tab in tabs { state.removeTab(tab.id); engine.close(id: tab.id) }
        for i in state.tabs.indices where state.tabs[i].spaceID == id { state.tabs[i].spaceID = fallback }
        state.folders.removeAll { $0.spaceID == id }; state.spaces.removeAll { $0.id == id }
        if state.activeSpaceID == id { state.switchSpace(fallback) }
        focusedPane = nil; saveSoon(); trim(); notify("Space removed · Restore it from the Spaces menu")
    }
    func restoreRemovedSpace() {
        guard let removedSpace else { return }
        if !state.spaces.contains(where: { $0.id == removedSpace.0.id }) { state.spaces.append(removedSpace.0) }
        state.folders += removedSpace.1.filter { folder in !state.folders.contains(where: { $0.id == folder.id }) }
        let ids = state.archive.filter { removedSpace.2.contains($0.tab.id) }.map(\.id)
        for id in ids { state.restore(id) }
        if let i = state.spaces.firstIndex(where: { $0.id == removedSpace.0.id }) {
            let visible = Set(state.tabs.filter { $0.spaceID == removedSpace.0.id || $0.kind == .favorite }.map(\.id))
            let selected = removedSpace.0.selectedTabID.flatMap { visible.contains($0) ? $0 : nil }
            state.spaces[i].selectedTabID = selected
            state.spaces[i].splitTabID = removedSpace.0.splitTabID.flatMap {
                selected != nil && $0 != selected && visible.contains($0) ? $0 : nil
            }
        }
        self.removedSpace = nil; state.repair(); switchSpace(removedSpace.0.id); saveSoon()
    }
    func openFolder(_ id: UUID) {
        guard let first = state.tabs.first(where: { $0.folderID == id }) else { return }; select(first.id)
        notify("Folder opened · other tabs load when selected")
    }
    func useSelectionToFind() {
        guard let id = currentID, let tab = state.tabs.first(where: { $0.id == id }), let url = URL(string: tab.url), ["http", "https"].contains(url.scheme ?? "") else { return }
        engine.webView(for: id, url: url).evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            Task { @MainActor [weak self] in
                guard let self, let text = result as? String, !text.isEmpty else { return }
                self.findQuery = text; self.findVisible = true; self.findFocus = UUID(); self.engine.find(id: id, query: text, backwards: false)
            }
        }
    }
    func copyQuote() {
        guard let id = currentID, let tab = state.tabs.first(where: { $0.id == id }), let url = URL(string: tab.url), ["http", "https"].contains(url.scheme ?? "") else { copyURL(markdown: true); return }
        engine.webView(for: id, url: url).evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let quote = (result as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
                let title = tab.title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                let source = "[\(title)](<\(tab.url)>)"
                let output = quote == "> " ? source : quote + "\n\n" + source
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string); self.notify("Copied quote and source")
            }
        }
    }
}

extension BrowserStore {
    func dragPayload(for item: BrowserDragItem) -> BrowserDragPayload {
        var payload = BrowserDragPayload(item: item)
        switch item {
        case .tab(let id): payload.tab = state.tabs.first { $0.id == id }
        case .folder(let id):
            if let folder = state.folders.first(where: { $0.id == id }) {
                payload.folders = state.folders.filter { $0.spaceID == folder.spaceID && ($0.id == id || $0.name.hasPrefix(folder.name + " / ")) }
                let ids = Set(payload.folders.map(\.id)); payload.tabs = state.tabs.filter { $0.folderID.map(ids.contains) ?? false }
            }
        case .space(let id):
            payload.space = state.spaces.first { $0.id == id }
            payload.folders = state.folders.filter { $0.spaceID == id }
            payload.tabs = state.tabs.filter { $0.spaceID == id && $0.kind != .favorite }
        }
        return payload
    }

    func canMoveFolder(_ sourceID: UUID, into targetID: UUID?) -> Bool {
        guard let source = state.folders.first(where: { $0.id == sourceID }) else { return false }
        guard let targetID else { return true }
        guard let target = state.folders.first(where: { $0.id == targetID }), sourceID != targetID else { return false }
        return target.spaceID != source.spaceID || !target.name.hasPrefix(source.name + " / ")
    }
    func canDrop(_ item: BrowserDragItem, on target: BrowserDropTarget, position: BrowserDropPosition) -> Bool {
        switch (item, target) {
        case (.tab(let source), .tab(let target)): return source != target
        case (.tab(let id), .splitLeft), (.tab(let id), .splitRight): return state.selectedTabID != id
        case (.tab, _): return true
        case (.folder(let source), .folder(let target)):
            if position == .inside { return canMoveFolder(source, into: target) || !state.folders.contains(where: { $0.id == source }) }
            guard source != target else { return false }
            let parent = folderParentID(target)
            return canMoveFolder(source, into: parent) || !state.folders.contains(where: { $0.id == source })
        case (.folder, .pinned), (.folder, .space): return true
        case (.space(let source), .space(let target)): return source != target
        default: return false
        }
    }

    /// Native drag gestures only commit metadata when the pointer is released.
    @discardableResult
    func commitDrop(_ payload: BrowserDragPayload, from source: BrowserStore?, on destination: BrowserDropTarget, position: BrowserDropPosition = .inside) -> Bool {
        let before = state
        let previousFocus = focusedPane
        let isLocal = source === self
        var item = payload.item
        if !isLocal {
            guard let copied = copyDragPayload(payload) else { return false }; item = copied
        }
        guard canDrop(item, on: destination, position: position) else { state = before; return false }
        let success: Bool
        switch item {
        case .tab(let id): success = dropTab(id, on: destination, position: position)
        case .folder(let id): success = dropFolder(id, on: destination, position: position)
        case .space(let id):
            if case .space(let anchor) = destination { success = reorderSpace(id, relativeTo: anchor, after: position == .after) }
            else { success = false }
        }
        if success { clearInvalidDragFocus(); saveSoon(); trim() }
        else { state = before; focusedPane = previousFocus }
        return success
    }

    @discardableResult
    func dropExternalURL(_ text: String, on destination: BrowserDropTarget, position: BrowserDropPosition = .inside) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return false }
        let before = state
        let previousFocus = focusedPane
        let previous = state.selectedTabID
        let previousSpace = state.activeSpaceID
        let id = state.open(url: url.absoluteString, title: url.host ?? "New Tab", spaceID: previousSpace)
        if let previous { state.select(previous) }
        let success = dropTab(id, on: destination, position: position)
        guard success else { state = before; focusedPane = previousFocus; return false }
        if destination != .splitLeft && destination != .splitRight { state.select(id) }
        clearInvalidDragFocus(); saveSoon(); trim(); return true
    }

    private func dropTab(_ id: UUID, on destination: BrowserDropTarget, position: BrowserDropPosition) -> Bool {
        guard let tab = state.tabs.first(where: { $0.id == id }) else { return false }
        let selected = state.selectedTabID
        let active = state.activeSpaceID
        var targetSpace = active
        var kind = tab.kind
        var folder: UUID?
        var anchor: UUID?
        switch destination {
        case .tab(let target):
            guard let other = state.tabs.first(where: { $0.id == target }), id != target else { return false }
            targetSpace = other.kind == .favorite ? active : other.spaceID; kind = other.kind; folder = other.folderID; anchor = target
        case .folder(let target):
            guard let group = state.folders.first(where: { $0.id == target }) else { return false }
            targetSpace = group.spaceID; kind = .pinned; folder = target
            if let i = state.folders.firstIndex(where: { $0.id == target }) { state.folders[i].isExpanded = true }
        case .pinned: kind = .pinned
        case .today: kind = .today
        case .favorites: kind = .favorite
        case .space(let target):
            guard state.spaces.contains(where: { $0.id == target }) else { return false }
            targetSpace = target; folder = nil
            // A favorite remains global when dragged between space buttons.
        case .splitLeft, .splitRight:
            guard let primary = state.selectedTabID, primary != id else { return false }
            if tab.kind != .favorite && tab.spaceID != active { state.moveTab(id, to: active) }
            if destination == .splitRight { setSplit(id) }
            else { state.select(id); setSplit(primary) }
            return true
        }
        state.moveTab(id, to: targetSpace, folderID: folder)
        guard let index = state.tabs.firstIndex(where: { $0.id == id }) else { return false }
        state.tabs[index].kind = kind
        state.tabs[index].folderID = kind == .favorite || kind == .today ? nil : folder
        state.tabs[index].savedURL = kind == .today ? nil : (state.tabs[index].savedURL ?? state.tabs[index].url)
        if let anchor { _ = placeTab(id, relativeTo: anchor, after: position == .after) }
        // Same-space reorder/section moves leave the page and MRU ordering alone.
        // If a global favorite becomes a local pin, repair references in other spaces.
        for i in state.spaces.indices where state.spaces[i].id != targetSpace && kind != .favorite {
            if state.spaces[i].selectedTabID == id { state.spaces[i].selectedTabID = state.tabs.filter { $0.id != id && ($0.spaceID == state.spaces[i].id || $0.kind == .favorite) }.max(by: { $0.lastAccessed < $1.lastAccessed })?.id }
            if state.spaces[i].splitTabID == id { state.spaces[i].splitTabID = nil }
        }
        if let selected, state.tabs.contains(where: { $0.id == selected && ($0.spaceID == active || $0.kind == .favorite) }), let i = state.spaces.firstIndex(where: { $0.id == active }) {
            state.spaces[i].selectedTabID = selected
        }
        return true
    }

    @discardableResult
    func placeTab(_ id: UUID, relativeTo target: UUID, after: Bool) -> Bool {
        guard id != target, let from = state.tabs.firstIndex(where: { $0.id == id }), state.tabs.contains(where: { $0.id == target }) else { return false }
        let moving = state.tabs.remove(at: from)
        guard let anchor = state.tabs.firstIndex(where: { $0.id == target }) else { return false }
        state.tabs.insert(moving, at: anchor + (after ? 1 : 0)); return true
    }
    private func folderParentID(_ id: UUID) -> UUID? {
        guard let folder = state.folders.first(where: { $0.id == id }) else { return nil }
        let components = folder.name.components(separatedBy: " / ")
        guard components.count > 1 else { return nil }
        let parent = components.dropLast().joined(separator: " / ")
        return state.folders.first { $0.spaceID == folder.spaceID && $0.name == parent }?.id
    }
    private func dropFolder(_ id: UUID, on destination: BrowserDropTarget, position: BrowserDropPosition) -> Bool {
        guard let folder = state.folders.first(where: { $0.id == id }) else { return false }
        var space = state.activeSpaceID
        var parent: UUID?
        var anchor: UUID?
        switch destination {
        case .folder(let target):
            guard let targetFolder = state.folders.first(where: { $0.id == target }) else { return false }
            space = targetFolder.spaceID
            if position == .inside { parent = target }
            else { parent = folderParentID(target); anchor = target }
        case .space(let target): space = target
        case .pinned: break
        default: return false
        }
        guard state.spaces.contains(where: { $0.id == space }), canMoveFolder(id, into: parent) else { return false }
        let oldPath = folder.name
        let bundle = state.folders.filter { $0.spaceID == folder.spaceID && ($0.id == id || $0.name.hasPrefix(oldPath + " / ")) }
        let ids = Set(bundle.map(\.id))
        if let anchor, ids.contains(anchor) { return false }
        let leaf = oldPath.components(separatedBy: " / ").last ?? oldPath
        let parentPath = parent.flatMap { parentID in state.folders.first(where: { $0.id == parentID })?.name }
        let base = parentPath.map { $0 + " / " + leaf } ?? leaf
        let newPath = uniqueFolderPath(base, in: space, excluding: ids)
        var moved = bundle
        for i in moved.indices { moved[i].spaceID = space; moved[i].name = newPath + moved[i].name.dropFirst(oldPath.count) }
        state.folders.removeAll { ids.contains($0.id) }
        if let anchor, let index = state.folders.firstIndex(where: { $0.id == anchor }) {
            state.folders.insert(contentsOf: moved, at: index + (position == .after ? 1 : 0))
        } else { state.folders.append(contentsOf: moved) }
        if let parent, let i = state.folders.firstIndex(where: { $0.id == parent }) { state.folders[i].isExpanded = true }
        let tabIDs = state.tabs.filter { $0.folderID.map(ids.contains) ?? false }.map(\.id)
        for tab in tabIDs {
            guard let group = state.tabs.first(where: { $0.id == tab })?.folderID else { continue }
            state.moveTab(tab, to: space, folderID: group)
        }
        return true
    }
    @discardableResult
    func reorderSpace(_ id: UUID, relativeTo target: UUID, after: Bool) -> Bool {
        guard id != target, let from = state.spaces.firstIndex(where: { $0.id == id }), state.spaces.contains(where: { $0.id == target }) else { return false }
        let moving = state.spaces.remove(at: from)
        guard let anchor = state.spaces.firstIndex(where: { $0.id == target }) else { return false }
        state.spaces.insert(moving, at: anchor + (after ? 1 : 0)); return true
    }
    private func clearInvalidDragFocus() {
        if let focusedPane, focusedPane != state.selectedTabID && focusedPane != splitID { self.focusedPane = nil }
    }
    private func copyDragPayload(_ payload: BrowserDragPayload) -> BrowserDragItem? {
        func safe(_ tab: BrowserTab) -> Bool {
            guard let url = URL(string: tab.url) else { return false }
            return (["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil) || tab.url == "curve://start"
        }
        switch payload.item {
        case .tab:
            guard var tab = payload.tab, safe(tab) else { return nil }
            tab.id = UUID(); tab.spaceID = state.activeSpaceID; tab.folderID = nil; state.tabs.append(tab); return .tab(tab.id)
        case .folder(let sourceID):
            guard let root = payload.folders.first(where: { $0.id == sourceID }) else { return nil }
            let bundle = payload.folders.filter { $0.spaceID == root.spaceID && ($0.id == root.id || $0.name.hasPrefix(root.name + " / ")) }
            // Other windows may contain cloned IDs and the same folder paths.
            // Keep the incoming tree separate until dropFolder gives it its
            // final path, so prefix lookup cannot capture existing descendants.
            let namespace = "__CurveDrag_" + UUID().uuidString + " / "
            var map: [UUID: UUID] = [:]
            for folder in bundle { map[folder.id] = UUID() }
            for var folder in bundle { folder.id = map[folder.id]!; folder.name = namespace + folder.name; folder.spaceID = state.activeSpaceID; state.folders.append(folder) }
            for var tab in payload.tabs where safe(tab) && tab.folderID.flatMap({ map[$0] }) != nil {
                tab.id = UUID(); tab.spaceID = state.activeSpaceID; tab.folderID = tab.folderID.flatMap { map[$0] }; tab.kind = .pinned; state.tabs.append(tab)
            }
            return map[root.id].map(BrowserDragItem.folder)
        case .space:
            guard var space = payload.space else { return nil }
            let oldSelected = space.selectedTabID; let oldSplit = space.splitTabID
            space.id = UUID(); space.selectedTabID = nil; space.splitTabID = nil; state.spaces.append(space)
            var folders: [UUID: UUID] = [:]; var tabs: [UUID: UUID] = [:]
            for var folder in payload.folders { let old = folder.id; folder.id = UUID(); folders[old] = folder.id; folder.spaceID = space.id; state.folders.append(folder) }
            for var tab in payload.tabs where safe(tab) {
                let old = tab.id; tab.id = UUID(); tabs[old] = tab.id; tab.spaceID = space.id; tab.folderID = tab.folderID.flatMap { folders[$0] }; state.tabs.append(tab)
            }
            if let i = state.spaces.firstIndex(where: { $0.id == space.id }) {
                state.spaces[i].selectedTabID = oldSelected.flatMap { tabs[$0] }; state.spaces[i].splitTabID = oldSplit.flatMap { tabs[$0] }
            }
            return .space(space.id)
        }
    }
}
