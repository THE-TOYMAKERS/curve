import Foundation

/// Executed only by SandboxChecks.sh in a freshly generated QA bundle identity.
/// The host creates the outside fixtures; this probe must not read or change
/// them. Results go through stdout, never through an outside result file.
@main
struct SandboxProbe {
    private static func isPermissionDenial(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(value.code) { return true }
        if value.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(value.code) { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenial(underlying) }
        return false
    }

    static func main() async {
        guard CommandLine.arguments.count == 6 else { fputs("SandboxProbe requires synthetic fixture arguments.\n", stderr); exit(2) }
        let identity = CommandLine.arguments[1]
        let outsideRead = URL(fileURLWithPath: CommandLine.arguments[2])
        let outsideWrite = URL(fileURLWithPath: CommandLine.arguments[3])
        guard let endpoint = URL(string: CommandLine.arguments[4]), endpoint.scheme == "http", endpoint.host == "127.0.0.1" else { exit(2) }
        let nonce = CommandLine.arguments[5]
        var checks: [String: Bool] = [:]
        var errors: [String] = []
        let requiredChecks = [
            "qa_bundle_identity", "container_home", "own_container_write_read",
            "secure_state_roundtrip", "secure_backup_recovery", "secure_history_roundtrip",
            "secure_history_backup_recovery", "secure_directory_permissions", "secure_file_permissions",
            "secure_clearing_both_backups", "secure_selective_window_history_erasure",
            "secure_full_window_metadata_erasure", "secure_storage_reusable_after_erasure",
            "outside_read_denied", "outside_write_denied", "localhost_outbound_network"
        ]
        for name in requiredChecks { checks[name] = false }

        checks["qa_bundle_identity"] = Bundle.main.bundleIdentifier == identity && identity.hasPrefix("com.toymakers.curve.qa.sandbox.")
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        checks["container_home"] = home.path.hasSuffix("/Library/Containers/\(identity)/Data")
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let ownDirectory = support.appendingPathComponent("SyntheticSandboxProbe", isDirectory: true)
            try FileManager.default.createDirectory(at: ownDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: ownDirectory) }
            let ownFile = ownDirectory.appendingPathComponent("own-container.txt")
            try Data(nonce.utf8).write(to: ownFile, options: .atomic)
            let readBack = try Data(contentsOf: ownFile)
            checks["own_container_write_read"] = readBack == Data(nonce.utf8) && ownFile.path.hasPrefix(home.path + "/")
            let profile = ownDirectory.appendingPathComponent("Curve", isDirectory: true)
            let persistence = StatePersistence(directory: profile)
            let history = BrowsingHistory(directory: profile)
            let space = BrowserSpace(name: "Synthetic sandbox", emoji: "T", colorHex: "BDB6DD")
            var original = BrowserState(spaces: [space], autoArchiveHours: 0)
            let pin = original.open(url: "https://pin.sandbox-fixture.invalid/" + nonce, title: "Synthetic pin", kind: .pinned)
            let archived = BrowserTab(title: "Synthetic archive", url: "https://archive.sandbox-fixture.invalid/" + nonce, spaceID: space.id)
            original.archive = [ArchivedTab(tab: archived)]
            var changed = original
            _ = changed.open(url: "curve://start", title: "Synthetic start")
            try persistence.save(original)
            try persistence.save(changed)
            checks["secure_state_roundtrip"] = persistence.load() == changed
            try Data("broken primary".utf8).write(to: persistence.stateURL)
            checks["secure_backup_recovery"] = persistence.load() == original
            try persistence.save(changed)
            let firstVisits = [HistoryEntry(title: "Synthetic first", url: "https://history.sandbox-fixture.invalid/first")]
            let secondVisits = [HistoryEntry(title: "Synthetic second", url: "https://history.sandbox-fixture.invalid/second")]
            try history.save(firstVisits)
            try history.save(secondVisits)
            checks["secure_history_roundtrip"] = history.load() == secondVisits
            try Data("broken history".utf8).write(to: history.historyURL)
            checks["secure_history_backup_recovery"] = history.load() == firstVisits
            try history.save(secondVisits)
            func mode(_ url: URL) throws -> Int {
                (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777
            }
            checks["secure_directory_permissions"] = try mode(profile) == 0o700
            checks["secure_file_permissions"] = try [persistence.stateURL, persistence.backupURL, history.historyURL, history.backupURL].allSatisfy { try mode($0) == 0o600 }
            try history.clear(); try persistence.clear()
            checks["secure_clearing_both_backups"] = [persistence.stateURL, persistence.backupURL, history.historyURL, history.backupURL].allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } && history.load().isEmpty

            let window = profile.appendingPathComponent("Windows/" + UUID().uuidString, isDirectory: true)
            let windowPersistence = StatePersistence(directory: window)
            try persistence.save(original); try persistence.save(changed)
            try windowPersistence.save(original); try windowPersistence.save(changed)
            try BrowsingHistory(directory: window).save(firstVisits)
            try history.save(firstVisits); try history.save(secondVisits)
            try ProfilePrivacy.eraseHistory(in: profile)
            let scrubbed = windowPersistence.load()
            checks["secure_selective_window_history_erasure"] = scrubbed.tabs.contains { $0.id == pin } && scrubbed.archive.isEmpty && persistence.load().archive.isEmpty && history.load().isEmpty && !FileManager.default.fileExists(atPath: windowPersistence.backupURL.path)
            try ProfilePrivacy.eraseSavedSessions(in: profile)
            checks["secure_full_window_metadata_erasure"] = [profile, window].allSatisfy { directory in
                ["state.json", "state.backup.json", "history.json", "history.backup.json"].allSatisfy { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
            }
            try persistence.save(changed)
            checks["secure_storage_reusable_after_erasure"] = persistence.load() == changed
        } catch { errors.append("own-container/real profile helper I/O failed: \(error.localizedDescription) [\((error as NSError).domain):\((error as NSError).code)]") }

        do {
            _ = try Data(contentsOf: outsideRead)
            checks["outside_read_denied"] = false
        } catch {
            checks["outside_read_denied"] = isPermissionDenial(error)
            if checks["outside_read_denied"] != true { errors.append("outside read failed for a reason other than permission denial") }
        }
        do {
            try Data("must-not-write".utf8).write(to: outsideWrite, options: .atomic)
            checks["outside_write_denied"] = false
        } catch {
            checks["outside_write_denied"] = isPermissionDenial(error)
            if checks["outside_write_denied"] != true { errors.append("outside write failed for a reason other than permission denial") }
        }
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 6
            configuration.timeoutIntervalForResource = 10
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: endpoint)
            checks["localhost_outbound_network"] = (response as? HTTPURLResponse)?.statusCode == 200 && data == Data(nonce.utf8)
        } catch { checks["localhost_outbound_network"] = false; errors.append("localhost request failed: \((error as NSError).domain):\((error as NSError).code)") }

        let passed = checks.count == requiredChecks.count && checks.values.allSatisfy { $0 } && errors.isEmpty
        let report: [String: Any] = ["passed": passed, "identity": identity, "checks": checks, "errors": errors]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
        exit(passed ? 0 : 1)
    }
}
