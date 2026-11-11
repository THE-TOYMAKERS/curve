import Foundation

/// A browser policy, not a count of observed blocked requests.
public enum ProtectionLevel: String, Codable, CaseIterable, Sendable {
    case strict, balanced, off

    public static let `default`: ProtectionLevel = .strict
    public var title: String {
        switch self {
        case .strict: return "Strict"
        case .balanced: return "Balanced"
        case .off: return "Off"
        }
    }
    public var isEnabled: Bool { self != .off }
}

public enum ProtectionRuleError: Error, LocalizedError {
    case invalidDomainList
    case invalidDomain(String)
    case protectionDisabled

    public var errorDescription: String? {
        switch self {
        case .invalidDomainList: return "The bundled protection list is invalid. This page has not been loaded."
        case .invalidDomain: return "The bundled protection list contains an invalid domain. This page has not been loaded."
        case .protectionDisabled: return "Protection is disabled for this page."
        }
    }
}

/// Declarative WebKit rules run before network requests; page scripts cannot
/// replace them. The runtime must await successful compilation before loading.
public enum ProtectionRules {
    public static let formatVersion = 2
    public static let maximumDomains = 60_000

    public static func domains(from data: Data) throws -> [String] {
        guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8) else {
            throw ProtectionRuleError.invalidDomainList
        }
        var result = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let domain = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if domain.isEmpty || domain.hasPrefix("#") { continue }
            guard isValidDomain(domain) else { throw ProtectionRuleError.invalidDomain(domain) }
            result.insert(domain)
            guard result.count <= maximumDomains else { throw ProtectionRuleError.invalidDomainList }
        }
        guard !result.isEmpty else { throw ProtectionRuleError.invalidDomainList }
        return result.sorted()
    }

    public static func isValidDomain(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.utf8.count <= 253,
              domain.utf8.allSatisfy({ $0 < 128 }), domain == domain.lowercased() else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        // Hosts lists may also contain canonical IPv4 literals. Supporting
        // those permits entirely local, real-network regression fixtures.
        if labels.count == 4, labels.allSatisfy({ part in
            guard let value = UInt8(part) else { return false }
            return String(value) == part
        }) { return true }
        guard labels.count >= 2, let last = labels.last, Int(last) == nil else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
        }
    }

    /// Match the authority, including subdomains and optional URL credentials,
    /// never a matching string in a path, query, or unrelated hostname suffix.
    public static func urlFilter(for domain: String) throws -> String {
        guard isValidDomain(domain) else { throw ProtectionRuleError.invalidDomain(domain) }
        // Canonical HTTP/WebSocket URLs have a slash after their authority.
        // Requiring a complete numeric port prevents mistaking credentials
        // such as `tracker.example:443@safe.example` for the destination host.
        return "^[^:]+://+([^/]*@)?([^:/]+\\.)?" + domain.replacingOccurrences(of: ".", with: "\\.") + "\\.?(:[0-9]+)?/"
    }

    public static func encodedRules(for level: ProtectionLevel, domains: [String]) throws -> String {
        guard level.isEnabled else { throw ProtectionRuleError.protectionDisabled }
        let unique = Set(domains)
        guard !unique.isEmpty, unique.count <= maximumDomains else { throw ProtectionRuleError.invalidDomainList }
        var rules: [[String: Any]] = []
        rules.reserveCapacity(unique.count + 20)
        for domain in unique.sorted() {
            var trigger: [String: Any] = ["url-filter": try urlFilter(for: domain), "url-filter-is-case-sensitive": true]
            if level == .balanced { trigger["load-type"] = ["third-party"] }
            rules.append(["trigger": trigger, "action": ["type": "block"]])
        }
        if level == .strict {
            // First-party ad delivery paths need explicit matching. Never block
            // a full document solely because its article path mentions ads.
            for path in ["pagead", "gampad", "adsbygoogle", "adservice", "adserver", "prebid"] {
                rules.append([
                    "trigger": ["url-filter": "^[^:]+://[^/]+/([^?]*/)?" + path + "[/?._-]",
                                "resource-type": ["image", "script", "raw", "media", "style-sheet"]],
                    "action": ["type": "block"]
                ])
            }
            rules.append(["trigger": ["url-filter": ".*", "load-type": ["third-party"]], "action": ["type": "block-cookies"]])
        }
        let commonSelectors = ["ins.adsbygoogle", "[data-ad-client]", "[data-ad-slot]", "[id^='google_ads_iframe']", "[id^='div-gpt-ad']"]
        let strictSelectors = [".advertisement", ".advertisement-container", ".ad-banner", ".ad-slot", "[data-testid='ad-container']", "[aria-label='Advertisement']", "ytd-ad-slot-renderer", "ytd-display-ad-renderer", "ytd-promoted-sparkles-web-renderer", "ytd-in-feed-ad-layout-renderer", "ytd-banner-promo-renderer", ".ytp-ad-overlay-container"]
        rules.append(["trigger": ["url-filter": ".*"],
                      "action": ["type": "css-display-none", "selector": (commonSelectors + (level == .strict ? strictSelectors : [])).joined(separator: ",")]])
        let encoded = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        guard let string = String(data: encoded, encoding: .utf8) else { throw ProtectionRuleError.invalidDomainList }
        return string
    }
}
