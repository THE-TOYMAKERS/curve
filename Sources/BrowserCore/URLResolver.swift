import Foundation

public enum URLResolver {
    public static func resolve(_ input: String, searchEngine: String = "duckduckgo") -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value == "curve://start" || value == "aperture://start" { return URL(string: "curve://start") }
        if value.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil {
            guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            return url
        }
        if value.range(of: #"^(?i:javascript|data|file|about|vbscript|curve|aperture):"#, options: .regularExpression) != nil { return nil }
        if !value.contains(where: \.isWhitespace) {
            let host = value.components(separatedBy: "/")[0]
            let isLocal = host == "localhost" || host.hasPrefix("localhost:") || host.hasPrefix("127.0.0.1") || host.hasPrefix("[::1]")
            if isLocal || host.contains(".") || host.contains(":") {
                if let url = URL(string: (isLocal ? "http://" : "https://") + value), url.host != nil { return url }
            }
        }
        var components = URLComponents(string: searchEngine == "google" ? "https://www.google.com/search" : "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: value)]
        return components.url
    }
}
