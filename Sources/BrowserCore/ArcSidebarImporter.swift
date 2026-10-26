import Foundation

public enum ArcImportError: LocalizedError {
    case invalidSidebar
    public var errorDescription: String? { "This file does not contain a supported Arc sidebar. Choose Arc’s StorableSidebar.json file." }
}

/// Reads Arc's exported local sidebar only. It never reads account, cookie, or credential databases.
public enum ArcSidebarImporter {
    public static func importFile(_ url: URL, into state: BrowserState) throws -> BrowserState {
        try importData(Data(contentsOf: url), into: state)
    }
    public static func importData(_ data: Data, into state: BrowserState) throws -> BrowserState {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = json["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [[String: Any]],
              let container = containers.first(where: { $0["spaces"] != nil }),
              let rawSpaces = container["spaces"] as? [Any],
              let rawItems = container["items"] as? [Any] else { throw ArcImportError.invalidSidebar }
        let sourceSpaces = records(rawSpaces)
        let sourceItems = records(rawItems)
        guard !sourceSpaces.isEmpty else { throw ArcImportError.invalidSidebar }
        var result = state
        var items: [String: [String: Any]] = [:]
        for item in sourceItems { if let id = item["id"] as? String { items[id] = item } }
        var roots: [(root: String, space: UUID, kind: TabKind)] = []
        var firstImportedSpace: UUID?
        for source in sourceSpaces {
            guard let sourceID = source["id"] as? String else { continue }
            let id = UUID(uuidString: sourceID) ?? UUID()
            if firstImportedSpace == nil { firstImportedSpace = id }
            let custom = source["customInfo"] as? [String: Any] ?? [:]
            let icons = custom["iconType"] as? [String: Any] ?? [:]
            var emoji = icons["emoji_v2"] as? String ?? "◈"
            if emoji == "◈", let scalar = icons["emoji"] as? UInt32, let unicode = Unicode.Scalar(scalar) { emoji = String(unicode) }
            let sourceTheme = custom["windowTheme"] as? [String: Any] ?? [:]
            let theme = readTheme(sourceTheme)
            let hex = theme?.baseColors.first?.hex ?? "BDB6DD"
            if let index = result.spaces.firstIndex(where: { $0.id == id }) {
                result.spaces[index].theme = theme
                result.spaces[index].colorHex = hex
            } else {
                result.spaces.append(BrowserSpace(id: id, name: source["title"] as? String ?? "Imported", emoji: emoji, colorHex: hex, theme: theme))
            }
            // Arc encodes a Swift dictionary as alternating key/value elements.
            let rootIDs = source["containerIDs"] as? [Any] ?? source["newContainerIDs"] as? [Any] ?? []
            var index = 0
            while index + 1 < rootIDs.count {
                let key = rootIDs[index]
                let value = rootIDs[index + 1]
                let isPinned = (key as? String) == "pinned" || (key as? [String: Any])?["pinned"] != nil
                if let value = value as? String { roots.append((value, id, isPinned ? .pinned : .today)) }
                index += 2
            }
        }
        guard let initialSpace = firstImportedSpace else { throw ArcImportError.invalidSidebar }
        if let favoriteIDs = container["topAppsContainerIDs"] as? [Any] {
            for root in favoriteIDs.compactMap({ $0 as? String }) { roots.append((root, initialSpace, .favorite)) }
        }
        // Parent references are authoritative even when a root has no childrenIds list.
        var children: [String: [String]] = [:]
        for item in sourceItems {
            guard let id = item["id"] as? String, let parent = item["parentID"] as? String else { continue }
            children[parent, default: []].append(id)
        }
        var visited = Set<String>()
        func walk(_ sourceID: String, spaceID: UUID, kind: TabKind, folderID: UUID?, path: [String]) {
            guard visited.insert(sourceID).inserted else { return }
            guard let item = items[sourceID] else {
                for child in children[sourceID] ?? [] { walk(child, spaceID: spaceID, kind: kind, folderID: folderID, path: path) }
                return
            }
            let payload = item["data"] as? [String: Any] ?? [:]
            var nextFolder = folderID
            var nextPath = path
            if payload["list"] != nil {
                let name = item["title"] as? String ?? "Folder"
                nextPath.append(name)
                let id = UUID(uuidString: sourceID) ?? UUID()
                if !result.folders.contains(where: { $0.id == id }) { result.folders.append(BrowserFolder(id: id, spaceID: spaceID, name: nextPath.joined(separator: " / "), isExpanded: false)) }
                nextFolder = id
            }
            if let tab = payload["tab"] as? [String: Any], let rawURL = tab["savedURL"] as? String,
               let url = URL(string: rawURL), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                let id = UUID(uuidString: sourceID) ?? UUID()
                if !result.tabs.contains(where: { $0.id == id }) {
                    let title = item["title"] as? String ?? tab["savedTitle"] as? String ?? url.host ?? "Imported Tab"
                    // A newly imported tab gets a fresh archive grace period.
                    result.tabs.append(BrowserTab(id: id, title: title, url: rawURL, kind: kind, spaceID: spaceID, folderID: kind == .favorite ? nil : nextFolder))
                }
            }
            let ordered = item["childrenIds"] as? [String] ?? []
            let remaining = (children[sourceID] ?? []).filter { !ordered.contains($0) }
            for child in ordered + remaining { walk(child, spaceID: spaceID, kind: kind, folderID: nextFolder, path: nextPath) }
        }
        for root in roots { walk(root.root, spaceID: root.space, kind: root.kind, folderID: nil, path: []) }
        result.activeSpaceID = initialSpace
        for i in result.spaces.indices where result.spaces[i].selectedTabID == nil {
            result.spaces[i].selectedTabID = result.tabs.first(where: { $0.spaceID == result.spaces[i].id && $0.kind != .favorite })?.id
        }
        result.repair()
        return result
    }
    /// Upgrades only the appearance of matching spaces from an older import.
    /// It cannot add tabs, change selection, rename a space, or touch logins.
    public static func refreshThemes(from url: URL, into state: BrowserState) throws -> BrowserState {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let sidebar = json?["sidebar"] as? [String: Any], let containers = sidebar["containers"] as? [[String: Any]] else { throw ArcImportError.invalidSidebar }
        var result = state
        for container in containers {
            for source in records(container["spaces"] as? [Any] ?? []) {
                guard let text = source["id"] as? String, let id = UUID(uuidString: text), let i = result.spaces.firstIndex(where: { $0.id == id }),
                      let custom = source["customInfo"] as? [String: Any], let raw = custom["windowTheme"] as? [String: Any], let theme = readTheme(raw) else { continue }
                result.spaces[i].theme = theme; result.spaces[i].colorHex = theme.baseColors.first?.hex ?? result.spaces[i].colorHex
            }
        }
        return result
    }
    private static func rgba(_ raw: Any?) -> ThemeColor? {
        guard let color = raw as? [String: Any], let r = color["red"] as? Double, let g = color["green"] as? Double, let b = color["blue"] as? Double else { return nil }
        return ThemeColor(red: r, green: g, blue: b, alpha: color["alpha"] as? Double ?? 1)
    }
    private static func find(_ key: String, in value: Any) -> Any? {
        if let dict = value as? [String: Any] {
            if let found = dict[key] { return found }
            for name in dict.keys.sorted() { if let found = find(key, in: dict[name]!) { return found } }
        } else if let values = value as? [Any] {
            for value in values { if let found = find(key, in: value) { return found } }
        }
        return nil
    }
    private static func readTheme(_ raw: [String: Any]) -> BrowserTheme? {
        let background = raw["background"] ?? [:]
        let gradient = (find("blendedGradient", in: background) as? [String: Any])?["_0"] as? [String: Any] ?? [:]
        let palette = raw["primaryColorPalette"] as? [String: Any] ?? [:]
        let base = (gradient["baseColors"] as? [Any] ?? []).compactMap { rgba($0) }
        let fallback = rgba(palette["midTone"]) ?? rgba(palette["shaded"]) ?? rgba(palette["tintedLight"])
        let colors = base.isEmpty ? fallback.map { [$0] } ?? [] : base
        guard !colors.isEmpty else { return nil }
        let modifiers = gradient["modifiers"] as? [String: Any] ?? [:]
        let appearance = find("contentOverBackgroundAppearance", in: background) as? String ?? "light"
        let dark = appearance == "dark"
        let semantic = raw["semanticColorPalette"] as? [String: Any] ?? [:]
        let palettes = semantic["appearanceBased"] as? [String: Any] ?? [:]
        let active = palettes[dark ? "dark" : "light"] as? [String: Any] ?? [:]
        return BrowserTheme(baseColors: colors, overlayColors: (gradient["overlayColors"] as? [Any] ?? []).compactMap { rgba($0) }, intensity: modifiers["intensityFactor"] as? Double ?? 0.8, noise: modifiers["noiseFactor"] as? Double ?? 0.2, isVibrant: find("isVibrant", in: background) as? Bool ?? true, isDark: dark, ink: rgba(active["title"]))
    }
    private static func records(_ array: [Any]) -> [[String: Any]] {
        array.compactMap { $0 as? [String: Any] }.map { record in
            if let value = record["value"] as? [String: Any] { return value }
            return record
        }
    }
}
