import Foundation
import CryptoKit
@preconcurrency import WebKit
import BrowserCore
import Darwin

enum ContentProtectionError: Error, LocalizedError {
    case unavailableResources
    case corruptResources
    case unavailableRuleStore
    case compilationFailed

    var errorDescription: String? {
        switch self {
        case .unavailableResources: return "Curve’s bundled protection lists are missing. Reload after reinstalling Curve; this page has not been loaded."
        case .corruptResources: return "Curve’s bundled protection lists failed their integrity check. This page has not been loaded."
        case .unavailableRuleStore: return "WebKit’s protection-rule store is unavailable. This page has not been loaded."
        case .compilationFailed: return "WebKit could not prepare Curve’s protection rules. This page has not been loaded."
        }
    }
}

/// No runtime list downloads, remote configuration, or browsing telemetry.
/// Callers must await `ruleList(for:)` and add the returned list to a web view’s
/// user-content controller before invoking any page load or HTML load.
@MainActor
final class ContentProtection {
    static let shared = ContentProtection()
    static let sourceRevision = "3a0c0fcd8b22163e4d295eea1a6bca580518227e"
    static let sourceDate = "2026-11-11"
    static let bundledDomainCount = 38_212

    private static let files: [(name: String, bytes: Int, sha256: String)] = [
        ("ads.txt", 306_075, "dab8e5580364edae9783a6786263576ae5b0ae34f1b354eb58caf4311a9ea4bb"),
        ("trackers.txt", 259_965, "5551d002b0d477280cc47e026eab3a9499e0e9a30c44e335356eb9ed5113d8d4")
    ]
    private let resourceDirectory: URL?
    private let suppliedRuleStore: WKContentRuleListStore?
    private var cached: [ProtectionLevel: WKContentRuleList] = [:]
    private var pending: [ProtectionLevel: Task<WKContentRuleList, Error>] = [:]

    /// An explicit directory/store supports isolated tests. Production uses only
    /// the signed application bundle, never a writable or downloaded fallback.
    init(resourceDirectory: URL? = nil, ruleStore: WKContentRuleListStore? = nil) {
        self.resourceDirectory = resourceDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("Protection", isDirectory: true)
        self.suppliedRuleStore = ruleStore
    }

    func ruleList(for level: ProtectionLevel) async throws -> WKContentRuleList {
        guard level.isEnabled else { throw ProtectionRuleError.protectionDisabled }
        if let result = cached[level] { return result }
        if let task = pending[level] { return try await task.value }
        let task = Task { @MainActor [self] in try await compileVerifiedRules(for: level) }
        pending[level] = task
        do {
            let result = try await task.value
            pending[level] = nil
            cached[level] = result
            return result
        } catch {
            pending[level] = nil
            throw error
        }
    }

    private func compileVerifiedRules(for level: ProtectionLevel) async throws -> WKContentRuleList {
        guard let directory = resourceDirectory else { throw ContentProtectionError.unavailableResources }
        var domainSet = Set<String>()
        for file in Self.files {
            let url = directory.appendingPathComponent(file.name)
            let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw ContentProtectionError.unavailableResources }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_size == file.bytes else {
                try? handle.close(); throw ContentProtectionError.corruptResources
            }
            let data: Data
            do { data = try handle.read(upToCount: file.bytes + 1) ?? Data(); try handle.close() }
            catch { try? handle.close(); throw ContentProtectionError.unavailableResources }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == file.bytes, hash == file.sha256 else { throw ContentProtectionError.corruptResources }
            domainSet.formUnion(try ProtectionRules.domains(from: data))
        }
        guard domainSet.count == Self.bundledDomainCount else { throw ContentProtectionError.corruptResources }
        guard let store = suppliedRuleStore ?? WKContentRuleListStore.default() else { throw ContentProtectionError.unavailableRuleStore }
        let identifier = "Curve-Protection-v\(ProtectionRules.formatVersion)-\(Self.sourceRevision)-\(level.rawValue)"
        let existing: WKContentRuleList? = await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in continuation.resume(returning: list) }
        }
        if let existing { return existing }
        let encoded = try ProtectionRules.encodedRules(for: level, domains: Array(domainSet))
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded) { list, error in
                if let error { continuation.resume(throwing: error) }
                else if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: ContentProtectionError.compilationFailed) }
            }
        }
    }
}
