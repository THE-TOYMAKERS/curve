import Foundation

public struct StatePersistence {
    public let directory: URL
    public var stateURL: URL { directory.appendingPathComponent("state.json") }
    public var backupURL: URL { directory.appendingPathComponent("state.backup.json") }
    public init(directory: URL) { self.directory = directory }
    public func load() -> BrowserState {
        // Upgrade permissions on both regular metadata files, including the
        // backup even when the primary decodes successfully.
        try? SecureProfileStorage.validateFiles(named: [stateURL.lastPathComponent, backupURL.lastPathComponent], in: directory)
        for url in [stateURL, backupURL] {
            if let data = try? SecureProfileStorage.readData(named: url.lastPathComponent, in: directory), var state = try? JSONDecoder().decode(BrowserState.self, from: data) {
                state.repair(); return state
            }
        }
        return .initial
    }
    public func save(_ state: BrowserState) throws {
        try SecureProfileStorage.ensureDirectory(directory)
        try SecureProfileStorage.validateFiles(named: [stateURL.lastPathComponent, backupURL.lastPathComponent], in: directory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var valid = state; valid.repair()
        let data = try encoder.encode(valid)
        if let existing = try SecureProfileStorage.readData(named: stateURL.lastPathComponent, in: directory), (try? JSONDecoder().decode(BrowserState.self, from: existing)) != nil {
            try SecureProfileStorage.writeData(existing, named: backupURL.lastPathComponent, in: directory)
        }
        try SecureProfileStorage.writeData(data, named: stateURL.lastPathComponent, in: directory)
    }
    public func clear() throws {
        try SecureProfileStorage.removeFiles(named: [stateURL.lastPathComponent, backupURL.lastPathComponent], in: directory)
    }
}
