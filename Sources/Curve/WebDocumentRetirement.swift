import Foundation
@preconcurrency import WebKit

/// Retire loaded scripts even when a stale SwiftUI host retains the web view.
/// Only native completion of our inert replacement navigation releases the
/// erasure barrier; ordinary website JavaScript cannot forge its identity.
@MainActor
final class WebDocumentRetirement: NSObject, WKNavigationDelegate {
    private static var pending: [ObjectIdentifier: WebDocumentRetirement] = [:]
    private weak var originalView: WKWebView?
    private var retainedView: WKWebView?
    private var navigation: WKNavigation?
    private var result: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var timeout: Task<Void, Never>?

    static func retire(_ view: WKWebView) {
        let key = ObjectIdentifier(view)
        if let old = pending[key], old.result == nil { return }
        let retirement = WebDocumentRetirement()
        retirement.originalView = view; retirement.retainedView = view
        pending[key] = retirement
        view.stopLoading()
        view.uiDelegate = nil
        view.configuration.userContentController.removeAllUserScripts()
        view.navigationDelegate = retirement
        retirement.navigation = view.loadHTMLString("<!doctype html><meta charset='utf-8'><title></title>", baseURL: nil)
        retirement.timeout = Task { @MainActor [weak retirement] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            retirement?.finish(.failure(RetirementError.couldNotStopDocument))
        }
    }

    static func waitForAll() async throws {
        while !pending.isEmpty {
            for entry in Array(pending.values) {
                guard let view = entry.originalView else { remove(entry); continue }
                if case .failure? = entry.result { retire(view); continue }
                try await entry.wait()
            }
        }
    }

    private static func remove(_ entry: WebDocumentRetirement) {
        guard let view = entry.originalView else { pending = pending.filter { $0.value !== entry }; return }
        let key = ObjectIdentifier(view)
        if pending[key] === entry { pending.removeValue(forKey: key) }
    }
    private func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    private func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        timeout?.cancel(); timeout = nil
        retainedView?.navigationDelegate = nil
        retainedView = nil
        let completions = waiters; waiters.removeAll()
        if case .success = result { Self.remove(self) }
        for completion in completions { completion.resume(with: result) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation, webView.url?.absoluteString == "about:blank" else { return }
        finish(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === self.navigation { finish(.failure(RetirementError.couldNotStopDocument)) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === self.navigation { finish(.failure(RetirementError.couldNotStopDocument)) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.success(())) }
    private enum RetirementError: Error, LocalizedError {
        case couldNotStopDocument
        var errorDescription: String? { "A previously loaded document could not be stopped. Website data clearing was not completed; close Curve and retry." }
    }
}
