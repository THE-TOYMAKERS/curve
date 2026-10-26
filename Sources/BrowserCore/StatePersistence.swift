import Foundation

public struct StatePersistence {
    public let directory: URL
    public var stateURL: URL { directory.appendingPathComponent("state.json") }
    public var backupURL: URL { directory.appendingPathComponent("state.backup.json") }
    public init(directory: URL) { self.directory = directory }
    public func load() -> BrowserState {
        for url in [stateURL, backupURL] {
            if let data = try? Data(contentsOf: url), var state = try? JSONDecoder().decode(BrowserState.self, from: data) {
                state.repair(); return state
            }
        }
        return .initial
    }
    public func save(_ state: BrowserState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var valid = state; valid.repair()
        let data = try encoder.encode(valid)
        if let existing = try? Data(contentsOf: stateURL), (try? JSONDecoder().decode(BrowserState.self, from: existing)) != nil {
            try existing.write(to: backupURL, options: .atomic)
        }
        try data.write(to: stateURL, options: .atomic)
    }
}
