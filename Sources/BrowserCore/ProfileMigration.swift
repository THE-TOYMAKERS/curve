import Foundation

/// Copies the previous app's saved sessions without moving or editing its data.
/// Website cookies, caches, passwords and unrelated files are never imported.
public enum ProfileMigration {
    private static let filenames = ["state.json", "state.backup.json", "history.json", "history.backup.json"]

    /// Returns true only when a new Curve directory was installed. An existing
    /// destination always wins, including an empty or partially recovered one.
    @discardableResult
    public static func copyLegacyProfile(from legacy: URL, to destination: URL,
                                         fileManager: FileManager = .default) throws -> Bool {
        let fm = fileManager
        if try SecureProfileStorage.directoryExists(destination) { return false }
        guard try SecureProfileStorage.directoryExists(legacy) else { return false }
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".Curve-migration-" + UUID().uuidString, isDirectory: true)
        try SecureProfileStorage.ensureDirectory(staging)
        defer { try? fm.removeItem(at: staging) }
        var copied = try copySessionFiles(from: legacy, to: staging)
        let oldWindows = legacy.appendingPathComponent("Windows", isDirectory: true)
        if try SecureProfileStorage.directoryExists(oldWindows) {
            for name in try SecureProfileStorage.entryNames(in: oldWindows) where UUID(uuidString: name) != nil {
                let window = oldWindows.appendingPathComponent(name, isDirectory: true)
                guard try SecureProfileStorage.directoryExists(window) else { continue }
                let target = staging.appendingPathComponent("Windows/" + name, isDirectory: true)
                try SecureProfileStorage.ensureDirectory(target)
                copied += try copySessionFiles(from: window, to: target)
            }
        }
        guard copied > 0 else { return false }
        // Rename only after every copy succeeds. A concurrent new destination
        // makes the exclusive rename fail rather than replacing that session.
        try SecureProfileStorage.installDirectory(staging, at: destination)
        return true
    }

    private static func copySessionFiles(from source: URL, to target: URL) throws -> Int {
        var copied = 0
        for name in filenames {
            // Never chmod or modify the old app's files during migration.
            guard let data = try SecureProfileStorage.readData(named: name, in: source, harden: false) else { continue }
            try SecureProfileStorage.writeData(data, named: name, in: target)
            copied += 1
        }
        return copied
    }
}
