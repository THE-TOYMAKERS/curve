import AppKit
import SwiftUI
import BrowserCore
@preconcurrency import WebKit

enum BrowserWindowMode { case normal, incognito, little }

@MainActor
final class BrowserCoordinator: ObservableObject {
    static let shared = BrowserCoordinator()
    private let privacySettings: PrivacySettings
    private let persistentWebsiteDataStore: WKWebsiteDataStore
    init(privacySettings: PrivacySettings? = nil, persistentWebsiteDataStore: WKWebsiteDataStore? = nil) {
        self.privacySettings = privacySettings ?? .shared
        self.persistentWebsiteDataStore = persistentWebsiteDataStore ?? .default()
    }
    private static var directoryOverride: String? {
        ProcessInfo.processInfo.environment["CURVE_DATA_DIR"]
            ?? Bundle.main.object(forInfoDictionaryKey: "CurveDataDirectory") as? String
            ?? ProcessInfo.processInfo.environment["APERTURE_DATA_DIR"]
            ?? Bundle.main.object(forInfoDictionaryKey: "ApertureDataDirectory") as? String
    }
    static var hasDataDirectoryOverride: Bool {
        directoryOverride != nil
    }
    private static let defaultDirectory: (url: URL, migrationFailed: Bool) = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let destination = support.appendingPathComponent("Curve", isDirectory: true)
        // Sandboxed builds import an earlier profile only through a user-selected
        // file. A private launch must not read/copy another browser's metadata.
        return (destination, false)
    }()
    static var dataDirectory: URL {
        directoryOverride.map { URL(fileURLWithPath: $0) } ?? defaultDirectory.url
    }
    static var legacyMigrationFailed: Bool { !hasDataDirectoryOverride && defaultDirectory.migrationFailed }
    weak var activeStore: BrowserStore?
    private final class WeakStore {
        weak var value: BrowserStore?
        init(_ value: BrowserStore) { self.value = value }
    }
    private var registeredStores: [WeakStore] = []
    private var activeErasureOptions: (history: Bool, websiteData: Bool, savedTabs: Bool)?
    @Published private(set) var isErasingData = false
    func register(_ store: BrowserStore) {
        registeredStores.removeAll { $0.value == nil }
        registeredStores.append(WeakStore(store))
        if let options = activeErasureOptions {
            store.prepareForPrivacyErasure(history: options.history, websiteData: options.websiteData, savedTabs: options.savedTabs)
        }
    }
    func unregister(_ store: BrowserStore) { registeredStores.removeAll { $0.value == nil || $0.value === store } }
    func nextPersistentSessionID() -> UUID {
        let mainProfileIsOpen = registeredStores.compactMap(\.value).contains {
            $0.mode == .normal && $0.persistence.directory.standardizedFileURL == Self.dataDirectory.standardizedFileURL
        }
        return mainProfileIsOpen ? UUID() : Self.mainID
    }
    var openNormalWindow: (() -> Void)?
    var pendingURLs: [URL] = []
    static let mainID = UUID(uuidString: "DAA70000-0000-4000-8000-000000000001")!
    func receive(_ urls: [URL]) {
        let safe = urls.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        if let activeStore { for url in safe { activeStore.open(url.absoluteString) } }
        else { pendingURLs += safe }
    }
    func consumePendingURLs(in store: BrowserStore) {
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs; pendingURLs.removeAll()
        for url in urls { store.open(url.absoluteString) }
    }
    func makeStore(mode requestedMode: BrowserWindowMode, sessionID: UUID? = nil, respectPrivateDefault: Bool = true) -> BrowserStore {
        let mode: BrowserWindowMode = requestedMode == .normal && respectPrivateDefault && privacySettings.privateByDefault ? .incognito : requestedMode
        var directory: URL?
        var seed: BrowserState?
        if mode == .normal {
            if let sessionID, sessionID != Self.mainID {
                let base = Self.dataDirectory
                directory = base.appendingPathComponent("Windows/\(sessionID.uuidString)")
                if !FileManager.default.fileExists(atPath: directory!.appendingPathComponent("state.json").path) { seed = activeStore?.mode == .normal ? activeStore?.state : StatePersistence(directory: base).load() }
            }
        }
        let engine = WebEngine(isPrivate: mode != .normal, websiteDataStore: mode == .normal ? persistentWebsiteDataStore : nil, privacySettings: privacySettings)
        let store = BrowserStore(mode: mode, directory: directory, seed: seed, engine: engine)
        if self !== Self.shared { register(store) }
        return store
    }

    /// Quiesce every live window before erasing shared storage. Otherwise a
    /// background document or deferred save could immediately restore old data.
    func eraseBrowsingData(history: Bool, websiteData: Bool, savedTabs: Bool) async throws {
        guard !isErasingData, history || websiteData || savedTabs else { return }
        isErasingData = true
        activeErasureOptions = (history, websiteData, savedTabs)
        registeredStores.removeAll { $0.value == nil }
        let stores = registeredStores.compactMap(\.value)
        for store in stores { store.prepareForPrivacyErasure(history: history, websiteData: websiteData, savedTabs: savedTabs) }
        defer {
            activeErasureOptions = nil
            for store in registeredStores.compactMap(\.value) { store.finishPrivacyErasure() }
            isErasingData = false
        }
        if websiteData || savedTabs { try await WebDocumentRetirement.waitForAll() }
        if history || savedTabs {
            if savedTabs { try ProfilePrivacy.eraseSavedSessions(in: Self.dataDirectory) }
            else { try ProfilePrivacy.eraseHistory(in: Self.dataDirectory) }
            for store in stores where store.mode == .normal { try store.persistence.clear() }
        }
        if websiteData {
            await withCheckedContinuation { continuation in
                persistentWebsiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { continuation.resume() }
            }
            // All engines have already stopped; shared normal stores cannot
            // repopulate cookies while another window's store is being cleared.
            var clearedEngines: Set<ObjectIdentifier> = []
            while let store = registeredStores.compactMap(\.value).first(where: { !clearedEngines.contains(ObjectIdentifier($0.engine)) }) {
                clearedEngines.insert(ObjectIdentifier(store.engine))
                try await WebDocumentRetirement.waitForAll()
                await store.engine.eraseWebsiteData()
            }
        }
    }
}

struct BrowserStoreFocusKey: FocusedValueKey { typealias Value = BrowserStore }
extension FocusedValues {
    var browserStore: BrowserStore? {
        get { self[BrowserStoreFocusKey.self] }
        set { self[BrowserStoreFocusKey.self] = newValue }
    }
}

struct BrowserWindowHost: View {
    @StateObject private var store: BrowserStore
    @Environment(\.openWindow) private var openWindow
    init(mode: BrowserWindowMode, sessionID: UUID? = nil, respectPrivateDefault: Bool = true) { _store = StateObject(wrappedValue: BrowserCoordinator.shared.makeStore(mode: mode, sessionID: sessionID, respectPrivateDefault: respectPrivateDefault)) }
    var body: some View {
        BrowserView(store: store, engine: store.engine)
            .focusedSceneValue(\.browserStore, store)
            .focusedSceneObject(store)
            .onAppear {
                let open = openWindow
                BrowserCoordinator.shared.openNormalWindow = { open(id: "browser", value: UUID()) }
                store.onNewWindow = { mode in
                    switch mode {
                    case .normal: open(id: "browser", value: UUID())
                    case .incognito: open(id: "private")
                    case .little: open(id: "little")
                    }
                }
            }
    }
}
