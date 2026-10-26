import Foundation

public enum TabKind: String, Codable, CaseIterable, Sendable { case today, pinned, favorite }

public struct BrowserTab: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var customTitle: String?
    public var url: String
    public var kind: TabKind
    public var savedURL: String?
    public var spaceID: UUID
    public var folderID: UUID?
    public var lastAccessed: Date
    public var createdAt: Date
    public init(id: UUID = UUID(), title: String, customTitle: String? = nil, url: String, kind: TabKind = .today, savedURL: String? = nil, spaceID: UUID, folderID: UUID? = nil, lastAccessed: Date = Date(), createdAt: Date = Date()) {
        self.id = id; self.title = title; self.customTitle = customTitle; self.url = url; self.kind = kind; self.savedURL = savedURL ?? (kind == .today ? nil : url); self.spaceID = spaceID; self.folderID = folderID; self.lastAccessed = lastAccessed; self.createdAt = createdAt
    }
}
public struct BrowserSpace: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var emoji: String
    public var colorHex: String
    public var theme: BrowserTheme?
    public var selectedTabID: UUID?
    public var splitTabID: UUID?
    public var splitVertical: Bool
    public init(id: UUID = UUID(), name: String, emoji: String, colorHex: String, theme: BrowserTheme? = nil, selectedTabID: UUID? = nil, splitTabID: UUID? = nil, splitVertical: Bool = false) {
        self.id = id; self.name = name; self.emoji = emoji; self.colorHex = colorHex; self.theme = theme; self.selectedTabID = selectedTabID; self.splitTabID = splitTabID; self.splitVertical = splitVertical
    }
}
extension BrowserSpace {
    private enum CodingKeys: String, CodingKey { case id, name, emoji, colorHex, theme, selectedTabID, splitTabID, splitVertical }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        emoji = try values.decode(String.self, forKey: .emoji)
        colorHex = try values.decode(String.self, forKey: .colorHex)
        theme = try values.decodeIfPresent(BrowserTheme.self, forKey: .theme)
        selectedTabID = try values.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        splitTabID = try values.decodeIfPresent(UUID.self, forKey: .splitTabID)
        splitVertical = try values.decodeIfPresent(Bool.self, forKey: .splitVertical) ?? false
    }
}
public struct BrowserFolder: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var spaceID: UUID
    public var name: String
    public var isExpanded: Bool
    public init(id: UUID = UUID(), spaceID: UUID, name: String, isExpanded: Bool = true) {
        self.id = id; self.spaceID = spaceID; self.name = name; self.isExpanded = isExpanded
    }
}
public struct ArchivedTab: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var tab: BrowserTab
    public var closedAt: Date
    public init(id: UUID = UUID(), tab: BrowserTab, closedAt: Date = Date()) { self.id = id; self.tab = tab; self.closedAt = closedAt }
}
public struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: String
    public var visitedAt: Date
    public init(id: UUID = UUID(), title: String, url: String, visitedAt: Date = Date()) {
        self.id = id; self.title = title; self.url = url; self.visitedAt = visitedAt
    }
}
public struct BrowserState: Codable, Equatable, Sendable {
    public var spaces: [BrowserSpace]
    public var tabs: [BrowserTab]
    public var folders: [BrowserFolder]
    public var archive: [ArchivedTab]
    public var activeSpaceID: UUID
    public var sidebarWidth: Double
    public var sidebarVisible: Bool
    public var autoArchiveHours: Double
    public var maxLiveTabs: Int
    public var searchEngine: String
    public var appearanceVersion: Int?
    public init(spaces: [BrowserSpace], tabs: [BrowserTab] = [], folders: [BrowserFolder] = [], archive: [ArchivedTab] = [], activeSpaceID: UUID? = nil, sidebarWidth: Double = 224, sidebarVisible: Bool = true, autoArchiveHours: Double = 12, maxLiveTabs: Int = 6, searchEngine: String = "duckduckgo", appearanceVersion: Int? = 2) {
        self.spaces = spaces; self.tabs = tabs; self.folders = folders; self.archive = archive; self.activeSpaceID = activeSpaceID ?? spaces.first?.id ?? UUID(); self.sidebarWidth = sidebarWidth; self.sidebarVisible = sidebarVisible; self.autoArchiveHours = autoArchiveHours; self.maxLiveTabs = maxLiveTabs; self.searchEngine = searchEngine; self.appearanceVersion = appearanceVersion
        repair()
    }
    public static var initial: BrowserState {
        let personal = BrowserSpace(name: "Personal", emoji: "◈", colorHex: "BDB6DD")
        let work = BrowserSpace(name: "Work", emoji: "✳", colorHex: "A9CADD")
        let focus = BrowserSpace(name: "Focus", emoji: "☀", colorHex: "E7C4AE")
        var state = BrowserState(spaces: [personal, work, focus])
        _ = state.open(url: "https://www.are.na", title: "Are.na", kind: .favorite)
        _ = state.open(url: "https://www.apple.com", title: "Apple", kind: .favorite)
        _ = state.open(url: "https://www.swift.org", title: "Swift", kind: .pinned, spaceID: work.id)
        _ = state.open(url: "curve://start", title: "A little room for the internet", spaceID: personal.id)
        state.activeSpaceID = personal.id
        return state
    }
    public var activeSpace: BrowserSpace { spaces.first(where: { $0.id == activeSpaceID }) ?? spaces[0] }
    public var visibleTabs: [BrowserTab] { tabs.filter { $0.kind == .favorite || $0.spaceID == activeSpaceID } }
    public var selectedTabID: UUID? {
        guard let id = spaces.first(where: { $0.id == activeSpaceID })?.selectedTabID,
              tabs.contains(where: { $0.id == id && ($0.spaceID == activeSpaceID || $0.kind == .favorite) }) else { return nil }
        return id
    }
    @discardableResult public mutating func open(url: String, title: String = "New Tab", kind: TabKind = .today, spaceID: UUID? = nil, folderID: UUID? = nil) -> UUID {
        let target = spaces.contains(where: { $0.id == spaceID }) ? spaceID! : activeSpaceID
        let validFolder = folders.first(where: { $0.id == folderID && $0.spaceID == target })?.id
        let tab = BrowserTab(title: title, url: url, kind: validFolder == nil ? kind : .pinned, spaceID: target, folderID: validFolder)
        tabs.append(tab); activeSpaceID = target; select(tab.id)
        return tab.id
    }
    public mutating func select(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[index].kind != .favorite { activeSpaceID = tabs[index].spaceID }
        tabs[index].lastAccessed = Date()
        if let index = spaces.firstIndex(where: { $0.id == activeSpaceID }) { spaces[index].selectedTabID = id }
    }
    /// Closing a pin or favorite returns it to its saved URL; explicit removal uses removeTab.
    public mutating func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[index].kind != .today {
            tabs[index].url = tabs[index].savedURL ?? tabs[index].url
            return
        }
        removeTab(id)
    }
    /// Archives any kind, preserving a reversible explicit removal.
    public mutating func removeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        archive.insert(ArchivedTab(tab: tab), at: 0)
        if archive.count > 2000 { archive.removeLast(archive.count - 2000) }
        for i in spaces.indices where spaces[i].splitTabID == id { spaces[i].splitTabID = nil }
        for i in spaces.indices where spaces[i].selectedTabID == id {
            spaces[i].selectedTabID = tabs.filter { $0.spaceID == spaces[i].id || $0.kind == .favorite }.max(by: { $0.lastAccessed < $1.lastAccessed })?.id
        }
    }
    public mutating func restore(_ id: UUID) {
        guard let index = archive.firstIndex(where: { $0.id == id }) else { return }
        var tab = archive.remove(at: index).tab
        if tabs.contains(where: { $0.id == tab.id }) { tab.id = UUID() }
        if !spaces.contains(where: { $0.id == tab.spaceID }) { tab.spaceID = activeSpaceID }
        if !folders.contains(where: { $0.id == tab.folderID && $0.spaceID == tab.spaceID }) { tab.folderID = nil }
        tab.lastAccessed = Date(); tabs.append(tab); select(tab.id)
    }
    public mutating func togglePin(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].kind = tabs[index].kind == .pinned ? .today : .pinned
        tabs[index].savedURL = tabs[index].kind == .today ? nil : tabs[index].url
        if tabs[index].kind == .today { tabs[index].folderID = nil }
    }
    public mutating func toggleFavorite(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].kind = tabs[index].kind == .favorite ? .pinned : .favorite
        tabs[index].savedURL = tabs[index].savedURL ?? tabs[index].url
        tabs[index].folderID = nil
    }
    public mutating func switchSpace(_ id: UUID) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        activeSpaceID = id
    }
    @discardableResult public mutating func addSpace(name: String, emoji: String = "◈", colorHex: String = "BDB6DD") -> UUID {
        let space = BrowserSpace(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : name, emoji: emoji, colorHex: colorHex)
        spaces.append(space); activeSpaceID = space.id; return space.id
    }
    @discardableResult public mutating func addFolder(name: String, spaceID: UUID? = nil) -> UUID {
        let folder = BrowserFolder(spaceID: spaceID ?? activeSpaceID, name: name.isEmpty ? "Untitled" : name)
        folders.append(folder); return folder.id
    }
    public mutating func moveTab(_ id: UUID, to spaceID: UUID, folderID: UUID? = nil) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), spaces.contains(where: { $0.id == spaceID }) else { return }
        let validFolder = folders.first(where: { $0.id == folderID && $0.spaceID == spaceID })?.id
        tabs[i].spaceID = spaceID; tabs[i].folderID = validFolder
        if validFolder != nil { tabs[i].kind = .pinned; tabs[i].savedURL = tabs[i].savedURL ?? tabs[i].url }
        for s in spaces.indices where spaces[s].id != spaceID && tabs[i].kind != .favorite {
            if spaces[s].selectedTabID == id {
                spaces[s].selectedTabID = tabs.filter { $0.id != id && ($0.spaceID == spaces[s].id || $0.kind == .favorite) }.max(by: { $0.lastAccessed < $1.lastAccessed })?.id
            }
            if spaces[s].splitTabID == id { spaces[s].splitTabID = nil }
        }
    }
    public mutating func reorderTab(_ id: UUID, before otherID: UUID) {
        guard id != otherID, let from = tabs.firstIndex(where: { $0.id == id }), tabs.contains(where: { $0.id == otherID }) else { return }
        let tab = tabs.remove(at: from)
        if let target = tabs.firstIndex(where: { $0.id == otherID }) { tabs.insert(tab, at: target) }
    }
    public mutating func archiveExpired(now: Date = Date(), protectedIDs: Set<UUID> = []) {
        guard autoArchiveHours > 0 else { return }
        let selected = Set(spaces.compactMap(\.selectedTabID) + spaces.compactMap(\.splitTabID)).union(protectedIDs)
        let expired = tabs.filter { $0.kind == .today && !selected.contains($0.id) && now.timeIntervalSince($0.lastAccessed) > autoArchiveHours * 3600 }.map(\.id)
        for id in expired { close(id) }
    }
    public mutating func repair() {
        if spaces.isEmpty { spaces = [BrowserSpace(name: "Personal", emoji: "◈", colorHex: "BDB6DD")] }
        var seenSpaces = Set<UUID>(); spaces = spaces.filter { seenSpaces.insert($0.id).inserted }
        if !spaces.contains(where: { $0.id == activeSpaceID }) { activeSpaceID = spaces[0].id }
        var seenFolders = Set<UUID>(); folders = folders.filter { folder in spaces.contains(where: { $0.id == folder.spaceID }) && seenFolders.insert(folder.id).inserted }
        var seenTabs = Set<UUID>(); tabs = tabs.filter { seenTabs.insert($0.id).inserted }
        for i in tabs.indices {
            // Session compatibility with the app's previous name; website URLs
            // and tab identities are otherwise preserved.
            if tabs[i].url == "aperture://start" { tabs[i].url = "curve://start" }
            if tabs[i].savedURL == "aperture://start" { tabs[i].savedURL = "curve://start" }
            if !spaces.contains(where: { $0.id == tabs[i].spaceID }) { tabs[i].spaceID = activeSpaceID }
            if !folders.contains(where: { $0.id == tabs[i].folderID && $0.spaceID == tabs[i].spaceID }) { tabs[i].folderID = nil }
            if tabs[i].folderID != nil && tabs[i].kind == .today { tabs[i].kind = .pinned }
            if tabs[i].kind == .favorite { tabs[i].folderID = nil }
        }
        for i in archive.indices {
            if archive[i].tab.url == "aperture://start" { archive[i].tab.url = "curve://start" }
            if archive[i].tab.savedURL == "aperture://start" { archive[i].tab.savedURL = "curve://start" }
        }
        for i in spaces.indices {
            if let id = spaces[i].splitTabID, !tabs.contains(where: { $0.id == id && ($0.spaceID == spaces[i].id || $0.kind == .favorite) }) { spaces[i].splitTabID = nil }
            if spaces[i].splitTabID == spaces[i].selectedTabID { spaces[i].splitTabID = nil }
            if let id = spaces[i].selectedTabID, !tabs.contains(where: { $0.id == id && ($0.spaceID == spaces[i].id || $0.kind == .favorite) }) { spaces[i].selectedTabID = nil }
        }
        sidebarWidth = sidebarWidth.isFinite ? min(380, max(200, sidebarWidth)) : 224
        autoArchiveHours = autoArchiveHours.isFinite ? min(8760, max(0, autoArchiveHours)) : 12
        maxLiveTabs = min(24, max(2, maxLiveTabs))
        if searchEngine != "google" { searchEngine = "duckduckgo" }
    }
}
