import AppKit
import SwiftUI
import BrowserCore

enum BrowserWindowMode { case normal, incognito, little }

@MainActor
final class BrowserCoordinator {
    static let shared = BrowserCoordinator()
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
        do {
            try ProfileMigration.copyLegacyProfile(from: support.appendingPathComponent("Aperture", isDirectory: true), to: destination)
            return (destination, false)
        } catch {
            return (destination, true)
        }
    }()
    static var dataDirectory: URL {
        directoryOverride.map { URL(fileURLWithPath: $0) } ?? defaultDirectory.url
    }
    static var legacyMigrationFailed: Bool { !hasDataDirectoryOverride && defaultDirectory.migrationFailed }
    weak var activeStore: BrowserStore?
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
    func makeStore(mode: BrowserWindowMode, sessionID: UUID? = nil) -> BrowserStore {
        var directory: URL?
        var seed: BrowserState?
        if mode == .normal {
            if let sessionID, sessionID != Self.mainID {
                let base = Self.dataDirectory
                directory = base.appendingPathComponent("Windows/\(sessionID.uuidString)")
                if !FileManager.default.fileExists(atPath: directory!.appendingPathComponent("state.json").path) { seed = activeStore?.mode == .normal ? activeStore?.state : StatePersistence(directory: base).load() }
            }
        }
        return BrowserStore(mode: mode, directory: directory, seed: seed)
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
    init(mode: BrowserWindowMode, sessionID: UUID? = nil) { _store = StateObject(wrappedValue: BrowserCoordinator.shared.makeStore(mode: mode, sessionID: sessionID)) }
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
