import Foundation
import Darwin

/// Presentation and navigation decisions must use the parsed URL's host, never
/// a page title, user-info prefix, or a substring match against a brand name.
public enum URLSecurity {
    /// Foundation's URL host is ASCII/IDNA encoded. URLComponents.host may instead
    /// decode it to Unicode, which can make look-alike domains difficult to spot.
    public static func asciiHost(for url: URL) -> String? {
        guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host.removeFirst(); host.removeLast() }
        guard host.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }),
              !host.contains(where: { "%/@\\?#".contains($0) }) else { return nil }
        return host
    }

    /// Retains every DNS label, including every `www` label. Only a default port
    /// may be omitted; a nondefault port is part of the displayed destination.
    public static func displayHost(for url: URL) -> String {
        guard let host = asciiHost(for: url) else { return "Invalid address" }
        var displayed = host.contains(":") ? "[\(host)]" : host
        if let port = url.port,
           !((url.scheme?.lowercased() == "https" && port == 443) ||
             (url.scheme?.lowercased() == "http" && port == 80)) {
            displayed += ":\(port)"
        }
        return displayed
    }

    public static func displayOrigin(for url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              asciiHost(for: url) != nil else { return "Invalid address" }
        return "\(scheme)://\(displayHost(for: url))"
    }

    /// Accepts the exact DNS domain or one of its subdomains, with a label
    /// boundary. `notapple.com` and `apple.com.attacker.example` do not match.
    public static func isHost(_ host: String, inDomain domain: String) -> Bool {
        func normalized(_ input: String) -> String? {
            var value = input.lowercased()
            if value.hasSuffix(".") { value.removeLast() }
            guard !value.isEmpty,
                  value.utf8.allSatisfy({ (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) || $0 == 45 || $0 == 46 }),
                  value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return nil }
            return value
        }
        guard let host = normalized(host), let domain = normalized(domain) else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    /// Only explicit loopback destinations keep HTTP for local development.
    /// LAN names, private network addresses, and `localhost.attacker.example`
    /// are not automatically granted an insecure-transport exception.
    public static func isLoopback(_ url: URL) -> Bool {
        guard var host = asciiHost(for: url) else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4,
           parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && ($0.count == 1 || !$0.hasPrefix("0")) && (Int($0).map { (0...255).contains($0) } ?? false) }),
           parts.first == "127" { return true }
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        let ipv6Loopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
        let mappedLoopback = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff && bytes[12] == 127
        return ipv6Loopback || mappedLoopback
    }

    /// HTTPS-only navigation: no automatic HTTP retry if TLS fails. Callers
    /// display the resulting load failure rather than silently weakening TLS.
    public static func httpsUpgraded(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http", !isLoopback(url),
              asciiHost(for: url) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return components.url ?? url
    }
}
