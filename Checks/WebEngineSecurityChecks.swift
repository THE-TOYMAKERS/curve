import AppKit
import Foundation
import Network
import WebKit
import BrowserCore

private enum EngineSecurityFixtureError: Error { case server, timeout, missingResources }

/// Loopback-only HTTP fixture. Captures what actually reaches the network,
/// including initial request headers; all records contain synthetic test data.
private final class EngineSecurityServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Curve.EngineSecurityFixture")
    private let lock = NSLock()
    private var records: [(path: String, headers: [String: String], uptime: Double)] = []
    private var attemptedReplies: Set<String> = []
    private var listener: NWListener?
    private var selectedPort: UInt16 = 0
    private var startupFinished = false
    var port: UInt16 { lock.lock(); defer { lock.unlock() }; return selectedPort }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
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
                case .cancelled:
                    if self.finishStartup(port: nil) { continuation.resume(throwing: EngineSecurityFixtureError.server) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
            }
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.finishStartup(port: nil) else { return }
                listener.cancel(); continuation.resume(throwing: EngineSecurityFixtureError.timeout)
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
    func count(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return records.filter { $0.path == path }.count
    }
    func header(_ name: String, for path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return records.first { $0.path == path }?.headers[name.lowercased()]
    }
    func replyAttempted(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return attemptedReplies.contains(path)
    }
    func events(since start: Double) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return records.prefix(30).map { String(format: "+%.2fs %@", $0.uptime - start, $0.path) }
    }
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
            let lines = text.components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init)?.components(separatedBy: "?")[0] ?? "/"
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if line.isEmpty { break }
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
            }
            self.lock.lock()
            if self.records.count < 2_000 { self.records.append((path, headers, ProcessInfo.processInfo.systemUptime)) }
            self.lock.unlock()
            let body: String
            let contentType: String
            if path == "/heartbeat" || path.hasPrefix("/slow-cookie-") {
                body = "ok"; contentType = "text/plain"
            } else {
                body = """
                <!doctype html><meta charset="utf-8"><title>Curve engine security \(path)</title>
                <p id="allowed">Synthetic local engine check</p>
                <script>
                  window.pageScriptRan = true;
                  window.pageSawGPC = navigator.globalPrivacyControl === true;
                  if (location.pathname === '/gpc') {
                    fetch('/slow-cookie-live', {cache:'no-store'}).catch(() => {});
                  }
                  if (location.pathname === '/retirement') {
                    fetch('/slow-cookie-retired', {cache:'no-store'}).catch(() => {});
                    window.heartbeat = setInterval(() => {
                      document.cookie = 'CurveSecurityZombie=1; SameSite=Lax; Path=/';
                      fetch('/heartbeat', {cache:'no-store'}).catch(() => {});
                    }, 30);
                  }
                </script>
                """
                contentType = "text/html; charset=utf-8"
            }
            let cookieHeader = path.hasPrefix("/slow-cookie-") ? "Set-Cookie: \(path == "/slow-cookie-live" ? "CurveSecurityLiveCookie" : "CurveSecurityLateCookie")=1; SameSite=Lax; Path=/\r\n" : ""
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\n\(cookieHeader)Connection: close\r\n\r\n\(body)"
            if path.hasPrefix("/slow-cookie-") {
                // The response arrives after the native clear-data path should
                // have retired the requesting document and cleared its store.
                self.queue.asyncAfter(deadline: .now() + 1) {
                    self.lock.lock(); self.attemptedReplies.insert(path); self.lock.unlock()
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else { connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() }) }
        }
    }
}

@main
@MainActor
struct WebEngineSecurityChecks {
    private static var assertions = 0
    private static var failures: [String] = []
    private static var engines: [WebEngine] = []
    private static var suites: [String] = []

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures.append(message); print("FAIL: \(message)") }
    }
    private static func settings(noScript: Bool = false) -> PrivacySettings {
        let suite = "CurveEngineSecurityChecks." + UUID().uuidString
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(noScript, forKey: "privacy.blockJavaScript")
        return PrivacySettings(defaults: defaults)
    }
    private static func wait(seconds: Double = 15, until predicate: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return predicate()
    }
    private static func engine(protection: ContentProtection, noScript: Bool = false,
                               data: WKWebsiteDataStore? = nil) -> WebEngine {
        let engine = WebEngine(isPrivate: true, websiteDataStore: data ?? .nonPersistent(),
                               privacySettings: settings(noScript: noScript), contentProtection: protection)
        engines.append(engine)
        return engine
    }
    private static func waitForCookie(_ name: String, in data: WKWebsiteDataStore) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            if await data.httpCookieStore.allCookies().contains(where: { $0.name == name }) { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private static func run(resources: URL, scratch: URL, server: EngineSecurityServer) async throws {
        let ruleDirectory = scratch.appendingPathComponent("Rules", isDirectory: true)
        try FileManager.default.createDirectory(at: ruleDirectory, withIntermediateDirectories: true)
        guard let ruleStore = WKContentRuleListStore(url: ruleDirectory) else { throw EngineSecurityFixtureError.server }
        let protection = ContentProtection(resourceDirectory: resources, ruleStore: ruleStore)
        func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(server.port)\(path)")! }

        let normal = engine(protection: protection)
        let normalID = UUID()
        let initialStart = ProcessInfo.processInfo.systemUptime
        let normalView = normal.webView(for: normalID, url: url("/gpc"))
        func initialDiagnostics(_ stage: String) {
            let state = normal.state(id: normalID)
            let report: [String: Any] = [
                "stage": stage, "elapsed": ProcessInfo.processInfo.systemUptime - initialStart,
                "protectionReady": state.protectionReady, "engineLoading": state.isLoading,
                "webViewLoading": normalView.isLoading, "title": normalView.title ?? "nil",
                "webViewURL": normalView.url?.absoluteString ?? "nil", "engineURL": state.url,
                "error": state.error ?? "none", "requests": server.events(since: initialStart)
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print("ENGINE_INITIAL_DIAGNOSTIC \(text)"); fflush(stdout) }
        }
        check(!normalView.isInspectable, "release web views do not enable Safari inspection")
        check(normalView.configuration.preferences.isFraudulentWebsiteWarningEnabled, "WebKit fraudulent-website warnings explicitly enabled")
        check(!normalView.configuration.preferences.javaScriptCanOpenWindowsAutomatically, "unsolicited script windows disabled")
        check(normalView.configuration.upgradeKnownHostsToHTTPS, "WebKit known-host HTTPS upgrade enabled")
        check(!normalView.configuration.websiteDataStore.isPersistent, "injected engine has no production website store")
        initialDiagnostics("first-load-start")
        var lastDiagnostic = initialStart
        let loaded = await wait(seconds: 45) {
            if ProcessInfo.processInfo.systemUptime - lastDiagnostic >= 5 {
                lastDiagnostic = ProcessInfo.processInfo.systemUptime; initialDiagnostics("first-load-wait")
            }
            return normalView.title == "Curve engine security /gpc" && !normalView.isLoading && normal.state(id: normalID).protectionReady
        }
        initialDiagnostics(loaded ? "first-load-finished" : "first-load-timeout")
        check(loaded, "integrated engine loads only after verified rules are ready")
        check(server.count("/gpc") == 1, "one real first document request reaches localhost")
        check(server.header("sec-gpc", for: "/gpc") == "1", "initial native request sends actual Sec-GPC header")
        let gpc = try? await normalView.evaluateJavaScript("navigator.globalPrivacyControl === true && window.pageSawGPC === true")
        check(gpc as? Bool == true, "page and native inspection observe the GPC JavaScript signal")
        let ordinaryScript = try? await normalView.evaluateJavaScript("window.pageScriptRan === true")
        check(ordinaryScript as? Bool == true, "ordinary page JavaScript works when NoScript is off")
        let liveCookieRequest = await wait { server.count("/slow-cookie-live") == 1 }
        check(liveCookieRequest, "control page creates a real delayed cookie response")
        let liveCookieReceived = await waitForCookie("CurveSecurityLiveCookie", in: normalView.configuration.websiteDataStore)
        check(liveCookieReceived, "delayed Set-Cookie works while its document is active")

        let noScript = engine(protection: protection, noScript: true)
        let noScriptID = UUID()
        let noScriptView = noScript.webView(for: noScriptID, url: url("/noscript"))
        check(!noScriptView.configuration.defaultWebpagePreferences.allowsContentJavaScript, "NoScript config disables website JavaScript")
        let noScriptLoaded = await wait { noScriptView.title == "Curve engine security /noscript" && !noScriptView.isLoading && noScript.state(id: noScriptID).protectionReady }
        check(noScriptLoaded, "NoScript still renders real HTML")
        let pageScriptBlocked = try? await noScriptView.evaluateJavaScript("typeof window.pageScriptRan === 'undefined'")
        check(pageScriptBlocked as? Bool == true, "website inline script never executed in NoScript mode")
        let nativeScript = try? await noScriptView.evaluateJavaScript("window.nativeFromTest = 42; window.nativeFromTest")
        check(nativeScript as? Int == 42, "native controlled JavaScript evaluation remains available")

        let missingProtection = ContentProtection(resourceDirectory: scratch.appendingPathComponent("MissingLists"), ruleStore: ruleStore)
        let missing = engine(protection: missingProtection)
        let missingID = UUID()
        let missingView = missing.webView(for: missingID, url: url("/must-not-load"))
        let explicitError = await wait(seconds: 5) { missing.state(id: missingID).error != nil }
        check(explicitError, "missing lists produce an explicit engine protection error")
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(server.count("/must-not-load") == 0, "missing lists cause zero actual document requests")
        check(missingView.url == nil && !missing.state(id: missingID).protectionReady, "missing rules never create an unprotected document")

        let closing = engine(protection: protection)
        let closingID = UUID()
        let retainedClosingView = closing.webView(for: closingID, url: url("/closed-before-first-load"))
        closing.close(id: closingID)
        try await WebDocumentRetirement.waitForAll()
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(server.count("/closed-before-first-load") == 0, "closing a pending initial load cancels its real request")
        check(closing.liveCount == 0 && retainedClosingView.url?.absoluteString == "about:blank", "retained closed view is inert and cannot recreate a session")

        let retiringData = WKWebsiteDataStore.nonPersistent()
        let retiring = engine(protection: protection, data: retiringData)
        let retiringID = UUID()
        let retainedView = retiring.webView(for: retiringID, url: url("/retirement"))
        let heartbeatStarted = await wait { server.count("/heartbeat") >= 2 }
        check(heartbeatStarted, "synthetic loaded page really runs background cookie/network activity")
        check(server.count("/slow-cookie-retired") == 1, "document has an outstanding delayed Set-Cookie response before retirement")
        retiring.beginPrivacyReset()
        try await WebDocumentRetirement.waitForAll()
        await retiring.eraseWebsiteData()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let afterRetirement = server.count("/heartbeat")
        try? await Task.sleep(nanoseconds: 350_000_000)
        check(server.count("/heartbeat") == afterRetirement, "retained view does not resume network activity after retirement")
        let cookies = await retiringData.httpCookieStore.allCookies()
        check(!cookies.contains { $0.name == "CurveSecurityZombie" }, "retired document cannot repopulate cookies after data erasure")
        let lateReplyAttempted = await wait(seconds: 5) { server.replyAttempted("/slow-cookie-retired") }
        check(lateReplyAttempted, "fixture attempts the delayed response after retirement")
        try? await Task.sleep(nanoseconds: 250_000_000)
        let lateCookies = await retiringData.httpCookieStore.allCookies()
        check(!lateCookies.contains { $0.name == "CurveSecurityLateCookie" }, "late network response cannot restore a cookie after its document was retired and erased")
        check(retainedView.url?.absoluteString == "about:blank", "retirement reached a native-confirmed inert document")
        _ = retiring.webView(for: UUID(), url: url("/reset-must-not-load"))
        retiring.load(id: retiringID, url: url("/reset-must-not-load"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(server.count("/reset-must-not-load") == 0 && retiring.liveCount == 0, "erasure guard blocks new engine documents and requests")
        retiring.endPrivacyReset()
        initialDiagnostics("suite-finished")
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            fputs("FAIL: integrated engine security checks exceeded the 120-second deadline.\n", stderr)
            exit(1)
        }
        Task { @MainActor in
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("CurveEngineSecurityChecks-\(UUID().uuidString)", isDirectory: true)
            let server = EngineSecurityServer()
            do {
                guard CommandLine.arguments.count > 1 else { throw EngineSecurityFixtureError.missingResources }
                let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                try await server.start()
                try await run(resources: resources, scratch: scratch, server: server)
            } catch { failures.append("fixture/runtime error: \(error)"); print("FAIL: \(error)") }
            for engine in engines { engine.shutdown() }
            try? await WebDocumentRetirement.waitForAll()
            server.stop()
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            try? FileManager.default.removeItem(at: scratch)
            if failures.isEmpty { print("PASS: \(assertions) integrated WebEngine security checks") }
            else { print("FAIL: \(failures.count) / \(assertions) integrated WebEngine security checks") }
            fflush(stdout)
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }
}
