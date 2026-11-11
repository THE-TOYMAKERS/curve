import AppKit
import SwiftUI
import Combine
import BrowserCore
import CoreServices
@preconcurrency import WebKit

struct WebPageState {
    var url = ""
    var title = ""
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    var error: String?
    var isSuspended = false
    var isSecure = false
    var protectionReady = false
}

struct BrowserDownload: Identifiable {
    let id: UUID
    var name: String
    var url: URL?
    var progress: Double = 0
    var status: String = "Waiting…"
    var isComplete = false
}

/// Native WebKit sessions are created only when a tab is visited. Inactive, clean
/// sessions are discarded by least recent use. The OS supplies the rendering engine.
@MainActor
final class WebEngine: NSObject, ObservableObject {
    @Published var revision = 0
    @Published var downloads: [BrowserDownload] = []
    @Published var peekURL: URL?
    let isPrivate: Bool
    private let websiteDataStore: WKWebsiteDataStore
    private let privacySettings: PrivacySettings
    private let contentProtection: ContentProtection

    init(isPrivate: Bool = false, websiteDataStore overrideStore: WKWebsiteDataStore? = nil,
         privacySettings: PrivacySettings? = nil, contentProtection: ContentProtection? = nil) {
        self.isPrivate = isPrivate
        self.privacySettings = privacySettings ?? .shared
        self.contentProtection = contentProtection ?? .shared
        websiteDataStore = overrideStore ?? (isPrivate ? .nonPersistent() : .default())
        super.init()
        privacyObserver = NotificationCenter.default.addObserver(forName: PrivacySettings.didChange, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["reloadPages"] as? Bool == true else { return }
            Task { @MainActor [weak self] in
                guard let self, note.object as AnyObject? === self.privacySettings else { return }
                self.resetForPrivacyChange()
            }
        }
    }
    var onPageChanged: ((UUID, String, String) -> Void)?
    var onOpenTab: ((URL) -> Void)?
    var onPeek: ((URL) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onError: ((UUID, String) -> Void)?
    var onFindResult: ((Bool) -> Void)?
    var onUserNavigation: (() -> Void)?
    /// Called only for a user-activated main-frame link, never a redirect.
    var shouldPeekNavigation: ((UUID, URL, URL?) -> Bool)?

    private final class Session {
        let view: WKWebView
        var observations: [NSKeyValueObservation] = []
        var lastUsed = Date()
        var dirty = false
        var playingMedia = false
        var crashReloads = 0
        var requestedURL: URL?
        var protectionTask: Task<Void, Never>?
        var protectionReady = false
        var installedRules: WKContentRuleList?
        var preparing = false
        var loadGeneration: UInt64 = 0
        init(_ view: WKWebView) { self.view = view }
    }
    private var sessions: [UUID: Session] = [:]
    private var snapshots: [UUID: WebPageState] = [:]
    private var visibleIDs: Set<UUID> = []
    private var liveLimit = 6
    private static let interactionWorld = WKContentWorld.world(name: "CurveInteractions")
    private var downloadTasks: [UUID: WKDownload] = [:]
    private var downloadIDs: [ObjectIdentifier: UUID] = [:]
    private var downloadObservations: [UUID: NSKeyValueObservation] = [:]
    private var evictionTask: Task<Void, Never>?
    private var didShutdown = false
    private var retiredView: WKWebView?
    private var privacyObserver: NSObjectProtocol?
    private var privacyResetInProgress = false
    var liveCount: Int { sessions.count }

    func webView(for id: UUID, url: URL) -> WKWebView {
        if didShutdown || privacyResetInProgress {
            if let retiredView { return retiredView }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: .zero, configuration: configuration)
            retiredView = view
            return view
        }
        if let session = sessions[id] {
            session.lastUsed = Date()
            return session.view
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = websiteDataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = !privacySettings.blockJavaScript
        config.upgradeKnownHostsToHTTPS = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        let controller = WKUserContentController()
        controller.add(WeakScriptHandler(self), contentWorld: Self.interactionWorld, name: "curve")
        controller.addUserScript(WKUserScript(source: Self.interactionScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: Self.interactionWorld))
        if privacySettings.sendGlobalPrivacyControl {
            controller.addUserScript(WKUserScript(source: Self.globalPrivacyControlScript, injectionTime: .atDocumentStart,
                                                 forMainFrameOnly: false, in: .page))
        }
        config.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.isInspectable = false
        view.autoresizingMask = [.width, .height]
        let session = Session(view)
        session.requestedURL = url
        sessions[id] = session
        let update: @Sendable (WKWebView, NSKeyValueObservedChange<String?>) -> Void = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.publish(id) }
        }
        session.observations.append(view.observe(\.title, options: [.new], changeHandler: update))
        session.observations.append(view.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.publish(id) }
        })
        session.observations.append(view.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.publish(id) }
        })
        session.observations.append(view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.publish(id) }
        })
        session.observations.append(view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.publish(id) }
        })
        session.observations.append(view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.publish(id) }
        })
        session.observations.append(view.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.publish(id) }
        })
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            scheduleLoad(id: id, session: session, url: url)
        }
        return view
    }

    func state(id: UUID) -> WebPageState {
        if let session = sessions[id] {
            let view = session.view
            return WebPageState(url: view.url?.absoluteString ?? session.requestedURL?.absoluteString ?? snapshots[id]?.url ?? "",
                                title: view.title ?? snapshots[id]?.title ?? "",
                                isLoading: view.isLoading || session.preparing, progress: view.estimatedProgress,
                                canGoBack: view.canGoBack, canGoForward: view.canGoForward,
                                error: snapshots[id]?.error, isSuspended: false,
                                isSecure: view.url?.scheme?.lowercased() == "https" && view.hasOnlySecureContent && !view.isLoading && !session.preparing && snapshots[id]?.error == nil,
                                protectionReady: session.protectionReady)
        }
        return snapshots[id] ?? WebPageState(isSuspended: true)
    }

    func activate(ids: Set<UUID>, limit: Int) {
        guard !didShutdown else { return }
        visibleIDs = ids
        liveLimit = max(2, limit)
        for id in ids { sessions[id]?.lastUsed = Date() }
        evictionTask?.cancel()
        evictionTask = Task { @MainActor [weak self] in
            // Let selection settle before removing any previous session.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.evictInactive()
        }
    }

    /// Tabs with unsaved form edits, active media, or capture must survive both
    /// idle archiving and memory eviction. Native media state includes WebAudio
    /// and cross-origin frames, which the DOM event bridge cannot fully observe.
    func protectedTabIDs() async -> Set<UUID> {
        var protected: Set<UUID> = []
        for (id, session) in sessions {
            if session.dirty || session.view.cameraCaptureState != .none ||
                session.view.microphoneCaptureState != .none {
                protected.insert(id)
                continue
            }
            let playback = await withCheckedContinuation { continuation in
                session.view.requestMediaPlaybackState { continuation.resume(returning: $0) }
            }
            if sessions[id] === session, playback == .playing { protected.insert(id) }
        }
        return protected
    }

    func close(id: UUID) {
        if let view = sessions[id]?.view { cancelWebsiteUIRequests(for: view) }
        sessions[id]?.protectionTask?.cancel()
        sessions[id]?.view.stopLoading()
        sessions[id]?.view.navigationDelegate = nil
        sessions[id]?.view.uiDelegate = nil
        sessions[id]?.view.configuration.userContentController.removeScriptMessageHandler(forName: "curve", contentWorld: Self.interactionWorld)
        if let view = sessions[id]?.view { WebDocumentRetirement.retire(view) }
        sessions[id]?.view.removeFromSuperview()
        sessions.removeValue(forKey: id)
        snapshots.removeValue(forKey: id)
        revision &+= 1
    }

    /// Called as a browser window closes, especially before releasing a private
    /// store. No rendering process or in-flight download should outlive the window.
    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        evictionTask?.cancel()
        evictionTask = nil
        visibleIDs.removeAll()
        for id in Array(sessions.keys) { close(id: id) }
        for id in Array(downloadTasks.keys) { cancelDownload(id) }
        downloads.removeAll()
        snapshots.removeAll()
        peekURL = nil
        if isPrivate {
            let store = websiteDataStore
            let settings = privacySettings
            Task { @MainActor in
                do { try await WebDocumentRetirement.waitForAll() }
                catch { settings.cleanupWarning = "A private page could not be stopped. Quit Curve to finish closing its private processes." }
                await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            }
        }
        if let privacyObserver { NotificationCenter.default.removeObserver(privacyObserver); self.privacyObserver = nil }
    }

    func load(id: UUID, url: URL) {
        guard !didShutdown, !privacyResetInProgress else { return }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        snapshots[id]?.error = nil
        if let session = sessions[id] {
            scheduleLoad(id: id, session: session, url: url)
        } else {
            _ = webView(for: id, url: url)
        }
        sessions[id]?.dirty = false
        sessions[id]?.crashReloads = 0
    }
    func openHTML(id: UUID, html: String, baseURL: URL? = nil) {
        guard !didShutdown, !privacyResetInProgress else { return }
        _ = webView(for: id, url: URL(string: "about:blank")!)
        guard let session = sessions[id] else { return }
        prepareProtection(id: id, session: session) { view in view.loadHTMLString(html, baseURL: baseURL) }
    }
    func goBack(_ id: UUID) { sessions[id]?.view.goBack() }
    func goForward(_ id: UUID) { sessions[id]?.view.goForward() }
    func reload(_ id: UUID) {
        snapshots[id]?.error = nil
        sessions[id]?.dirty = false
        sessions[id]?.crashReloads = 0
        if let session = sessions[id] {
            if session.view.url == nil, let url = session.requestedURL,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                scheduleLoad(id: id, session: session, url: url)
            } else { session.view.reload() }
        }
    }
    func stop(_ id: UUID) { sessions[id]?.view.stopLoading() }

    /// Every real document, including test HTML with remote subresources, waits
    /// for verified native content rules. There is no unfiltered startup window.
    private func prepareProtection(id: UUID, session: Session, load: @escaping (WKWebView) -> Void) {
        session.protectionTask?.cancel()
        session.loadGeneration &+= 1
        let generation = session.loadGeneration
        session.preparing = true
        let level: ProtectionLevel = privacySettings.protectionLevel == .balanced ? .balanced : .strict
        session.protectionTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let rules = try await self.contentProtection.ruleList(for: level)
                guard !Task.isCancelled, !self.didShutdown, !self.privacyResetInProgress,
                      self.sessions[id] === session, session.loadGeneration == generation else { return }
                let controller = session.view.configuration.userContentController
                if session.installedRules?.identifier != rules.identifier {
                    controller.add(rules)
                    if let old = session.installedRules { controller.remove(old) }
                    session.installedRules = rules
                }
                session.protectionReady = true
                session.preparing = false
                if var state = self.snapshots[id] { state.error = nil; self.snapshots[id] = state }
                load(session.view)
                self.publish(id)
            } catch {
                guard !Task.isCancelled, self.sessions[id] === session, session.loadGeneration == generation else { return }
                session.preparing = false
                session.protectionReady = false
                var state = self.snapshots[id] ?? WebPageState(url: session.requestedURL?.absoluteString ?? "")
                state.error = "Protection could not start. No webpage was loaded. \(error.localizedDescription)"
                state.isLoading = false
                self.snapshots[id] = state
                self.onError?(id, state.error!)
                self.revision &+= 1
            }
        }
    }

    private func scheduleLoad(id: UUID, session: Session, url: URL) {
        let destination = privacySettings.httpsOnly ? URLSecurity.httpsUpgraded(url) : url
        session.requestedURL = destination
        var request = URLRequest(url: destination)
        if privacySettings.sendGlobalPrivacyControl { request.setValue("1", forHTTPHeaderField: "Sec-GPC") }
        prepareProtection(id: id, session: session) { $0.load(request) }
    }

    private func resetForPrivacyChange() {
        guard !didShutdown, !privacyResetInProgress else { return }
        // Destroy loaded documents so an old script cannot keep running after a
        // stricter setting is selected. The next view uses the new configuration.
        let saved = sessions.mapValues { $0.requestedURL?.absoluteString ?? $0.view.url?.absoluteString ?? "" }
        for id in Array(sessions.keys) { close(id: id) }
        for (id, url) in saved { snapshots[id] = WebPageState(url: url, isSuspended: true) }
        revision &+= 1
    }

    func beginPrivacyReset() {
        privacyResetInProgress = true
        evictionTask?.cancel()
        for id in Array(sessions.keys) { close(id: id) }
        for id in Array(downloadTasks.keys) { cancelDownload(id) }
        downloads.removeAll(); snapshots.removeAll(); peekURL = nil
    }

    func eraseWebsiteData() async {
        await withCheckedContinuation { continuation in
            websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }

    func endPrivacyReset() { privacyResetInProgress = false; retiredView = nil; revision &+= 1 }

    private static let globalPrivacyControlScript = """
    (() => {
      try { Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', {get: () => true, configurable: false}); } catch (_) {}
    })();
    """
    func zoom(id: UUID, factor: Double) {
        guard let view = sessions[id]?.view else { return }
        view.pageZoom = min(3, max(0.5, factor == 0 ? 1 : view.pageZoom * factor))
        revision &+= 1
    }
    func find(id: UUID, query: String, backwards: Bool = false) {
        guard let view = sessions[id]?.view else { onFindResult?(false); return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        view.find(query, configuration: config) { [weak self] result in
            self?.onFindResult?(result.matchFound)
        }
    }
    func clearFind(id: UUID) {
        sessions[id]?.view.find("", configuration: WKFindConfiguration()) { _ in }
    }
    func revealDownload(_ id: UUID) {
        guard let url = downloads.first(where: { $0.id == id })?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func cancelDownload(_ id: UUID) {
        downloadTasks[id]?.cancel { _ in }
        finishDownload(id, status: "Cancelled", success: false)
    }

    private func publish(_ id: UUID) {
        guard let view = sessions[id]?.view else { return }
        snapshots[id] = state(id: id)
        revision &+= 1
        if snapshots[id]?.error == nil, let url = view.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            onPageChanged?(id, view.title ?? url.host ?? "Untitled", url.absoluteString)
        }
    }
    private func id(for view: WKWebView) -> UUID? {
        sessions.first(where: { $0.value.view === view })?.key
    }
    private func evictInactive() async {
        guard sessions.count > liveLimit else { return }
        let candidates = sessions.filter {
            !visibleIDs.contains($0.key) && !$0.value.dirty && !$0.value.playingMedia &&
            $0.value.view.cameraCaptureState == .none && $0.value.view.microphoneCaptureState == .none
        }.sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (id, session) in candidates {
            guard sessions.count > liveLimit, !Task.isCancelled else { break }
            let mediaState = await withCheckedContinuation { continuation in
                session.view.requestMediaPlaybackState { continuation.resume(returning: $0) }
            }
            guard mediaState != .playing, !visibleIDs.contains(id),
                  sessions[id] === session, !session.dirty else { continue }
            var snapshot = state(id: id)
            snapshot.isLoading = false
            snapshot.isSuspended = true
            close(id: id)
            snapshots[id] = snapshot
        }
        revision &+= 1
    }
    private func fail(_ view: WKWebView, error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled, let id = id(for: view) else { return }
        var snapshot = state(id: id)
        snapshot.error = error.localizedDescription
        snapshot.isLoading = false
        snapshots[id] = snapshot
        onError?(id, error.localizedDescription)
        revision &+= 1
    }
    private func register(_ download: WKDownload) {
        guard !didShutdown, !privacyResetInProgress else { download.cancel { _ in }; return }
        let key = ObjectIdentifier(download)
        guard downloadIDs[key] == nil else { return }
        guard let view = download.webView, let sourceID = id(for: view),
              sessions[sourceID]?.protectionReady == true else { download.cancel { _ in }; return }
        let id = UUID()
        downloadIDs[key] = id
        downloadTasks[id] = download
        download.delegate = self
        downloads.insert(BrowserDownload(id: id, name: download.originalRequest?.url?.lastPathComponent ?? "Download"), at: 0)
        downloadObservations[id] = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor [weak self] in
                guard let self, let index = self.downloads.firstIndex(where: { $0.id == id }) else { return }
                self.downloads[index].progress = fraction
            }
        }
    }
    private func finishDownload(_ id: UUID, status: String, success: Bool) {
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            downloads[index].status = status
            downloads[index].isComplete = success
            if success { downloads[index].progress = 1 }
        }
        if let task = downloadTasks.removeValue(forKey: id) { downloadIDs.removeValue(forKey: ObjectIdentifier(task)) }
        downloadObservations.removeValue(forKey: id)
    }

    private static let interactionScript = """
    (() => {
      const post = (data) => { try { window.webkit.messageHandlers.curve.postMessage(data); } catch (_) {} };
      document.addEventListener('click', (event) => {
        if (!event.isTrusted || event.button !== 0) return;
        const anchor = event.target.closest && event.target.closest('a[href]');
        if (!anchor || !/^https?:$/.test(anchor.protocol)) return;
        if (event.shiftKey && !event.metaKey && !event.ctrlKey) {
          event.preventDefault(); event.stopImmediatePropagation();
          post({type:'peek',url:anchor.href});
        } else if (event.metaKey || event.ctrlKey) {
          event.preventDefault(); event.stopImmediatePropagation();
          post({type:'tab',url:anchor.href});
        }
      }, true);
      document.addEventListener('input', (event) => {
        if (event.isTrusted && (/^(INPUT|TEXTAREA|SELECT)$/.test(event.target.tagName) || event.target.isContentEditable)) post({type:'dirty'});
      }, true);
      const updateMedia = () => post({type:'media',playing:Array.from(document.querySelectorAll('audio,video')).some(m=>!m.paused&&!m.ended)});
      document.addEventListener('play',updateMedia,true);
      document.addEventListener('pause',updateMedia,true);
      document.addEventListener('ended',updateMedia,true);
    })();
    """
}

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: WebEngine?
    init(_ owner: WebEngine) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak owner] in owner?.receive(message) }
    }
}

extension WebEngine: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(message)
    }
    fileprivate func receive(_ message: WKScriptMessage) {
        guard let view = message.webView, let id = id(for: view),
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "dirty" { sessions[id]?.dirty = true; return }
        if type == "media" { sessions[id]?.playingMedia = body["playing"] as? Bool ?? false; return }
        guard let text = body["url"] as? String, let url = URL(string: text),
              text.utf8.count <= 16_384,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if type == "peek" { peekURL = url; onPeek?(url) }
        if type == "tab" { onOpenTab?(url) }
    }
}

extension WebEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !didShutdown, !privacyResetInProgress else { decisionHandler(.cancel); return }
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        guard let sessionID = id(for: webView), sessions[sessionID]?.protectionReady == true else { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .linkActivated || navigationAction.navigationType == .formSubmitted || navigationAction.navigationType == .formResubmitted {
            onUserNavigation?()
        }
        if privacySettings.httpsOnly, scheme == "http", !URLSecurity.isLoopback(url) {
            decisionHandler(.cancel)
            let method = (navigationAction.request.httpMethod ?? "GET").uppercased()
            guard ["GET", "HEAD"].contains(method) else {
                fail(webView, error: NSError(domain: "CurveHTTPS", code: 1, userInfo: [NSLocalizedDescriptionKey: "HTTPS is required. This insecure form was not submitted. Open the website's HTTPS address before trying again."]))
                return
            }
            if navigationAction.targetFrame == nil { onOpenTab?(URLSecurity.httpsUpgraded(url)); return }
            if navigationAction.targetFrame?.isMainFrame == true {
                var request = navigationAction.request
                request.url = URLSecurity.httpsUpgraded(url)
                if privacySettings.sendGlobalPrivacyControl { request.setValue("1", forHTTPHeaderField: "Sec-GPC") }
                sessions[sessionID]?.requestedURL = request.url
                webView.load(request)
            }
            return
        }
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if ["http", "https", "about", "blob"].contains(scheme) {
            if ["http", "https"].contains(scheme), navigationAction.navigationType == .linkActivated,
               navigationAction.targetFrame?.isMainFrame == true, let id = id(for: webView),
               shouldPeekNavigation?(id, url, webView.url) == true {
                peekURL = url
                onPeek?(url)
                decisionHandler(.cancel)
                return
            }
            if navigationAction.targetFrame == nil {
                onOpenTab?(url)
                decisionHandler(.cancel)
            } else {
                if navigationAction.targetFrame?.isMainFrame == true, ["http", "https"].contains(scheme),
                   let id = id(for: webView) { sessions[id]?.requestedURL = url }
                decisionHandler(.allow)
            }
            return
        }
        if navigationAction.navigationType == .linkActivated && ["mailto", "tel", "sms"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard !didShutdown, !privacyResetInProgress, let id = id(for: webView), sessions[id]?.protectionReady == true else {
            decisionHandler(.cancel); return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        cancelWebsiteUIRequests(for: webView)
        if let id = id(for: webView) { snapshots[id]?.error = nil; sessions[id]?.dirty = false; publish(id) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let id = id(for: webView) { snapshots[id]?.error = nil; publish(id) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(webView, error: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(webView, error: error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let id = id(for: webView), let session = sessions[id] else { return }
        if session.crashReloads == 0 {
            session.crashReloads = 1
            webView.reload()
        } else {
            fail(webView, error: NSError(domain: "Curve", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: "This page stopped responding. Reload to try again."]))
        }
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { register(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { register(download) }
}

/// The registry owns only pending native requests. Each request completes once,
/// and its default completion rejects access if its document goes away.
@MainActor
private final class WebsiteUIRequest {
    let token = UUID()
    weak var owner: WebEngine?
    weak var view: WKWebView?
    let isCurrent: () -> Bool
    private let rejection: () -> Void
    private let retire: (UUID) -> Void
    var dismiss: (() -> Void)?
    private(set) var isSettled = false

    init(owner: WebEngine, view: WKWebView, isCurrent: @escaping () -> Bool,
         reject: @escaping () -> Void, retire: @escaping (UUID) -> Void) {
        self.owner = owner; self.view = view; self.isCurrent = isCurrent
        self.rejection = reject; self.retire = retire
    }
    func resolve(_ reply: () -> Void) {
        guard !isSettled else { return }
        isSettled = true; retire(token); dismiss = nil
        reply()
    }
    func cancel() {
        guard !isSettled else { return }
        isSettled = true; retire(token)
        let close = dismiss; dismiss = nil
        rejection(); close?()
    }
}

@MainActor
private final class WebsiteUIRequests {
    static let shared = WebsiteUIRequests()
    private var pending: [UUID: WebsiteUIRequest] = [:]
    func begin(owner: WebEngine, view: WKWebView, isCurrent: @escaping () -> Bool,
               reject: @escaping () -> Void) -> WebsiteUIRequest? {
        // A hidden frame cannot stack native prompts behind an existing one.
        guard !pending.values.contains(where: { $0.owner === owner && $0.view === view }) else { return nil }
        let request = WebsiteUIRequest(owner: owner, view: view, isCurrent: isCurrent,
                                       reject: reject, retire: { [weak self] in self?.pending.removeValue(forKey: $0) })
        pending[request.token] = request
        return request
    }
    func cancel(owner: WebEngine, view: WKWebView) {
        let requests = pending.values.filter { $0.owner === owner && $0.view === view }
        for request in requests { request.cancel() }
    }
}

extension WebEngine: WKUIDelegate {
    /// Called on tab close/reset and before a new document starts navigating.
    func cancelWebsiteUIRequests(for view: WKWebView) {
        WebsiteUIRequests.shared.cancel(owner: self, view: view)
    }
    private func nativeUIIsActive(_ view: WKWebView) -> Bool {
        guard !didShutdown, !privacyResetInProgress, let id = id(for: view),
              let session = sessions[id], session.view === view,
              session.protectionReady, !session.preparing,
              let window = view.window, window.isVisible else { return false }
        return true
    }
    private func beginWebsiteUIRequest(for view: WKWebView, bindToDocumentURL: Bool = true,
                                       reject: @escaping () -> Void) -> WebsiteUIRequest? {
        guard nativeUIIsActive(view), view.window?.attachedSheet == nil,
              let id = id(for: view), let session = sessions[id] else { return nil }
        let documentURL = view.url
        return WebsiteUIRequests.shared.begin(owner: self, view: view, isCurrent: { [weak self, weak view, weak session] in
            guard let self, let view, let session else { return false }
            return self.nativeUIIsActive(view) && self.sessions[id] === session && (!bindToDocumentURL || view.url == documentURL)
        }, reject: reject)
    }
    private func websiteOrigin(_ origin: WKSecurityOrigin) -> URL? {
        guard ["https", "http"].contains(origin.protocol.lowercased()), !origin.host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = origin.protocol.lowercased()
        components.host = origin.host.contains(":") && !origin.host.hasPrefix("[") ? "[\(origin.host)]" : origin.host
        if origin.port != 0 { components.port = origin.port }
        guard let url = components.url, URLSecurity.asciiHost(for: url) != nil else { return nil }
        return url
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard nativeUIIsActive(webView) else { return nil }
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { onOpenTab?(url) }
        return nil
    }
    func webViewDidClose(_ webView: WKWebView) {
        guard !didShutdown, !privacyResetInProgress, let id = id(for: webView) else { return }
        onCloseTab?(id)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let origin = websiteOrigin(frame.securityOrigin),
              let request = beginWebsiteUIRequest(for: webView, reject: completionHandler) else { completionHandler(); return }
        let alert = NSAlert()
        alert.messageText = "Website message · \(URLSecurity.displayOrigin(for: origin))"
        alert.informativeText = String(message.prefix(4000))
        alert.addButton(withTitle: "OK")
        present(alert, on: webView, request: request) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let origin = websiteOrigin(frame.securityOrigin),
              let request = beginWebsiteUIRequest(for: webView, reject: { completionHandler(false) }) else { completionHandler(false); return }
        let alert = NSAlert()
        alert.messageText = "Website message · \(URLSecurity.displayOrigin(for: origin))"
        alert.informativeText = String(message.prefix(4000))
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, on: webView, request: request) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard let origin = websiteOrigin(frame.securityOrigin),
              let request = beginWebsiteUIRequest(for: webView, reject: { completionHandler(nil) }) else { completionHandler(nil); return }
        let alert = NSAlert()
        alert.messageText = "Website message · \(URLSecurity.displayOrigin(for: origin))"
        alert.informativeText = String(prompt.prefix(4000))
        let input = NSTextField(string: String((defaultText ?? "").prefix(4000)))
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, on: webView, request: request) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let origin = websiteOrigin(frame.securityOrigin),
              let request = beginWebsiteUIRequest(for: webView, reject: { completionHandler(nil) }) else { completionHandler(nil); return }
        guard let window = webView.window else { request.cancel(); return }
        let panel = NSOpenPanel()
        panel.title = "Choose files for \(URLSecurity.displayOrigin(for: origin))"
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        request.dismiss = { [weak panel] in panel?.cancel(nil) }
        panel.beginSheetModal(for: window) { result in
            guard !request.isSettled else { return }
            guard request.isCurrent() else { request.cancel(); return }
            request.resolve { completionHandler(result == .OK ? panel.urls : nil) }
        }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let resource: String
        switch type {
        case .camera: resource = "camera"
        case .microphone: resource = "microphone"
        case .cameraAndMicrophone: resource = "camera and microphone"
        @unknown default: decisionHandler(.deny); return
        }
        // The visible top-level document must be the requesting origin. A
        // cross-origin iframe cannot borrow its embedding page's identity.
        guard let requestingURL = websiteOrigin(origin), let frameURL = websiteOrigin(frame.securityOrigin),
              let topURL = webView.url,
              URLSecurity.displayOrigin(for: requestingURL) == URLSecurity.displayOrigin(for: frameURL),
              URLSecurity.displayOrigin(for: requestingURL) == URLSecurity.displayOrigin(for: topURL),
              requestingURL.scheme == "https" || URLSecurity.isLoopback(requestingURL),
              let request = beginWebsiteUIRequest(for: webView, reject: { decisionHandler(.deny) }) else { decisionHandler(.deny); return }
        let alert = NSAlert()
        alert.messageText = "Allow \(resource) access?"
        alert.informativeText = "\(URLSecurity.displayOrigin(for: requestingURL)) is requesting access. This choice applies only to this request."
        alert.addButton(withTitle: "Don’t Allow")
        alert.addButton(withTitle: "Allow")
        present(alert, on: webView, request: request) { decisionHandler($0 == .alertSecondButtonReturn ? .grant : .deny) }
    }
    private func present(_ alert: NSAlert, on view: WKWebView, request: WebsiteUIRequest,
                         completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = view.window, request.isCurrent() else { request.cancel(); return }
        request.dismiss = { [weak alert] in
            guard let alert else { return }
            if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }
            alert.window.orderOut(nil)
        }
        alert.beginSheetModal(for: window) { result in
            guard !request.isSettled else { return }
            guard request.isCurrent() else { request.cancel(); return }
            request.resolve { completion(result) }
        }
    }
}

extension WebEngine: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard !didShutdown, !privacyResetInProgress,
              let id = downloadIDs[ObjectIdentifier(download)], downloadTasks[id] === download else { completionHandler(nil); return }
        guard let view = download.webView,
              let request = beginWebsiteUIRequest(for: view, bindToDocumentURL: false, reject: { [weak self] in
                  if let id = self?.downloadIDs[ObjectIdentifier(download)] { self?.finishDownload(id, status: "Cancelled", success: false) }
                  completionHandler(nil)
              }) else {
            finishDownload(id, status: "Cancelled: the requesting page is no longer active", success: false)
            completionHandler(nil); return
        }
        guard let window = view.window else { request.cancel(); return }
        let panel = NSSavePanel()
        panel.title = "Save Download"
        // Keep the extension visible and remove control/bidirectional override
        // characters that could disguise a downloaded executable's filename.
        let name = (suggestedFilename as NSString).lastPathComponent.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !(0x202a...0x202e).contains($0.value) && !(0x2066...0x2069).contains($0.value)
        }
        var safeName = String(String.UnicodeScalarView(name))
        if safeName.count > 180 {
            let fileExtension = (safeName as NSString).pathExtension
            if !fileExtension.isEmpty, fileExtension.count < 40 {
                let base = (safeName as NSString).deletingPathExtension
                safeName = String(base.prefix(179 - fileExtension.count)) + "." + fileExtension
            } else { safeName = String(safeName.prefix(180)) }
        }
        panel.nameFieldStringValue = safeName.isEmpty ? "Download" : safeName
        panel.isExtensionHidden = false; panel.canSelectHiddenExtension = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard !request.isSettled else { return }
            guard let self, !self.didShutdown, !self.privacyResetInProgress,
                  self.downloadTasks[id] === download, request.isCurrent() else { request.cancel(); return }
            request.resolve {
                guard result == .OK, let url = panel.url else {
                    self.finishDownload(id, status: "Cancelled", success: false)
                    completionHandler(nil)
                    return
                }
                // WKDownload must receive a path which does not yet exist. Never
                // overwrite an existing file, even after the save panel's confirmation.
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    self.finishDownload(id, status: "Choose a new filename; the file already exists.", success: false)
                    completionHandler(nil)
                    return
                }
                if let index = self.downloads.firstIndex(where: { $0.id == id }) {
                    self.downloads[index].name = url.lastPathComponent
                    self.downloads[index].url = url
                    self.downloads[index].status = "Downloading"
                }
                completionHandler(url)
            }
        }
        request.dismiss = { [weak panel] in panel?.cancel(nil) }
        panel.beginSheetModal(for: window, completionHandler: finish)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard !didShutdown, !privacyResetInProgress,
              let id = downloadIDs[ObjectIdentifier(download)], downloadTasks[id] === download else { return }
        guard let destination = downloads.first(where: { $0.id == id })?.url else {
            finishDownload(id, status: "Download destination unavailable", success: false); return
        }
        do {
            let attributes = try (destination as NSURL).resourceValues(forKeys: [.quarantinePropertiesKey])
            if attributes[.quarantinePropertiesKey] == nil {
                try (destination as NSURL).setResourceValue([
                    kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
                    kLSQuarantineAgentNameKey as String: "Curve",
                    kLSQuarantineAgentBundleIdentifierKey as String: "com.toymakers.curve",
                    kLSQuarantineTimeStampKey as String: Date()
                ], forKey: .quarantinePropertiesKey)
            }
            guard getxattr(destination.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0 else {
                throw NSError(domain: "CurveDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: "macOS quarantine could not be verified"])
            }
            // Explicit private downloads remain on disk, but should not gain an
            // avoidable Finder record of their source browsing address.
            if isPrivate { _ = removexattr(destination.path, "com.apple.metadata:kMDItemWhereFroms", XATTR_NOFOLLOW) }
            finishDownload(id, status: "Complete", success: true)
        } catch {
            let removed = (try? FileManager.default.removeItem(at: destination)) != nil
            finishDownload(id, status: removed ? "Removed: download security metadata could not be verified" : "Security metadata failed; remove this file manually", success: false)
        }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let id = downloadIDs[ObjectIdentifier(download)], downloadTasks[id] === download else { return }
        finishDownload(id, status: error.localizedDescription, success: false)
    }
}

struct WebContentView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WebContentHost { WebContentHost(webView: webView) }
    func updateNSView(_ host: WebContentHost, context: Context) { host.setWebView(webView) }
    static func dismantleNSView(_ host: WebContentHost, coordinator: ()) { host.releaseWebView() }
}

/// A cached page can briefly have two SwiftUI hosts while a split or sidebar
/// changes structure. Only its newest host may attach it; an outgoing host's
/// final update must never steal the page back into a disappearing subtree.
@MainActor
final class WebContentHost: NSView {
    @MainActor private final class WeakHost {
        weak var value: WebContentHost?
        init(_ value: WebContentHost) { self.value = value }
    }
    @MainActor private final class Mounts {
        var hosts: [WeakHost] = []
        func current(for view: WKWebView) -> WebContentHost? {
            hosts.removeAll {
                guard let host = $0.value, host.window != nil else { return true }
                return host.webView !== view
            }
            return hosts.compactMap(\.value).max { $0.generation < $1.generation }
        }
    }
    private static let mounts = NSMapTable<WKWebView, Mounts>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private static var nextGeneration: UInt64 = 0
    private let generation: UInt64
    private var webView: WKWebView?

    init(webView: WKWebView) {
        Self.nextGeneration &+= 1
        generation = Self.nextGeneration
        super.init(frame: .zero)
        setWebView(webView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setWebView(_ view: WKWebView) {
        if webView !== view {
            releaseWebView()
            webView = view
        }
        attachIfCurrent()
    }
    func releaseWebView() {
        guard let view = webView else { return }
        let group = Self.mounts.object(forKey: view)
        group?.hosts.removeAll { $0.value === self || $0.value == nil }
        if view.superview === self { view.removeFromSuperview() }
        webView = nil
        group?.current(for: view)?.attachIfCurrent()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attachIfCurrent() }
        else if let view = webView, let group = Self.mounts.object(forKey: view) {
            group.hosts.removeAll { $0.value === self || $0.value == nil }
            group.current(for: view)?.attachIfCurrent()
        }
    }
    override func layout() {
        super.layout()
        attachIfCurrent()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        attachIfCurrent()
    }
    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        attachIfCurrent()
    }
    private func attachIfCurrent() {
        guard window != nil, let view = webView else { return }
        let group = Self.mounts.object(forKey: view) ?? Mounts()
        Self.mounts.setObject(group, forKey: view)
        if !group.hosts.contains(where: { $0.value === self }) { group.hosts.append(WeakHost(self)) }
        guard group.current(for: view) === self else { return }
        if view.superview !== self {
            view.removeFromSuperview()
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        view.frame = bounds
    }
}
