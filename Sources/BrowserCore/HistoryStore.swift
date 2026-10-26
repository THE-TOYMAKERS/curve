import Foundation

/// Independent history storage so session migration and private windows need not touch history.
/// Callers supply newest-first entries. Reading does not create directories or files.
public struct BrowsingHistory {
    public static let maximumEntries = 2000
    public let directory: URL
    public var historyURL: URL { directory.appendingPathComponent("history.json") }
    public var backupURL: URL { directory.appendingPathComponent("history.backup.json") }
    public init(directory: URL) { self.directory = directory }
    public func load() -> [HistoryEntry] {
        for url in [historyURL, backupURL] {
            if let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
                return Array(entries.prefix(Self.maximumEntries))
            }
        }
        return []
    }
    public func save(_ entries: [HistoryEntry]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Array(entries.prefix(Self.maximumEntries)))
        if let existing = try? Data(contentsOf: historyURL), (try? JSONDecoder().decode([HistoryEntry].self, from: existing)) != nil {
            try existing.write(to: backupURL, options: .atomic)
        }
        try data.write(to: historyURL, options: .atomic)
    }
}
