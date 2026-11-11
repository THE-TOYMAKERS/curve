import Foundation

@main
enum URLSecurityChecks {
    static func main() {
        var checks = 0
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        func url(_ text: String) -> URL { URL(string: text)! }

        expect(URLSecurity.displayHost(for: url("https://bank.www.example")) == "bank.www.example", "interior www label must survive")
        expect(URLSecurity.displayHost(for: url("https://www.bank.example")) == "www.bank.example", "leading www label must survive")
        expect(URLSecurity.displayHost(for: url("https://www.www.bank.example")) == "www.www.bank.example", "repeated labels must survive")
        expect(URLSecurity.displayOrigin(for: url("https://bank.example@evil.example/path")) == "https://evil.example", "user info cannot impersonate origin")
        expect(URLSecurity.displayOrigin(for: url("https://example.com:8443/path?token=secret#fragment")) == "https://example.com:8443", "origin preserves port but excludes sensitive path/query")
        expect(URLSecurity.displayOrigin(for: url("http://example.com:80/path")) == "http://example.com", "origin identifies HTTP")
        expect(URLSecurity.displayOrigin(for: url("https://example.com:443/path")) == "https://example.com", "canonical HTTPS port")
        expect(URLSecurity.displayHost(for: url("https://例え.テスト/path")) == "xn--r8jz45g.xn--zckzah", "IDN is displayed in ASCII")
        expect(URLSecurity.asciiHost(for: url("https://аррӏе.com"))?.hasPrefix("xn--") == true, "homograph stays visibly punycode")
        expect(!URLSecurity.isHost(URLSecurity.asciiHost(for: url("https://аррӏе.com"))!, inDomain: "apple.com"), "homograph cannot receive Apple icon")
        expect(URLSecurity.isHost("www.apple.com", inDomain: "apple.com"), "real Apple subdomain")
        expect(URLSecurity.isHost("APPLE.COM.", inDomain: "apple.com"), "DNS case/trailing root dot")
        for host in ["notapple.com", "apple.com.evil.example", "apple-example.com", "apple.com@evil.example", "apple..com", "apple.com..", "apple.com/"] {
            expect(!URLSecurity.isHost(host, inDomain: "apple.com"), "look-alike host rejected: \(host)")
        }
        for text in ["http://localhost:8080", "http://localhost.:8080", "http://test.localhost", "http://127.0.0.1:8080", "http://127.31.2.3", "http://[::1]:8080", "http://[0:0:0:0:0:0:0:1]", "http://[::ffff:127.0.0.1]"] {
            expect(URLSecurity.isLoopback(url(text)), "explicit loopback recognized: \(text)")
            expect(URLSecurity.httpsUpgraded(url(text)) == url(text), "local HTTP preserved: \(text)")
        }
        for text in ["http://localhost.evil.example", "http://127.0.0.1.evil.example", "http://192.168.1.1", "http://example.com", "http://[::2]", "http://[::ffff:192.168.1.1]"] {
            expect(!URLSecurity.isLoopback(url(text)), "nonloopback has no transport exception: \(text)")
            expect(URLSecurity.httpsUpgraded(url(text)).scheme == "https", "HTTP upgraded: \(text)")
        }
        expect(URLSecurity.httpsUpgraded(url("http://example.com:80/path?q=1#f")).absoluteString == "https://example.com/path?q=1#f", "upgrade retains path/query/fragment and maps default port")
        expect(URLSecurity.httpsUpgraded(url("http://example.com:8080/path")).port == 8080, "nondefault port retained")
        expect(URLSecurity.displayHost(for: url("http://[::1]:8080")) == "[::1]:8080", "IPv6 display is unambiguous")
        expect(URLSecurity.displayOrigin(for: url("file:///etc/passwd")) == "Invalid address", "local files are not displayed as website origins")

        if failures.isEmpty { print("PASS: \(checks) URL security checks") }
        else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }
}
