import AppKit
import SwiftUI
import Combine
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

    init(isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        websiteDataStore = isPrivate ? .nonPersistent() : .default()
        super.init()
    }
    var onPageChanged: ((UUID, String, String) -> Void)?
    var onOpenTab: ((URL) -> Void)?
    var onPeek: ((URL) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onError: ((UUID, String) -> Void)?
    var onFindResult: ((Bool) -> Void)?
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
    var liveCount: Int { sessions.count }

    func webView(for id: UUID, url: URL) -> WKWebView {
        if didShutdown {
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
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        let controller = WKUserContentController()
        controller.add(WeakScriptHandler(self), contentWorld: Self.interactionWorld, name: "curve")
        controller.addUserScript(WKUserScript(source: Self.interactionScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: Self.interactionWorld))
        config.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.isInspectable = true
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
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func state(id: UUID) -> WebPageState {
        if let session = sessions[id] {
            let view = session.view
            return WebPageState(url: view.url?.absoluteString ?? session.requestedURL?.absoluteString ?? snapshots[id]?.url ?? "",
                                title: view.title ?? snapshots[id]?.title ?? "",
                                isLoading: view.isLoading, progress: view.estimatedProgress,
                                canGoBack: view.canGoBack, canGoForward: view.canGoForward,
                                error: snapshots[id]?.error, isSuspended: false)
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
        sessions[id]?.view.stopLoading()
        sessions[id]?.view.navigationDelegate = nil
        sessions[id]?.view.uiDelegate = nil
        sessions[id]?.view.configuration.userContentController.removeScriptMessageHandler(forName: "curve", contentWorld: Self.interactionWorld)
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
            websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                        modifiedSince: .distantPast) { }
        }
    }

    func load(id: UUID, url: URL) {
        guard !didShutdown else { return }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        snapshots[id]?.error = nil
        if let session = sessions[id] {
            session.requestedURL = url
            session.view.load(URLRequest(url: url))
        } else {
            _ = webView(for: id, url: url)
        }
        sessions[id]?.dirty = false
        sessions[id]?.crashReloads = 0
    }
    func openHTML(id: UUID, html: String, baseURL: URL? = nil) {
        guard !didShutdown else { return }
        let view = webView(for: id, url: URL(string: "about:blank")!)
        view.loadHTMLString(html, baseURL: baseURL)
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
                session.view.load(URLRequest(url: url))
            } else { session.view.reload() }
        }
    }
    func stop(_ id: UUID) { sessions[id]?.view.stopLoading() }
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
            snapshots[id] = snapshot
            session.view.stopLoading()
            session.view.navigationDelegate = nil
            session.view.uiDelegate = nil
            session.view.configuration.userContentController.removeScriptMessageHandler(forName: "curve", contentWorld: Self.interactionWorld)
            session.view.removeFromSuperview()
            sessions.removeValue(forKey: id)
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
        guard !didShutdown else { download.cancel { _ in }; return }
        let key = ObjectIdentifier(download)
        guard downloadIDs[key] == nil else { return }
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
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if type == "peek" { peekURL = url; onPeek?(url) }
        if type == "tab" { onOpenTab?(url) }
    }
}

extension WebEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !didShutdown else { decisionHandler(.cancel); return }
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
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
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
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

extension WebEngine: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !didShutdown else { return nil }
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { onOpenTab?(url) }
        return nil
    }
    func webViewDidClose(_ webView: WKWebView) { if let id = id(for: webView) { onCloseTab?(id) } }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = String(message.prefix(4000))
        alert.addButton(withTitle: "OK")
        present(alert, on: webView) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = String(message.prefix(4000))
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, on: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = String(prompt.prefix(4000))
        let input = NSTextField(string: defaultText ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, on: webView) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window = webView.window {
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else { completionHandler(panel.runModal() == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let alert = NSAlert()
        let resource: String
        switch type {
        case .camera: resource = "camera"
        case .microphone: resource = "microphone"
        case .cameraAndMicrophone: resource = "camera and microphone"
        @unknown default: decisionHandler(.deny); return
        }
        alert.messageText = "Allow \(origin.host) to use your \(resource)?"
        alert.informativeText = "Allow access only if you trust this website. This choice applies to this request."
        alert.addButton(withTitle: "Don’t Allow")
        alert.addButton(withTitle: "Allow")
        present(alert, on: webView) { decisionHandler($0 == .alertSecondButtonReturn ? .grant : .deny) }
    }
    private func present(_ alert: NSAlert, on view: WKWebView, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }
}

extension WebEngine: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        register(download)
        guard let id = downloadIDs[ObjectIdentifier(download)] else { completionHandler(nil); return }
        let panel = NSSavePanel()
        panel.title = "Save Download"
        panel.nameFieldStringValue = (suggestedFilename as NSString).lastPathComponent
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard let self else { completionHandler(nil); return }
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
        if let window = download.webView?.window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let id = downloadIDs[ObjectIdentifier(download)] else { return }
        finishDownload(id, status: "Complete", success: true)
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let id = downloadIDs[ObjectIdentifier(download)] else { return }
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
