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
        try? SecureProfileStorage.validateFiles(named: [historyURL.lastPathComponent, backupURL.lastPathComponent], in: directory)
        for url in [historyURL, backupURL] {
            if let data = try? SecureProfileStorage.readData(named: url.lastPathComponent, in: directory, maximumBytes: 16 * 1024 * 1024), let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
                return Array(entries.prefix(Self.maximumEntries))
            }
        }
        return []
    }
    public func save(_ entries: [HistoryEntry]) throws {
        try SecureProfileStorage.ensureDirectory(directory)
        try SecureProfileStorage.validateFiles(named: [historyURL.lastPathComponent, backupURL.lastPathComponent], in: directory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Array(entries.prefix(Self.maximumEntries)))
        if let existing = try SecureProfileStorage.readData(named: historyURL.lastPathComponent, in: directory, maximumBytes: 16 * 1024 * 1024), (try? JSONDecoder().decode([HistoryEntry].self, from: existing)) != nil {
            try SecureProfileStorage.writeData(existing, named: backupURL.lastPathComponent, in: directory)
        }
        try SecureProfileStorage.writeData(data, named: historyURL.lastPathComponent, in: directory)
    }
    public func clear() throws {
        try SecureProfileStorage.removeFiles(named: [historyURL.lastPathComponent, backupURL.lastPathComponent], in: directory)
    }
}
