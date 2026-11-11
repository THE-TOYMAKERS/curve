import Foundation
import Combine

/// A read-only, user-triggered update check. No downloaded code is executed or
/// installed, and release-provided URLs are never opened without validation.
@MainActor
final class ReleaseUpdateChecker: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var message: String?
    @Published private(set) var releaseURL: URL?
    private struct Release: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool }

    static func version(_ string: String) -> [Int]? {
        let raw = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(part), value < 1_000_000 else { return nil }
            result.append(value)
        }
        return result
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true; releaseURL = nil; message = nil
        defer { isChecking = false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let endpoint = URL(string: "https://api.github.com/repos/THE-TOYMAKERS/curve/releases/latest")!
            var request = URLRequest(url: endpoint)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Curve-update-check", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.url == endpoint else { throw UpdateError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 262_144 else { throw UpdateError.invalidResponse }
                data.append(byte)
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard !release.draft, !release.prerelease, let remote = Self.version(release.tag_name),
                  let local = Self.version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0") else {
                throw UpdateError.invalidResponse
            }
            if local.lexicographicallyPrecedes(remote) {
                releaseURL = URL(string: "https://github.com/THE-TOYMAKERS/curve/releases/tag/\(release.tag_name)")
                message = "Curve \(release.tag_name) is available. Review the official release before installing."
            } else { message = "No newer stable release was found (current \(local.map(String.init).joined(separator: ".")))." }
        } catch { message = "The update check could not be verified. Try again later." }
    }
    private enum UpdateError: Error { case invalidResponse }
}
