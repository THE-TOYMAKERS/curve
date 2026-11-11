import Foundation
import Darwin
import BrowserCore

/// Synthetic filesystem fixtures only. No actual browser profile is accessed.
@main
struct PrivacyStorageChecks {
    private static var assertions = 0
    private static var failures = 0
    private static let fm = FileManager.default

    private static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) rethrows {
        assertions += 1
        if try !condition() { failures += 1; print("FAIL: \(label)") }
    }
    private static func rejects(_ label: String, _ action: () throws -> Void) {
        assertions += 1
        do { try action(); failures += 1; print("FAIL: \(label) was accepted") }
        catch { }
    }
    private static func mode(_ url: URL) throws -> Int {
        (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777
    }
    private static func addReadACL(_ url: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/chmod")
        task.arguments = ["+a", "everyone allow read", url.path]
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw NSError(domain: "PrivacyStorageChecks.ACL", code: Int(task.terminationStatus)) }
    }
    private static func hasACL(_ url: URL) throws -> Bool {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOATTR { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        if result == 0 { return true }
        guard errno == EINVAL else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return false
    }

    static func main() {
        do { try runChecks() }
        catch { print("FAIL: Privacy storage fixture error: \(error)"); exit(1) }
    }

    private static func runChecks() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("curve-storage-checks-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? fm.removeItem(at: root) }

        let profile = root.appendingPathComponent("Curve", isDirectory: true)
        let state = StatePersistence(directory: profile)
        let history = BrowsingHistory(directory: profile)
        var original = BrowserState.initial
        _ = original.open(url: "https://private.example/?session=synthetic", title: "Sensitive synthetic tab")
        var changed = original
        _ = changed.addSpace(name: "Changed")
        let firstHistory = [HistoryEntry(title: "Private synthetic page", url: "https://private.example/one")]
        let secondHistory = [HistoryEntry(title: "Second synthetic page", url: "https://private.example/two")]

        _ = state.load(); _ = history.load()
        check(!fm.fileExists(atPath: profile.path), "reading absent metadata must not create a profile")
        try state.save(original); try state.save(changed)
        try history.save(firstHistory); try history.save(secondHistory)
        try check(mode(profile) == 0o700, "profile is owner-only")
        try check(mode(root) == 0o755, "unrelated parent permissions remain unchanged")
        for file in [state.stateURL, state.backupURL, history.historyURL, history.backupURL] {
            try check(mode(file) == 0o600, "metadata and backup are owner-only: \(file.lastPathComponent)")
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try addReadACL(file)
        }
        try addReadACL(profile); try addReadACL(root)
        try check(hasACL(profile) && hasACL(state.stateURL), "fixture installs extended read grants")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profile.path)
        check(state.load() == changed && history.load() == secondHistory, "permission upgrades preserve current data")
        try check(mode(profile) == 0o700, "load upgrades old directory permissions")
        for file in [state.stateURL, state.backupURL, history.historyURL, history.backupURL] {
            try check(mode(file) == 0o600, "load upgrades primary and backup permissions")
            try check(!hasACL(file), "load removes extra ACL grants from metadata and backup")
        }
        try check(!hasACL(profile), "load removes extra ACL grants from the designated profile directory")
        try check(hasACL(root), "hardening leaves unrelated parent ACLs unchanged")
        try Data("invalid JSON".utf8).write(to: state.stateURL)
        check(state.load() == original, "valid state backup survives primary corruption")
        try Data("invalid JSON".utf8).write(to: history.historyURL)
        check(history.load() == firstHistory, "valid history backup survives primary corruption")
        try state.save(changed); try history.save(secondHistory)
        try check(fm.contentsOfDirectory(atPath: profile.path).allSatisfy { !$0.hasPrefix(".curve-metadata-") }, "atomic saves leave no temporary metadata")

        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        let outsideState = StatePersistence(directory: outside)
        try outsideState.save(original)
        let protectedBytes = try Data(contentsOf: outsideState.stateURL)
        let alias = root.appendingPathComponent("LinkedProfile", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: outside)
        rejects("profile-directory symlink") { try StatePersistence(directory: alias).save(changed) }
        rejects("ancestor-directory symlink") { try StatePersistence(directory: alias.appendingPathComponent("nested")).save(changed) }
        rejects("clear through a directory symlink") { try StatePersistence(directory: alias).clear() }
        check(!StatePersistence(directory: alias).load().tabs.contains { $0.title == "Sensitive synthetic tab" }, "load does not follow a directory symlink")
        try check(Data(contentsOf: outsideState.stateURL) == protectedBytes, "directory attacks leave external state unchanged")
        check(!fm.fileExists(atPath: outside.appendingPathComponent("nested").path), "ancestor attack creates nothing outside the profile")

        let linked = root.appendingPathComponent("LinkedFiles", isDirectory: true)
        try SecureProfileStorage.ensureDirectory(linked)
        let linkState = StatePersistence(directory: linked)
        try fm.createSymbolicLink(at: linkState.stateURL, withDestinationURL: outsideState.stateURL)
        rejects("state-file symlink save") { try linkState.save(changed) }
        rejects("state-file symlink clear") { try linkState.clear() }
        check(!linkState.load().tabs.contains { $0.title == "Sensitive synthetic tab" }, "state load does not follow a file symlink")
        try fm.removeItem(at: linkState.stateURL)
        try linkState.save(changed)
        try fm.createSymbolicLink(at: linkState.backupURL, withDestinationURL: outsideState.stateURL)
        rejects("backup-file symlink save") { try linkState.save(original) }
        rejects("backup-file symlink clear") { try linkState.clear() }
        try check(Data(contentsOf: linkState.stateURL) != protectedBytes, "clear preflight preserves primary when backup is unsafe")
        try check(Data(contentsOf: outsideState.stateURL) == protectedBytes, "file attacks leave external bytes unchanged")

        let dangling = root.appendingPathComponent("Dangling", isDirectory: true)
        try SecureProfileStorage.ensureDirectory(dangling)
        let missing = root.appendingPathComponent("missing-target.json")
        try fm.createSymbolicLink(at: dangling.appendingPathComponent("history.json"), withDestinationURL: missing)
        rejects("dangling history symlink") { try BrowsingHistory(directory: dangling).save(firstHistory) }
        check(!fm.fileExists(atPath: missing.path), "dangling symlink target was not created")

        let hardlinked = root.appendingPathComponent("Hardlink", isDirectory: true)
        try SecureProfileStorage.ensureDirectory(hardlinked)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outsideState.stateURL.path)
        let hardlinkURL = hardlinked.appendingPathComponent("state.json")
        guard Darwin.link(outsideState.stateURL.path, hardlinkURL.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        rejects("hardlinked metadata") { try StatePersistence(directory: hardlinked).save(changed) }
        try check(mode(outsideState.stateURL) == 0o644, "hardlink rejection does not chmod the external inode")
        try check(Data(contentsOf: outsideState.stateURL) == protectedBytes, "hardlink rejection preserves external bytes")
        try fm.removeItem(at: hardlinkURL)
        rejects("metadata filename traversal") { try SecureProfileStorage.writeData(Data(), named: "../outside.json", in: profile) }
        rejects("bounded metadata read") { _ = try SecureProfileStorage.readData(named: "state.json", in: profile, maximumBytes: 3) }

        try history.clear(); try state.clear()
        check(!fm.fileExists(atPath: history.historyURL.path) && !fm.fileExists(atPath: history.backupURL.path), "history clear deletes primary and backup")
        check(!fm.fileExists(atPath: state.stateURL.path) && !fm.fileExists(atPath: state.backupURL.path), "session clear deletes primary and backup")
        check(history.load().isEmpty, "history backup cannot resurrect cleared visits")
        try history.clear(); try state.clear()

        let windows = profile.appendingPathComponent("Windows", isDirectory: true)
        let child = windows.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try state.save(original); try state.save(changed)
        try history.save(firstHistory); try history.save(secondHistory)
        let childState = StatePersistence(directory: child)
        try childState.save(original); try childState.save(changed)
        try BrowsingHistory(directory: child).save(firstHistory)
        let unknown = profile.appendingPathComponent("preferences.keep")
        try Data("Keep preferences".utf8).write(to: unknown)
        try ProfilePrivacy.eraseSavedSessions(in: profile)
        for directory in [profile, child] {
            try check(fm.contentsOfDirectory(atPath: directory.path).allSatisfy { !["state.json", "state.backup.json", "history.json", "history.backup.json"].contains($0) }, "global erasure includes all window metadata and backups")
        }
        try check(String(contentsOf: unknown) == "Keep preferences", "global erasure preserves unrelated files")
        try state.save(original)
        let hostileWindow = windows.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createSymbolicLink(at: hostileWindow, withDestinationURL: outside)
        rejects("global erasure with a symlinked window") { try ProfilePrivacy.eraseSavedSessions(in: profile) }
        check(fm.fileExists(atPath: state.stateURL.path), "global erasure preflights every window before deleting root state")

        let migrationRoot = root.appendingPathComponent("Migration", isDirectory: true)
        let legacy = migrationRoot.appendingPathComponent("Aperture", isDirectory: true)
        let destination = migrationRoot.appendingPathComponent("Curve", isDirectory: true)
        try StatePersistence(directory: legacy).save(original)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacy.path)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: legacy.appendingPathComponent("state.json").path)
        try addReadACL(legacy.appendingPathComponent("state.json"))
        try check(ProfileMigration.copyLegacyProfile(from: legacy, to: destination), "legacy profile migrates")
        try check(mode(legacy) == 0o755 && mode(legacy.appendingPathComponent("state.json")) == 0o644, "migration leaves legacy permissions unchanged")
        try check(hasACL(legacy.appendingPathComponent("state.json")), "migration leaves legacy ACLs unchanged")
        try check(mode(destination) == 0o700 && mode(destination.appendingPathComponent("state.json")) == 0o600, "migration protects destination permissions")
        check(StatePersistence(directory: destination).load() == original, "migration preserves profile contents")

        print("\(failures == 0 ? "PASS" : "FAIL"): Privacy storage checks: \(assertions) assertions; \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
