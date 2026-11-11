import AppKit
import Foundation
import Network
import WebKit
import BrowserCore

private enum FixtureFailure: Error { case server, timeout }

/// An isolated loopback fixture verifies actual requests reaching a server,
/// rather than inferring blocking from a failed image or script alone.
private final class ProtectionFixtureServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Curve.ProtectionFixture")
    private let lock = NSLock()
    private var requests: [String: Int] = [:]
    private var listener: NWListener?
    private var selectedPort: UInt16 = 0
    private var startupFinished = false
    var port: UInt16 { lock.lock(); defer { lock.unlock() }; return selectedPort }

    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue, self.finishStartup(port: port) else { return }
                    continuation.resume()
                case .failed(let error):
                    if self.finishStartup(port: nil) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener?.cancel(); listener = nil }
    private func finishStartup(port: UInt16?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !startupFinished else { return false }
        startupFinished = true
        if let port { selectedPort = port }
        return true
    }
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return requests[path, default: 0] }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            guard bytes.count <= 32_768, error == nil else { connection.cancel(); return }
            guard let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") else {
                if done { connection.cancel() } else { self.receive(connection, accumulated: bytes) }
                return
            }
            let target = text.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = target.components(separatedBy: "?")[0]
            self.lock.lock(); self.requests[path, default: 0] += 1; self.lock.unlock()
            let body: String
            let contentType: String
            if path.hasSuffix("/index") {
                let mode = path.split(separator: "/").first.map(String.init) ?? "control"
                body = """
                <!doctype html><meta charset="utf-8"><title>Protection fixture</title>
                <div id="normal">Allowed content</div><div id="common-slot" data-ad-slot="fixture">Ad slot</div>
                <div id="strict-slot" class="advertisement">Strict cosmetic slot</div>
                <script src="http://127.0.0.1:\(self.port)/\(mode)/blocked.js"></script>
                <script src="/\(mode)/pagead/ad.js"></script><script src="/\(mode)/allowed.js"></script>
                <script>window.fixtureReady=true;</script>
                """
                contentType = "text/html; charset=utf-8"
            } else if path.hasSuffix("blocked.js") { body = "window.blockedScriptRan=true;"; contentType = "application/javascript" }
            else if path.contains("/pagead/") { body = "window.firstPartyAdRan=true;"; contentType = "application/javascript" }
            else { body = "window.allowedScriptRan=true;"; contentType = "application/javascript" }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@main
struct ProtectionChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            fputs("FAIL: protection checks exceeded the 120-second native-helper deadline.\n", stderr)
            exit(1)
        }
        Task { @MainActor in
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("CurveProtectionChecks-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let source = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/Protection", isDirectory: true)
            var failures: [String] = []
            var checks = 0
            func check(_ condition: @autoclosure () -> Bool, _ name: String) {
                checks += 1
                if !condition() { failures.append(name) }
            }
            do {
                check(ProtectionLevel.default == .strict, "strict default")
                check(!ProtectionLevel.off.isEnabled, "off is explicit")
                let filter = try ProtectionRules.urlFilter(for: "tracker.example")
                let regex = try NSRegularExpression(pattern: filter)
                let matching = ["https://tracker.example/x", "http://a.tracker.example:8080/x", "https://user:pass@tracker.example/x", "https://tracker.example./x"]
                for url in matching { check(regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil, "blocks tracker authority: \(url)") }
                for url in ["https://nottracker.example/x", "https://tracker.example.evil.test/x", "https://safe.example/tracker.example/x", "https://safe.example/?next=https://tracker.example/x", "https://tracker.example@safe.example/x", "https://tracker.example:443@safe.example/x"] {
                    check(regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) == nil, "allows unrelated authority: \(url)")
                }
                for domain in ["evil.test/path", "evil.test|.*", ".evil.test", "evil..test", "-evil.test", "evil.test.", "EVIL.test", "bad_thing.test", "192.168.0.999"] { check(!ProtectionRules.isValidDomain(domain), "rejects invalid list domain: \(domain)") }
                do { _ = try ProtectionRules.domains(from: Data("tracker.example\n.*\n".utf8)); failures.append("invalid domain list fails closed") } catch { checks += 1 }
                do { _ = try ProtectionRules.encodedRules(for: .off, domains: ["tracker.example"]); failures.append("disabled list rejected") } catch { checks += 1 }

                let storeURL = scratch.appendingPathComponent("RuleStore", isDirectory: true)
                try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
                guard let store = WKContentRuleListStore(url: storeURL) else { throw ContentProtectionError.unavailableRuleStore }
                let protection = ContentProtection(resourceDirectory: source, ruleStore: store)
                let start = Date()
                print("Compiling verified full strict list…"); fflush(stdout)
                let strict = try await protection.ruleList(for: .strict)
                let elapsed = Date().timeIntervalSince(start)
                let strictAgain = try await protection.ruleList(for: .strict)
                check(strict === strictAgain, "compiled rule cache reused")
                _ = try await protection.ruleList(for: .balanced)
                print("Verified full strict/balanced lists and cache reuse."); fflush(stdout)
                check(ContentProtection.bundledDomainCount == 38_212, "pinned domain inventory")
                let missing = ContentProtection(resourceDirectory: scratch.appendingPathComponent("missing"), ruleStore: store)
                do { _ = try await missing.ruleList(for: .strict); failures.append("missing assets fail closed") } catch { checks += 1 }
                let damaged = scratch.appendingPathComponent("Damaged", isDirectory: true)
                try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
                for name in ["ads.txt", "trackers.txt"] { try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: damaged.appendingPathComponent(name)) }
                try Data("changed.test\n".utf8).write(to: damaged.appendingPathComponent("ads.txt"))
                do { _ = try await ContentProtection(resourceDirectory: damaged, ruleStore: store).ruleList(for: .strict); failures.append("changed assets fail closed even with a cache") } catch { checks += 1 }

                let server = ProtectionFixtureServer()
                print("Starting loopback request-count fixture…"); fflush(stdout)
                try await server.start()
                defer { server.stop() }
                for mode in [ProtectionLevel.off, .balanced, .strict] {
                    print("Loading \(mode.rawValue) fixture…"); fflush(stdout)
                    let config = WKWebViewConfiguration()
                    config.websiteDataStore = .nonPersistent()
                    if mode.isEnabled {
                        let encoded = try ProtectionRules.encodedRules(for: mode, domains: ["127.0.0.1"])
                        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
                            store.compileContentRuleList(forIdentifier: "Fixture-\(mode.rawValue)", encodedContentRuleList: encoded) { rule, error in
                                if let error { continuation.resume(throwing: error) }
                                else if let rule { continuation.resume(returning: rule) }
                                else { continuation.resume(throwing: ContentProtectionError.compilationFailed) }
                            }
                        }
                        config.userContentController.add(list)
                    }
                    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
                    let url = URL(string: "http://localhost:\(server.port)/\(mode.rawValue)/index")!
                    view.load(URLRequest(url: url))
                    var ready = false
                    for _ in 0..<150 {
                        if (try? await view.evaluateJavaScript("window.fixtureReady === true && document.readyState === 'complete'")) as? Bool == true { ready = true; break }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    check(ready, "\(mode.rawValue): fixture completed")
                    check(server.count("/\(mode.rawValue)/allowed.js") == 1, "\(mode.rawValue): allowed request reached server")
                    let allowedScriptRan = (try? await view.evaluateJavaScript("window.allowedScriptRan === true")) as? Bool == true
                    check(allowedScriptRan, "\(mode.rawValue): allowed script executes")
                    check(server.count("/\(mode.rawValue)/blocked.js") == (mode == .off ? 1 : 0), "\(mode.rawValue): tracker request blocked before server")
                    check(server.count("/\(mode.rawValue)/pagead/ad.js") == (mode == .strict ? 0 : 1), "\(mode.rawValue): first-party ad-path policy")
                    let commonHidden = (try? await view.evaluateJavaScript("getComputedStyle(document.getElementById('common-slot')).display === 'none'")) as? Bool == true
                    let strictHidden = (try? await view.evaluateJavaScript("getComputedStyle(document.getElementById('strict-slot')).display === 'none'")) as? Bool == true
                    check(commonHidden == mode.isEnabled, "\(mode.rawValue): common cosmetic rule")
                    check(strictHidden == (mode == .strict), "\(mode.rawValue): strict cosmetic rule")
                    view.stopLoading()
                }
                print("Full bundled strict list first compile/cache check: \(String(format: "%.2f", elapsed)) seconds; \(ContentProtection.bundledDomainCount) domains.")
            } catch { failures.append("Unexpected error: \(error)") }
            print(failures.isEmpty ? "PASS: \(checks) protection checks: authority boundaries, native full-list compilation, cache reuse, fail-closed assets, real loopback ad/tracker requests, allowed scripts, and cosmetic filters" : "FAIL: \(failures.joined(separator: "; "))")
            fflush(stdout)
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }
}
