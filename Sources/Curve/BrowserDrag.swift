import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import BrowserCore

extension UTType {
    static let curveDrag = UTType(exportedAs: "com.toymakers.curve.drag-item", conformingTo: .data)
    static let curveTab = UTType(exportedAs: "com.toymakers.curve.tab", conformingTo: .curveDrag)
    static let curveFolder = UTType(exportedAs: "com.toymakers.curve.folder", conformingTo: .curveDrag)
    static let curveSpace = UTType(exportedAs: "com.toymakers.curve.space", conformingTo: .curveDrag)
}

enum BrowserDragItem: Codable, Equatable, Hashable {
    case tab(UUID), folder(UUID), space(UUID)
    var id: UUID { switch self { case .tab(let id), .folder(let id), .space(let id): return id } }
    var type: UTType { switch self { case .tab: return .curveTab; case .folder: return .curveFolder; case .space: return .curveSpace } }
}
enum BrowserDropTarget: Equatable, Hashable {
    case tab(UUID), folder(UUID), pinned, today, favorites, space(UUID), splitLeft, splitRight
}
enum BrowserDropPosition: String, Codable { case before, inside, after }

struct BrowserDropFrame: Equatable {
    let target: BrowserDropTarget
    let rect: CGRect
    let axis: Axis
    var viewport: CGRect? = nil
    var visibleRect: CGRect { viewport.map { rect.intersection($0) } ?? rect }

    func position(for item: BrowserDragItem, at point: CGPoint) -> BrowserDropPosition {
        let value = axis == .horizontal ? point.x - rect.minX : point.y - rect.minY
        let length = max(1, axis == .horizontal ? rect.width : rect.height)
        switch target {
        case .tab: return value < length / 2 ? .before : .after
        case .folder:
            guard case .folder = item else { return .inside }
            if value < length * 0.23 { return .before }
            if value > length * 0.77 { return .after }
            return .inside
        case .space:
            guard case .space = item else { return .inside }
            return value < length / 2 ? .before : .after
        default: return .inside
        }
    }
}
private struct BrowserDropFramesKey: PreferenceKey {
    static var defaultValue: [BrowserDropFrame] = []
    static func reduce(value: inout [BrowserDropFrame], nextValue: () -> [BrowserDropFrame]) { value.append(contentsOf: nextValue()) }
}
private struct BrowserDragViewportKey: EnvironmentKey { static let defaultValue: CGRect? = nil }
private extension EnvironmentValues {
    var browserDragViewport: CGRect? {
        get { self[BrowserDragViewportKey.self] }
        set { self[BrowserDragViewportKey.self] = newValue }
    }
}
private struct BrowserDragViewport: ViewModifier {
    @Environment(\.browserDragViewport) private var parentViewport
    @State private var viewport = CGRect.zero
    func body(content: Content) -> some View {
        content.environment(\.browserDragViewport, parentViewport.map { viewport.intersection($0) } ?? viewport)
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { viewport = geometry.frame(in: .named("curveDrag")) }
                    .onChange(of: geometry.frame(in: .named("curveDrag"))) { _, value in viewport = value }
            })
    }
}

/// A drag carries a local snapshot, never cookies or account data. Cross-window
/// drops copy this snapshot using new IDs, leaving the source window untouched.
struct BrowserDragPayload: Codable {
    var token = UUID()
    let item: BrowserDragItem
    var tab: BrowserTab?
    var space: BrowserSpace?
    var folders: [BrowserFolder] = []
    var tabs: [BrowserTab] = []
}

@MainActor
private final class BrowserDragReference {
    weak var session: BrowserDragSession?
    init(_ session: BrowserDragSession) { self.session = session }
}
@MainActor
private enum BrowserDragRegistry {
    static weak var source: BrowserDragSession?
    static var sessions: [BrowserDragReference] = []
    private static var consumed = Set<UUID>()
    private static var consumedOrder: [UUID] = []
    static func contains(_ token: UUID) -> Bool { consumed.contains(token) }
    static func consume(_ token: UUID) {
        guard consumed.insert(token).inserted else { return }
        consumedOrder.append(token)
        if consumedOrder.count > 512 { consumed.remove(consumedOrder.removeFirst()) }
    }
}

@MainActor
final class BrowserDragPresentation: ObservableObject {
    @Published var point: CGPoint?
    @Published var item: BrowserDragItem?
    @Published var title = ""
}

@MainActor
private enum BrowserDragTrace {
    static func write(_ message: String) {
        guard Bundle.main.object(forInfoDictionaryKey: "CurveUITestMode") as? Bool == true else { return }
        let directory = BrowserCoordinator.dataDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("drag-debug.log")
        let data = Data("\(Date().timeIntervalSince1970) \(message)\n".utf8)
        if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url); return }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf: data)
    }
}

@MainActor
final class BrowserDragSession: ObservableObject {
    let presentation = BrowserDragPresentation()
    @Published private(set) var activeTabID: UUID?
    @Published private(set) var activeFolderID: UUID?
    @Published private(set) var activeSpaceID: UUID?
    @Published private(set) var incomingItem: BrowserDragItem?
    @Published private(set) var target: BrowserDropTarget?
    @Published private(set) var position: BrowserDropPosition = .inside
    private(set) var payload: BrowserDragPayload?
    weak var sourceStore: BrowserStore?
    private var hoverTask: Task<Void, Never>?
    private var localReleaseMonitor: Any?
    private var globalReleaseMonitor: Any?
    private var deactivationObserver: NSObjectProtocol?
    private var releaseTask: Task<Void, Never>?
    private var initialSpace: UUID?
    private var initialFocus: UUID?
    private var expansionBeforeHover: [UUID: Bool] = [:]
    private weak var hoverStore: BrowserStore?
    private weak var coordinateView: NSView?
    private weak var coordinateStore: BrowserStore?
    private var dropFrames: [BrowserDropFrame] = []
    private var lastUpdateLog = Date.distantPast
    private var committed = false
    private var dropInProgress = false
    private var monitorsMouse = true
    private var gestureDriven = false

    init() {
        BrowserDragRegistry.sessions.removeAll { $0.session == nil }
        BrowserDragRegistry.sessions.append(BrowserDragReference(self))
    }

    var item: BrowserDragItem? { payload?.item ?? incomingItem }
    var isDragging: Bool { item != nil || target != nil }
    func isSource(_ item: BrowserDragItem) -> Bool { payload?.item == item }
    func isTarget(_ target: BrowserDropTarget, position: BrowserDropPosition? = nil) -> Bool {
        self.target == target && (position == nil || self.position == position)
    }
    var knownPayload: BrowserDragPayload? { payload ?? BrowserDragRegistry.source?.payload }
    var knownSourceStore: BrowserStore? { sourceStore ?? BrowserDragRegistry.source?.sourceStore }

    func begin(_ item: BrowserDragItem, store: BrowserStore, monitorMouse: Bool = true) -> NSItemProvider {
        if let previous = BrowserDragRegistry.source, previous !== self { previous.finish(cancelled: true) }
        finish(cancelled: true)
        let snapshot = store.dragPayload(for: item)
        monitorsMouse = monitorMouse
        payload = snapshot; sourceStore = store; initialSpace = store.state.activeSpaceID; initialFocus = store.focusedPane
        presentation.item = item; presentation.title = previewTitle(snapshot); presentation.point = nil
        switch item { case .tab(let id): activeTabID = id; case .folder(let id): activeFolderID = id; case .space(let id): activeSpaceID = id }
        BrowserDragRegistry.source = self; committed = false
        trace("begin \(item) buttons=\(NSEvent.pressedMouseButtons)")
        BrowserDragRegistry.sessions.removeAll { $0.session == nil }
        for receiver in BrowserDragRegistry.sessions.compactMap(\.session) where receiver !== self {
            receiver.incomingItem = item
            receiver.presentation.item = item; receiver.presentation.title = presentation.title; receiver.presentation.point = nil
            switch item { case .tab(let id): receiver.activeTabID = id; case .folder(let id): receiver.activeFolderID = id; case .space(let id): receiver.activeSpaceID = id }
        }
        let encoded = (try? JSONEncoder().encode(snapshot)) ?? Data()
        // An eager custom-data representation is also visible to AppKit's drag
        // pasteboard bridge; no public text representation reaches text fields.
        let provider = NSItemProvider(item: encoded as NSData, typeIdentifier: UTType.curveDrag.identifier)
        provider.registerDataRepresentation(forTypeIdentifier: item.type.identifier, visibility: .all) { completion in completion(encoded, nil); return nil }
        trace("provider types=\(provider.registeredTypeIdentifiers.joined(separator: ","))")
        if monitorMouse { monitorRelease() }
        return provider
    }

    func beginGesture(_ item: BrowserDragItem, store: BrowserStore) -> UUID? {
        _ = begin(item, store: store); gestureDriven = true; return payload?.token
    }
    func updateGesture(at point: CGPoint, token: UUID) {
        guard gestureDriven, payload?.token == token, let screenPoint = screenPoint(for: point) else { return }
        routeGesture(at: screenPoint)
    }
    func endGesture(at point: CGPoint, token: UUID) {
        trace("gestureEnded point=\(point) active=\(NSApp.isActive) tokenMatches=\(payload?.token == token)")
        guard gestureDriven, payload?.token == token else { return }
        if let screenPoint = screenPoint(for: point), commitFallbackDrop(at: screenPoint) { return }
        finish(cancelled: true)
    }
    private func screenPoint(for point: CGPoint) -> CGPoint? {
        guard let view = coordinateView, let window = view.window else { return nil }
        return window.convertPoint(toScreen: view.convert(point, to: nil))
    }
    private func previewTitle(_ payload: BrowserDragPayload) -> String {
        switch payload.item {
        case .tab: return payload.tab?.title ?? "Tab"
        case .folder(let id): return payload.folders.first { $0.id == id }?.name.components(separatedBy: " / ").last ?? "Folder"
        case .space: return payload.space?.name ?? "Space"
        }
    }
    private func routeGesture(at screenPoint: CGPoint) {
        guard let payload, let source = sourceStore else { return }
        let sessions = BrowserDragRegistry.sessions.compactMap(\.session)
        var receiverAtPointer: BrowserDragSession?
        for window in NSApp.orderedWindows where window.isVisible && window.frame.contains(screenPoint) {
            if let receiver = sessions.first(where: { $0.coordinateView?.window === window }),
               let view = receiver.coordinateView, let store = receiver.coordinateStore, !view.isHiddenOrHasHiddenAncestor {
                let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
                guard view.bounds.contains(point) else { continue }
                receiverAtPointer = receiver
                if receiver.presentation.point != point { receiver.presentation.point = point }
                if let frame = receiver.sortedTargets(at: point).first(where: { receiver.permits(payload.item, source: source, store: store, frame: $0, point: point) }) {
                    receiver.hover(frame.target, position: frame.position(for: payload.item, at: point), store: store)
                } else if let old = receiver.target { receiver.exit(old) }
                break
            }
        }
        for receiver in sessions where receiver !== receiverAtPointer {
            if receiver.presentation.point != nil { receiver.presentation.point = nil }
            if let old = receiver.target { receiver.exit(old) }
        }
    }
    private func sortedTargets(at point: CGPoint) -> [BrowserDropFrame] {
        dropFrames.filter { $0.visibleRect.width > 0 && $0.visibleRect.height > 0 && $0.visibleRect.contains(point) }
            .sorted { $0.visibleRect.width * $0.visibleRect.height < $1.visibleRect.width * $1.visibleRect.height }
    }
    private func permits(_ item: BrowserDragItem, source: BrowserStore, store: BrowserStore, frame: BrowserDropFrame, point: CGPoint) -> Bool {
        if source === store { return store.canDrop(item, on: frame.target, position: frame.position(for: item, at: point)) }
        switch (item, frame.target) {
        case (.tab, _), (.folder, .folder), (.folder, .pinned), (.folder, .space), (.space, .space): return true
        default: return false
        }
    }

    private func monitorRelease() {
        guard localReleaseMonitor == nil else { return }
        // Button-state polling is unreliable for accessibility-generated native
        // drags. Observe actual release/cancel events only while a drag exists.
        localReleaseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .leftMouseDragged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .keyDown && event.keyCode == 53 {
                    self.trace("escape"); self.finish(cancelled: true)
                } else if event.type == .leftMouseDragged && self.gestureDriven,
                          let point = event.window?.convertPoint(toScreen: event.locationInWindow) {
                    self.routeGesture(at: point)
                } else if event.type == .leftMouseUp {
                    let point = event.window?.convertPoint(toScreen: event.locationInWindow)
                    self.scheduleReleaseCleanup("mouseUp.local point=\(event.locationInWindow)", fallbackAt: point)
                }
            }
            return event
        }
        globalReleaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleReleaseCleanup("mouseUp.outside") }
        }
        deactivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleReleaseCleanup("appDeactivated") }
        }
    }
    private func scheduleReleaseCleanup(_ reason: String, fallbackAt screenPoint: CGPoint? = nil) {
        guard isDragging, !dropInProgress else { return }
        trace(reason); releaseTask?.cancel()
        releaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self, !self.dropInProgress else { return }
            if let screenPoint, BrowserDragRegistry.source === self, self.commitFallbackDrop(at: screenPoint) { return }
            self.finish(cancelled: true)
        }
    }
    func updateDropFrames(_ frames: [BrowserDropFrame]) { dropFrames = frames }
    func registerCoordinateView(_ view: NSView, store: BrowserStore) { coordinateView = view; coordinateStore = store }

    /// A very fast pointer gesture can finish before SwiftUI establishes its
    /// native dragging destination. Native performDrop has the first chance;
    /// only an otherwise unhandled release uses the same registered targets.
    private func commitFallbackDrop(at screenPoint: CGPoint) -> Bool {
        guard gestureDriven || NSApp.isActive, let payload, let source = sourceStore else { return false }
        let sessions = BrowserDragRegistry.sessions.compactMap(\.session)
        for window in NSApp.orderedWindows where window.isVisible && window.frame.contains(screenPoint) {
            for receiver in sessions {
                guard let view = receiver.coordinateView, view.window === window, !view.isHiddenOrHasHiddenAncestor,
                      let store = receiver.coordinateStore else { continue }
                let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
                trace("fallback point=\(point) targets=\(receiver.dropFrames.count)")
                if receiver.commitRegisteredDrop(at: point, payload: payload, from: source, store: store) { return true }
            }
        }
        trace("fallback no accepted target")
        return false
    }
    @discardableResult
    func commitRegisteredDrop(at point: CGPoint, payload: BrowserDragPayload, from source: BrowserStore, store: BrowserStore) -> Bool {
        let candidates = sortedTargets(at: point)
        for frame in candidates {
            let position = frame.position(for: payload.item, at: point)
            if !permits(payload.item, source: source, store: store, frame: frame, point: point) { continue }
            if store.commitDrop(payload, from: source, on: frame.target, position: position) {
                trace("fallback committed \(frame.target) \(position)"); didCommit(); return true
            }
        }
        return false
    }
    func prepareForDrop() {
        dropInProgress = true; releaseTask?.cancel(); releaseTask = nil; hoverTask?.cancel()
        if let source = BrowserDragRegistry.source, source !== self {
            source.dropInProgress = true; source.releaseTask?.cancel(); source.releaseTask = nil
        }
    }
    func cancelDrop() {
        if let source = BrowserDragRegistry.source, source !== self { source.finish(cancelled: true) }
        finish(cancelled: true)
    }
    @discardableResult
    func importPayload(_ payload: BrowserDragPayload, store: BrowserStore, on target: BrowserDropTarget, position: BrowserDropPosition = .inside) -> Bool {
        guard !BrowserDragRegistry.contains(payload.token) else { trace("rejected consumed payload \(payload.token)"); return false }
        guard store.commitDrop(payload, from: nil, on: target, position: position) else { return false }
        BrowserDragRegistry.consume(payload.token); return true
    }
    func trace(_ message: String) { BrowserDragTrace.write("session=\(ObjectIdentifier(self)) \(message)") }
    func traceUpdate(_ destination: BrowserDropTarget, position: BrowserDropPosition) {
        guard Date().timeIntervalSince(lastUpdateLog) > 0.25 else { return }
        lastUpdateLog = Date(); trace("updated \(destination) \(position)")
    }
    private func removeReleaseMonitors() {
        if let localReleaseMonitor { NSEvent.removeMonitor(localReleaseMonitor); self.localReleaseMonitor = nil }
        if let globalReleaseMonitor { NSEvent.removeMonitor(globalReleaseMonitor); self.globalReleaseMonitor = nil }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver); self.deactivationObserver = nil }
    }
    deinit {
        if let localReleaseMonitor { NSEvent.removeMonitor(localReleaseMonitor) }
        if let globalReleaseMonitor { NSEvent.removeMonitor(globalReleaseMonitor) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        hoverTask?.cancel(); releaseTask?.cancel()
    }

    func hover(_ destination: BrowserDropTarget, position: BrowserDropPosition, store: BrowserStore) {
        if hoverStore == nil { hoverStore = store; initialSpace = store.state.activeSpaceID; initialFocus = store.focusedPane }
        let incoming = knownPayload?.item
        if incomingItem != incoming { incomingItem = incoming }
        if monitorsMouse && payload == nil { monitorRelease() }
        guard target != destination || self.position != position else { return }
        target = destination; self.position = position; hoverTask?.cancel()
        switch destination {
        case .folder(let id) where position == .inside:
            let isLocal = knownSourceStore === store
            guard (!isLocal || item != .folder(id)), let folder = store.state.folders.first(where: { $0.id == id }), !folder.isExpanded else { return }
            if isLocal, case .folder(let sourceID) = item, !store.canMoveFolder(sourceID, into: id) { return }
            expansionBeforeHover[id] = folder.isExpanded
            hoverTask = Task { @MainActor [weak self, weak store] in
                try? await Task.sleep(nanoseconds: 430_000_000)
                guard !Task.isCancelled, let self, let store, self.target == destination, self.position == .inside,
                      let i = store.state.folders.firstIndex(where: { $0.id == id }) else { return }
                withAnimation(.easeOut(duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16)) { store.state.folders[i].isExpanded = true }
            }
        case .space(let id):
            if case .space = item { return }
            guard store.state.activeSpaceID != id else { return }
            hoverTask = Task { @MainActor [weak self, weak store] in
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard !Task.isCancelled, let self, let store, self.target == destination else { return }
                withAnimation(.easeOut(duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16)) { store.state.switchSpace(id); store.focusedPane = nil }
                store.trim()
            }
        default: break
        }
    }
    func exit(_ destination: BrowserDropTarget) {
        guard target == destination else { return }; hoverTask?.cancel(); target = nil
    }
    func finish(cancelled: Bool) {
        if isDragging { trace("finish cancelled=\(cancelled) pendingDrop=\(dropInProgress)") }
        hoverTask?.cancel(); hoverTask = nil; removeReleaseMonitors(); releaseTask?.cancel(); releaseTask = nil
        if cancelled && !committed, let store = hoverStore ?? sourceStore {
            if let initialSpace, store.state.spaces.contains(where: { $0.id == initialSpace }) {
                store.state.switchSpace(initialSpace); store.focusedPane = initialFocus
            }
            for (id, wasExpanded) in expansionBeforeHover {
                if let i = store.state.folders.firstIndex(where: { $0.id == id }) { store.state.folders[i].isExpanded = wasExpanded }
            }
            store.saveSoon(); store.trim()
        }
        if let payload { BrowserDragRegistry.consume(payload.token) }
        if BrowserDragRegistry.source === self {
            BrowserDragRegistry.source = nil
            for receiver in BrowserDragRegistry.sessions.compactMap(\.session) where receiver !== self {
                receiver.finish(cancelled: !receiver.committed)
            }
        }
        activeTabID = nil; activeFolderID = nil; activeSpaceID = nil; incomingItem = nil; payload = nil
        target = nil; position = .inside; expansionBeforeHover.removeAll(); initialSpace = nil; initialFocus = nil; hoverStore = nil; sourceStore = nil; committed = false; dropInProgress = false; gestureDriven = false
        presentation.point = nil; presentation.item = nil; presentation.title = ""
    }
    func didCommit() {
        committed = true
        if let source = BrowserDragRegistry.source, source !== self { source.committed = true; source.finish(cancelled: false) }
        finish(cancelled: false)
    }
}

extension View {
    func browserDragViewport() -> some View { modifier(BrowserDragViewport()) }
    func browserDragCoordinateSpace(store: BrowserStore) -> some View {
        coordinateSpace(name: "curveDrag")
            .background(BrowserDragCoordinates(store: store, drag: store.drag))
            .onPreferenceChange(BrowserDropFramesKey.self) { store.drag.updateDropFrames($0) }
            .overlay(alignment: .topLeading) { BrowserFloatingDragPreview(presentation: store.drag.presentation).allowsHitTesting(false) }
    }
    func browserDragSource(_ item: BrowserDragItem, store: BrowserStore) -> some View {
        modifier(BrowserDragSource(item: item, store: store, drag: store.drag))
    }
    func browserDropTarget(_ target: BrowserDropTarget, store: BrowserStore, axis: Axis = .vertical) -> some View {
        modifier(BrowserDropZone(destination: target, store: store, drag: store.drag, axis: axis))
    }
}

private struct BrowserDragCoordinates: NSViewRepresentable {
    let store: BrowserStore
    let drag: BrowserDragSession
    func makeNSView(context: Context) -> BrowserDragCoordinateView {
        let view = BrowserDragCoordinateView(); drag.registerCoordinateView(view, store: store); return view
    }
    func updateNSView(_ view: BrowserDragCoordinateView, context: Context) { drag.registerCoordinateView(view, store: store) }
}
private final class BrowserDragCoordinateView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct BrowserDragSource: ViewModifier {
    let item: BrowserDragItem
    @ObservedObject var store: BrowserStore
    @ObservedObject var drag: BrowserDragSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var gestureActive = false
    @State private var gestureToken: UUID?
    func body(content: Content) -> some View {
        content.opacity(drag.isSource(item) ? 0.42 : 1)
            .animation(.easeOut(duration: reduceMotion ? 0 : 0.13), value: drag.isSource(item))
            .simultaneousGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("curveDrag"))
                .updating($gestureActive) { _, active, _ in active = true }
                .onChanged { value in
                    if gestureToken == nil { gestureToken = drag.beginGesture(item, store: store) }
                    if let gestureToken { drag.updateGesture(at: value.location, token: gestureToken) }
                }
                .onEnded { value in
                    guard let token = gestureToken else { return }; gestureToken = nil
                    drag.endGesture(at: value.location, token: token)
                })
            .onChange(of: gestureActive) { _, active in
                if !active {
                    let token = gestureToken
                    DispatchQueue.main.async { if !gestureActive && gestureToken == token { gestureToken = nil } }
                }
            }
    }
}
private struct BrowserFloatingDragPreview: View {
    @ObservedObject var presentation: BrowserDragPresentation
    private var symbol: String { switch presentation.item { case .tab: return "globe"; case .folder: return "folder.fill"; case .space: return "square.stack.3d.up"; case nil: return "globe" } }
    var body: some View {
        if let point = presentation.point, presentation.item != nil {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                Text(presentation.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }.padding(.horizontal, 13).frame(width: 215, height: 36, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.8)))
                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                .offset(x: point.x + 12, y: point.y + 12)
        }
    }
}

private struct BrowserDropZone: ViewModifier {
    let destination: BrowserDropTarget
    @ObservedObject var store: BrowserStore
    @ObservedObject var drag: BrowserDragSession
    let axis: Axis
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.browserDragViewport) private var viewport
    @State private var size: CGSize = .zero
    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geometry in
                Color.clear
                    .preference(key: BrowserDropFramesKey.self, value: [BrowserDropFrame(target: destination, rect: geometry.frame(in: .named("curveDrag")), axis: axis, viewport: viewport)])
                    .onAppear { size = geometry.size }.onChange(of: geometry.size) { _, value in size = value }
            })
            .overlay {
                if drag.isTarget(destination) {
                    if drag.position != .inside && isInsertion {
                        if axis == .horizontal {
                            Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: drag.position == .before ? .leading : .trailing)
                                .allowsHitTesting(false)
                        } else {
                            Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 6)
                                .frame(maxHeight: .infinity, alignment: drag.position == .before ? .top : .bottom)
                                .allowsHitTesting(false)
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1.5))
                            .allowsHitTesting(false)
                    }
                }
            }
            .onDrop(of: [UTType.curveDrag, .curveTab, .curveFolder, .curveSpace, .url, .utf8PlainText], delegate: BrowserDropDelegate(destination: destination, store: store, drag: drag, size: size, axis: axis))
            .animation(.easeOut(duration: reduceMotion ? 0 : 0.10), value: drag.target)
            .animation(.easeOut(duration: reduceMotion ? 0 : 0.10), value: drag.position)
    }
    private var isInsertion: Bool {
        switch destination { case .tab, .folder, .space: return true; default: return false }
    }
}

private struct BrowserDropDelegate: DropDelegate {
    let destination: BrowserDropTarget
    let store: BrowserStore
    let drag: BrowserDragSession
    let size: CGSize
    let axis: Axis
    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            let allowed: Bool
            if let item = drag.knownPayload?.item { allowed = permitted(item, position: dropPosition(info)) }
            else { allowed = info.hasItemsConforming(to: [.curveDrag, .url, .utf8PlainText]) }
            drag.trace("validate \(destination) allowed=\(allowed)")
            return allowed
        }
    }
    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            drag.trace("entered \(destination) \(dropPosition(info))")
            drag.hover(destination, position: dropPosition(info), store: store)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            let position = dropPosition(info)
            drag.traceUpdate(destination, position: position)
            guard drag.knownPayload.map({ permitted($0.item, position: position) }) ?? true else { return DropProposal(operation: .forbidden) }
            drag.hover(destination, position: position, store: store)
            return DropProposal(operation: drag.knownSourceStore === store ? .move : .copy)
        }
    }
    func dropExited(info: DropInfo) { MainActor.assumeIsolated { drag.trace("exited \(destination)"); drag.exit(destination) } }
    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            let position = dropPosition(info)
            drag.trace("drop \(destination) \(position) known=\(drag.knownPayload != nil)")
            drag.prepareForDrop()
            if let payload = drag.knownPayload {
                let source = drag.knownSourceStore
                let success = store.commitDrop(payload, from: source, on: destination, position: position)
                if success { drag.didCommit() } else { drag.cancelDrop() }
                return success
            }
            guard let provider = info.itemProviders(for: [.curveDrag, .url, .utf8PlainText]).first else { drag.cancelDrop(); return false }
            if provider.hasItemConformingToTypeIdentifier(UTType.curveDrag.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.curveDrag.identifier) { data, _ in
                    Task { @MainActor in
                        guard let data, let payload = try? JSONDecoder().decode(BrowserDragPayload.self, from: data) else { drag.cancelDrop(); return }
                        if drag.importPayload(payload, store: store, on: destination, position: position) { drag.didCommit() }
                        else { drag.cancelDrop() }
                    }
                }
                return true
            }
            let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url.identifier : UTType.utf8PlainText.identifier
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                Task { @MainActor in
                    let text: String?
                    if let url = value as? URL { text = url.absoluteString }
                    else if let url = value as? NSURL { text = url.absoluteString }
                    else if let string = value as? String { text = string }
                    else if let data = value as? Data { text = String(data: data, encoding: .utf8) }
                    else { text = nil }
                    guard let text, store.dropExternalURL(text, on: destination, position: position) else { drag.cancelDrop(); return }
                    drag.didCommit()
                }
            }
            return true
        }
    }
    @MainActor private func permitted(_ item: BrowserDragItem, position: BrowserDropPosition) -> Bool {
        if let source = drag.knownSourceStore, source !== store {
            switch (item, destination) {
            case (.tab, _): return true
            case (.folder, .folder), (.folder, .pinned), (.folder, .space), (.space, .space): return true
            default: return false
            }
        }
        return store.canDrop(item, on: destination, position: position)
    }
    private func dropPosition(_ info: DropInfo) -> BrowserDropPosition {
        let value = axis == .horizontal ? info.location.x : info.location.y
        let length = max(1, axis == .horizontal ? size.width : size.height)
        switch destination {
        case .tab: return value < length / 2 ? .before : .after
        case .folder:
            if case .folder = MainActor.assumeIsolated({ drag.knownPayload?.item }) {} else { return .inside }
            if value < length * 0.23 { return .before }
            if value > length * 0.77 { return .after }
            return .inside
        case .space:
            if case .space = MainActor.assumeIsolated({ drag.knownPayload?.item }) { return value < length / 2 ? .before : .after }
            return .inside
        default: return .inside
        }
    }
}
