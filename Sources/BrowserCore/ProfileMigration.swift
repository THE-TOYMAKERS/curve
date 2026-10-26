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
        guard !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: legacy.path) else { return false }
        let sourceValues = try legacy.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".Curve-migration-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var copied = try copySessionFiles(from: legacy, to: staging, fileManager: fm)
        let oldWindows = legacy.appendingPathComponent("Windows", isDirectory: true)
        if fm.fileExists(atPath: oldWindows.path) {
            let values = try oldWindows.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
            for window in try fm.contentsOfDirectory(at: oldWindows, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                guard UUID(uuidString: window.lastPathComponent) != nil else { continue }
                let values = try window.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
                let target = staging.appendingPathComponent("Windows/" + window.lastPathComponent, isDirectory: true)
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                copied += try copySessionFiles(from: window, to: target, fileManager: fm)
            }
        }
        guard copied > 0 else { return false }
        // Rename only after every copy succeeds. A concurrent new destination
        // makes moveItem fail rather than replacing that session.
        try fm.moveItem(at: staging, to: destination)
        return true
    }

    private static func copySessionFiles(from source: URL, to target: URL,
                                         fileManager fm: FileManager) throws -> Int {
        var copied = 0
        for name in filenames {
            let file = source.appendingPathComponent(name)
            guard fm.fileExists(atPath: file.path) else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
            try fm.copyItem(at: file, to: target.appendingPathComponent(name))
            copied += 1
        }
        return copied
    }
}
