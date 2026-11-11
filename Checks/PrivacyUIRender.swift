import AppKit
import SwiftUI
import WebKit
import BrowserCore

/// Renders only Curve's own SwiftUI views into bitmaps. Windows are never
/// ordered on screen, and no screenshot or accessibility access is used.
@main
@MainActor
struct PrivacyUIRender {
    private static let fm = FileManager.default

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if let icon = NSImage(contentsOfFile: "Resources/AppIcon-1024.png") { app.applicationIconImage = icon }
        Task { @MainActor in
            do { try await renderViews() }
            catch { fputs("FAIL: own-view rendering failed: \(error)\n", stderr); exit(1) }
            fflush(stdout)
            exit(0)
        }
        app.run()
    }

    private static func renderViews() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../../work/curve-privacy-ui", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let profile = fm.temporaryDirectory.appendingPathComponent("CurvePrivacyUI-" + UUID().uuidString, isDirectory: true)
        let oldDirectory = ProcessInfo.processInfo.environment["CURVE_DATA_DIR"]
        setenv("CURVE_DATA_DIR", profile.path, 1)

        // The argument domain is process-local and volatile. This makes the shared
        // read-only panel deterministic without writing any real preference key.
        let defaults = UserDefaults.standard
        let oldArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = oldArguments
        arguments["privacy.privateByDefault"] = true
        arguments["privacy.protectionLevel"] = "strict"
        arguments["privacy.httpsOnly"] = true
        arguments["privacy.blockJavaScript"] = false
        arguments["privacy.gpc"] = true
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            defaults.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain)
            if let oldDirectory { setenv("CURVE_DATA_DIR", oldDirectory, 1) } else { unsetenv("CURVE_DATA_DIR") }
            try? fm.removeItem(at: profile)
        }

        let privateEngine = WebEngine(isPrivate: true, websiteDataStore: .nonPersistent())
        let store = BrowserStore(mode: .incognito, directory: profile, engine: privateEngine)
        defer { store.shutdown() }
        let space = BrowserSpace(id: UUID(uuidString: "ED4D8165-4B6B-40C9-9951-E46D90528B66")!, name: "Private", emoji: "◌", colorHex: "C0C1D0")
        var state = BrowserState(spaces: [space], autoArchiveHours: 0)
        _ = state.open(url: "https://docs.example.invalid", title: "Documentation", kind: .pinned)
        _ = state.open(url: "https://reading.example.invalid", title: "Reading list", kind: .pinned)
        _ = state.open(url: "curve://start", title: "Private browsing")
        store.state = state

        try await snapshot(PrivacyPanel(store: store, engine: privateEngine),
                           size: NSSize(width: 620, height: 720),
                           appearance: .aqua, to: output.appendingPathComponent("privacy-panel-light.png"))
        try await snapshot(PrivacyPanel(store: store, engine: privateEngine),
                           size: NSSize(width: 620, height: 720),
                           appearance: .darkAqua, to: output.appendingPathComponent("privacy-panel-dark.png"))
        try await snapshot(PrivacyPanel(store: store, engine: privateEngine),
                           size: NSSize(width: 620, height: 720), appearance: .aqua,
                           to: output.appendingPathComponent("privacy-panel-bottom-light.png"), scrollToBottom: true)
        try await snapshot(PrivacyPanel(store: store, engine: privateEngine),
                           size: NSSize(width: 620, height: 720), appearance: .darkAqua,
                           to: output.appendingPathComponent("privacy-panel-bottom-dark.png"), scrollToBottom: true)
        try await snapshot(BrowserView(store: store, engine: privateEngine),
                           size: NSSize(width: 1280, height: 820),
                           appearance: .aqua, to: output.appendingPathComponent("private-browser-start.png"))
        print("Rendered only synthetic, read-only Curve UI. No window was shown and no existing app UI was captured.")
    }

    private static func snapshot<Content: View>(_ content: Content, size: NSSize,
                                               appearance: NSAppearance.Name, to destination: URL,
                                               scrollToBottom: Bool = false) async throws {
        let isDark = appearance == .darkAqua
        let view = AnyView(content
            .environment(\.locale, Locale(identifier: "en_US"))
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            .environment(\.colorScheme, isDark ? .dark : .light)
            .preferredColorScheme(isDark ? .dark : .light)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = []
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = isDark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .windowBackgroundColor
        window.isOpaque = true
        window.contentView = host
        window.setContentSize(size)
        defer { window.close() }

        // Flush SwiftUI/AppKit layout and asynchronous first-window setup while
        // leaving this dedicated native window hidden throughout the render.
        for _ in 0..<8 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            host.needsDisplay = true
            host.displayIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 125_000_000)
        }
        if scrollToBottom, let scroll = scrollView(in: host), let document = scroll.documentView {
            let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentSize.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                try? await Task.sleep(nanoseconds: 125_000_000)
            }
        }
        guard !window.isVisible, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw NSError(domain: "PrivacyUIRender", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate a hidden-view bitmap."])
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            throw NSError(domain: "PrivacyUIRender", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode the view bitmap."])
        }
        try png.write(to: destination, options: Data.WritingOptions.atomic)
        print("\(destination.path) — \(Int(size.width))×\(Int(size.height)) points, \(bitmap.pixelsWide)×\(bitmap.pixelsHigh) pixels")
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView,
           let document = scroll.documentView, document.bounds.height > scroll.contentSize.height + 20 { return scroll }
        for child in view.subviews { if let scroll = scrollView(in: child) { return scroll } }
        return nil
    }
}
