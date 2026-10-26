import SwiftUI
import AppKit
import WebKit
import BrowserCore
import UniformTypeIdentifiers

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0xBFCBE4
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct BrowserView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var engine: WebEngine
    @ObservedObject private var drag: BrowserDragSession
    @StateObject private var chrome = WindowChrome()
    @State private var showLaunch = false
    init(store: BrowserStore, engine: WebEngine) { self.store = store; self.engine = engine; self.drag = store.drag }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resizing = false
    @State private var sidebarStart: Double = 0
    @State private var hoverReveal = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                ArcThemeBackdrop(space: store.activeSpace).ignoresSafeArea().animation(.easeInOut(duration: reduceMotion ? 0.08 : 0.38), value: store.activeSpace.theme).animation(.easeInOut(duration: reduceMotion ? 0.08 : 0.38), value: store.activeSpace.colorHex)
                HStack(spacing: 0) {
                    if store.state.sidebarVisible {
                        Sidebar(store: store, engine: engine)
                            .frame(width: store.state.sidebarWidth)
                            .transition(BrowserMotion.sidebar(reduceMotion: reduceMotion))
                        Rectangle().fill(Color.clear).frame(width: 4)
                            .contentShape(Rectangle())
                            .onHover { over in if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("curveDrag")).onChanged { value in
                                if !resizing { sidebarStart = store.state.sidebarWidth; resizing = true }
                                store.state.sidebarWidth = min(360, max(224, sidebarStart + value.translation.width))
                            }.onEnded { value in
                                store.state.sidebarWidth = min(360, max(224, sidebarStart + value.translation.width))
                                resizing = false; store.saveSoon()
                            })
                    }
                    pageArea
                        .padding(.trailing, 8).padding(.vertical, 8)
                        .padding(.leading, store.state.sidebarVisible ? 0 : 8)
                }
                if !store.state.sidebarVisible {
                    HStack {
                        Color.clear.frame(width: chrome.isFullScreen ? 0 : 72, height: 30)
                        IconButton("sidebar.left", help: "Show Sidebar · ⌘S") { withAnimation(BrowserMotion.animation(reduceMotion: reduceMotion)) { store.state.sidebarVisible = true }; store.saveSoon() }
                        Spacer()
                    }.padding(.top, 11).padding(.leading, 12)
                }
                if !store.state.sidebarVisible {
                    HStack(spacing: 0) {
                        if hoverReveal {
                            Sidebar(store: store, engine: engine)
                                .frame(width: store.state.sidebarWidth)
                                .background(ArcThemeBackdrop(space: store.activeSpace))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .shadow(color: .black.opacity(0.18), radius: 12, x: 5)
                                .onHover { over in if !over { withAnimation(BrowserMotion.quick(reduceMotion: reduceMotion)) { hoverReveal = false } } }
                        } else {
                            Color.clear.frame(width: 9).contentShape(Rectangle()).onHover { over in if over { withAnimation(BrowserMotion.quick(reduceMotion: reduceMotion)) { hoverReveal = true } } }
                        }
                        Spacer(minLength: 0)
                    }
                }
                if let peek = store.peek {
                    Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { store.dismissPeek() }
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            IconButton("xmark", help: "Close Peek · Esc") { store.dismissPeek() }
                            Text(engine.state(id: peek.id).url.isEmpty ? (peek.url.host ?? "Peek") : (URL(string: engine.state(id: peek.id).url)?.host ?? "Peek")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Open in Split") { store.expandPeek(split: true) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                            IconButton("arrow.up.left.and.arrow.down.right", help: "Expand to Tab") { store.expandPeek() }
                        }.padding(12).background(.regularMaterial)
                        ZStack {
                            WebContentView(webView: engine.webView(for: peek.id, url: peek.url))
                            if let error = engine.state(id: peek.id).error {
                                VStack(spacing: 12) {
                                    Image(systemName: "wifi.exclamationmark").font(.title)
                                    Text("This page couldn’t load").font(.headline)
                                    Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 330)
                                    Button("Try Again") { engine.reload(peek.id) }.buttonStyle(.bordered)
                                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
                            }
                        }
                    }
                    .background(Color(nsColor: .windowBackgroundColor)).foregroundStyle(.primary).clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.5)))
                    .shadow(color: .black.opacity(0.25), radius: 40, y: 14)
                    .frame(width: max(500, geometry.size.width * 0.78), height: max(400, geometry.size.height * 0.83))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .transition(BrowserMotion.peek(reduceMotion: reduceMotion))
                }
                if store.paletteVisible {
                    Color.black.opacity(0.10).ignoresSafeArea().onTapGesture { store.paletteVisible = false }
                    CommandPalette(store: store).transition(BrowserMotion.palette(reduceMotion: reduceMotion)).frame(width: min(620, geometry.size.width - 80)).padding(.top, max(75, geometry.size.height * 0.15)) }
                if showLaunch {
                    LaunchBloom(reduceMotion: reduceMotion)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity).zIndex(5)
                }
                if let toast = store.toast {
                    Text(toast).font(.system(size: 12, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule()).shadow(color: .black.opacity(0.1), radius: 10, y: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 26).allowsHitTesting(false)
                }
            }
            .animation(BrowserMotion.animation(reduceMotion: reduceMotion), value: store.state.sidebarVisible)
            .animation(BrowserMotion.animation(reduceMotion: reduceMotion), value: store.paletteVisible)
            .animation(BrowserMotion.animation(reduceMotion: reduceMotion), value: store.peek?.id)
            .foregroundStyle(ArcThemeBackdrop.ink(for: store.activeSpace))
            .clipShape(RoundedRectangle(cornerRadius: chrome.isFullScreen ? 0 : 12))
            .sheet(isPresented: $store.historyVisible) { HistoryPanel(store: store) }
            .sheet(isPresented: $store.archiveVisible) { ArchivePanel(store: store) }
            .sheet(isPresented: $store.settingsVisible) { SettingsPanel(store: store, engine: engine) }
            .sheet(isPresented: $store.helpVisible) { ShortcutsPanel() }
            .sheet(isPresented: $store.downloadsVisible) { DownloadsPanel(engine: engine) }
        }
        .browserDragCoordinateSpace(store: store)
        .frame(minWidth: minimumWidth, minHeight: 520)
        .background(WindowSetup(store: store, chrome: chrome))
        .environment(\.browserFullscreen, chrome.isFullScreen)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(ArcThemeBackdrop.isDark(for: store.activeSpace) ? .dark : .light)
        .onAppear {
            store.trim()
            if BrowserLaunchPresentation.claim() {
                showLaunch = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: reduceMotion ? 120_000_000 : 520_000_000)
                    withAnimation(.easeOut(duration: reduceMotion ? 0.08 : 0.24)) { showLaunch = false }
                }
            }
        }
        .onChange(of: store.state.selectedTabID) { _, _ in store.trim() }
    }

    private var minimumWidth: CGFloat {
        let base: CGFloat = store.mode == .little ? 500 : 760
        return store.splitID != nil && !store.activeSpace.splitVertical ? max(base, (store.state.sidebarVisible ? store.state.sidebarWidth + 4 : 8) + 492) : base
    }

    @ViewBuilder private var pageArea: some View {
        Group {
            if let selected = store.selectedTab {
                if let splitID = store.splitID, splitID != selected.id, let second = store.state.tabs.first(where: { $0.id == splitID }) {
                    if store.activeSpace.splitVertical {
                        VSplitView {
                            WebPane(store: store, engine: engine, tab: selected, isSplit: true).frame(minHeight: 180)
                            WebPane(store: store, engine: engine, tab: second, isSplit: true).frame(minHeight: 180)
                        }
                    } else {
                        HSplitView {
                            WebPane(store: store, engine: engine, tab: selected, isSplit: true).frame(minWidth: 240)
                            WebPane(store: store, engine: engine, tab: second, isSplit: true).frame(minWidth: 240)
                        }
                    }
                } else { WebPane(store: store, engine: engine, tab: selected, isSplit: false) }
            } else { StartPage(store: store) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.black.opacity(0.07)))
        .shadow(color: .black.opacity(0.09), radius: 6, y: 2)
        .overlay {
            HStack(spacing: 12) {
                splitDropZone(.splitLeft, label: "Split Left", symbol: "rectangle.lefthalf.inset.filled")
                splitDropZone(.splitRight, label: "Split Right", symbol: "rectangle.righthalf.inset.filled")
            }.padding(14)
                .opacity(drag.activeTabID == nil ? 0 : 1)
                .allowsHitTesting(drag.activeTabID != nil)
                .accessibilityHidden(drag.activeTabID == nil)
                .animation(BrowserMotion.quick(reduceMotion: reduceMotion), value: drag.activeTabID != nil)
        }
    }
    private func splitDropZone(_ target: BrowserDropTarget, label: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light))
            Text(label).font(.system(size: 13, weight: .medium))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
            .browserDropTarget(target, store: store)
    }
}

struct Sidebar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.browserFullscreen) private var fullscreen
    @ObservedObject var store: BrowserStore
    @ObservedObject var engine: WebEngine
    @Namespace private var selection
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                WindowDragRegion()
                HStack(spacing: 0) {
                    if !fullscreen { Color.clear.frame(width: 66) }
                    IconButton("sidebar.left", help: "Hide Sidebar · ⌘S") { store.state.sidebarVisible = false; store.saveSoon() }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    IconButton("arrow.left", help: "Back · ⌘[") { if let id = store.currentID { engine.goBack(id) } }.disabled(!page.canGoBack)
                    IconButton("arrow.right", help: "Forward · ⌘]") { if let id = store.currentID { engine.goForward(id) } }.disabled(!page.canGoForward)
                    IconButton(page.isLoading ? "xmark" : "arrow.clockwise", help: "Reload · ⌘R") {
                        if let id = store.currentID { if page.isLoading { engine.stop(id) } else { engine.reload(id) } }
                    }
                }
            }.padding(.leading, 12).padding(.trailing, 6).frame(height: 44)
            Button { store.showPalette(.navigate) } label: {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
                    Text(address).lineLimit(1).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Text("⌘L").font(.system(size: 10)).opacity(0.45)
                }.foregroundStyle(.primary.opacity(0.55)).padding(.horizontal, 12).frame(height: 36)
                    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(ChromePressStyle()).help("Search or Enter URL · ⌘L").padding(.horizontal, 10)
            if !store.favorites.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(4, store.favorites.count)), spacing: 6) {
                    ForEach(store.favorites) { tab in
                        Button { store.select(tab.id) } label: {
                            SiteIcon(url: tab.url, size: 23).frame(maxWidth: .infinity).frame(height: 48)
                                .background(.white.opacity(store.state.selectedTabID == tab.id ? 0.6 : 0.23), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(ChromePressStyle()).help(tab.title)
                            .contextMenu { TabContextMenu(store: store, tab: tab) }
                            .browserDragSource(.tab(tab.id), store: store)
                            .browserDropTarget(.tab(tab.id), store: store, axis: .horizontal)
                    }
                }.padding(.horizontal, 11).padding(.top, 12)
                    .browserDropTarget(.favorites, store: store)
            }
            HStack(spacing: 8) {
                Text(store.activeSpace.emoji).font(.system(size: 17))
                Text(store.activeSpace.name).font(BrowserType.titleLabel()).lineLimit(1)
                Spacer()
                Menu {
                    Button("Rename Space…") { store.renameSpace() }
                    Button("New Folder…") { store.addFolder() }
                    Button("New Space…") { store.addSpace() }
                    Divider()
                    Button("Customize Space…") { store.settingsVisible = true }
                    Button("Change Icon…") { store.editSpaceIcon(store.state.activeSpaceID) }
                    Button("Duplicate Space") { store.duplicateSpace(store.state.activeSpaceID) }
                    Button("Remove Space") { store.removeSpace(store.state.activeSpaceID) }.disabled(store.state.spaces.count < 2)
                } label: { Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }.padding(.horizontal, 17).padding(.top, 17).padding(.bottom, 9)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.pinned.filter { $0.folderID == nil }) { tab in
                        TabRow(store: store, engine: engine, tab: tab, selection: selection).transition(BrowserMotion.tab(reduceMotion: reduceMotion))
                    }
                    ForEach(store.folders.filter { folder in
                        let parts = folder.name.components(separatedBy: " / ")
                        let parent = parts.dropLast().joined(separator: " / ")
                        return parts.count == 1 || !store.folders.contains(where: { $0.name == parent })
                    }) { folder in FolderBranch(store: store, engine: engine, folder: folder, selection: selection) }
                    Color.clear.frame(height: 16).contentShape(Rectangle()).browserDropTarget(.pinned, store: store)
                    Rectangle().fill(.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 8).padding(.bottom, 7)
                    HStack {
                        Text("Today").font(.system(size: 10, weight: .medium)).foregroundStyle(.primary.opacity(0.38))
                        Spacer()
                        if !store.today.isEmpty {
                            Button("Clear") { store.clearToday() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.primary.opacity(0.4)).help("Move Today’s tabs to Archive")
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 3)
                    ForEach(store.today) { tab in
                        TabRow(store: store, engine: engine, tab: tab, selection: selection).transition(BrowserMotion.tab(reduceMotion: reduceMotion))
                    }
                    Button { store.showPalette(.newTab) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "plus").font(.system(size: 16, weight: .regular)).frame(width: 18)
                            Text("New Tab").font(BrowserType.sidebar())
                            Spacer()
                            Text("⌘T").font(.system(size: 10)).opacity(0.5)
                        }.foregroundStyle(.primary.opacity(0.43)).padding(.horizontal, 10).frame(height: 36).contentShape(Rectangle())
                    }.buttonStyle(ChromePressStyle())
                    Color.clear.frame(minHeight: 48).contentShape(Rectangle()).browserDropTarget(.today, store: store)
                }.padding(.horizontal, 7)
                    .animation(BrowserMotion.animation(reduceMotion: reduceMotion), value: store.today.map(\.id))
                    .animation(BrowserMotion.animation(reduceMotion: reduceMotion), value: store.pinned.map(\.id))
            }.scrollIndicators(.hidden).browserDragViewport()
            HStack(spacing: 4) {
                Menu {
                    Button("Import from Arc…") { store.importArc() }
                    Button("History", systemImage: "clock") { store.performKeyAction(.history) }
                    Button("Archive", systemImage: "archivebox") { store.archiveVisible = true }
                    Button("Downloads", systemImage: "arrow.down.circle") { store.downloadsVisible = true }
                    Divider()
                    Button("Settings…") { store.settingsVisible = true }
                    Button("Keyboard Shortcuts") { store.helpVisible = true }
                } label: { Image(systemName: "square.grid.2x2").font(.system(size: 15)).frame(width: 25, height: 30) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Library")
                Spacer(minLength: 1)
                HStack(spacing: 3) {
                    ForEach(Array(store.state.spaces.prefix(visibleSpaceCount).enumerated()), id: \.element.id) { index, space in spaceButton(space, index: index) }
                    if store.state.spaces.count > visibleSpaceCount {
                        Menu {
                            ForEach(Array(store.state.spaces.dropFirst(visibleSpaceCount))) { space in Button("\(space.emoji)  \(space.name)") { store.switchSpace(space.id) } }
                        } label: { Image(systemName: "ellipsis").frame(width: 18, height: 30) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }.frame(height: 30)
                Spacer(minLength: 1)
                Menu {
                    Button("New Tab") { store.showPalette(.newTab) }
                    Button("New Folder…") { store.addFolder() }
                    Button("New Space…") { store.addSpace() }
                    Button("Add Split View…") { store.showPalette(.split) }
                } label: { Image(systemName: "plus").font(.system(size: 17)).frame(width: 24, height: 30) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Create")
            }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 9)
        }.accessibilityIdentifier("browser.sidebar")
    }
    private func spaceButton(_ space: BrowserSpace, index: Int) -> some View {
        Button { withAnimation(BrowserMotion.quick(reduceMotion: reduceMotion)) { store.switchSpace(space.id) } } label: {
            VStack(spacing: 2) {
                Text(space.emoji).font(.system(size: 15)).frame(width: 18, height: 23)
                Circle().fill(.primary.opacity(store.state.activeSpaceID == space.id ? 0.65 : 0)).frame(width: 3, height: 3)
            }.opacity(store.state.activeSpaceID == space.id ? 1 : 0.5)
        }.buttonStyle(ChromePressStyle()).help("\(space.name) · ⌃\(index + 1)")
            .contextMenu { SpaceContextMenu(store: store, space: space) }
            .browserDragSource(.space(space.id), store: store)
            .browserDropTarget(.space(space.id), store: store, axis: .horizontal)
    }
    private var visibleSpaceCount: Int { store.state.spaces.count <= 6 ? min(6, max(3, Int((store.state.sidebarWidth - 83) / 21))) : min(6, max(3, Int((store.state.sidebarWidth - 105) / 21))) }
    private var page: WebPageState { engine.state(id: store.currentID ?? UUID()) }
    private var address: String {
        guard let tab = store.state.tabs.first(where: { $0.id == store.currentID }), !tab.url.hasPrefix("curve:") else { return "Search or Enter URL…" }
        return URL(string: tab.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? tab.url
    }
}

struct TabRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: BrowserStore
    @ObservedObject var engine: WebEngine
    let tab: BrowserTab
    let selection: Namespace.ID
    @State private var hovering = false
    private var selected: Bool { store.state.selectedTabID == tab.id || store.splitID == tab.id }
    var body: some View {
        HStack(spacing: 9) {
            if engine.state(id: tab.id).isLoading { ProgressView().controlSize(.mini).frame(width: 18, height: 18) }
            else { SiteIcon(url: tab.url, size: 17).onTapGesture { if tab.kind != .today { store.reset(tab.id) } else { store.select(tab.id) } } }
            Text(tab.title.isEmpty ? "New Tab" : tab.title).font(BrowserType.sidebar(selected: selected)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if hovering {
                Button { store.close(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 23).contentShape(Rectangle()) }.buttonStyle(.plain).help(tab.kind == .today ? "Archive Tab" : "Close / Reset Pinned Tab")
            } else if store.splitID == tab.id { Image(systemName: "rectangle.split.2x1").font(.system(size: 10)).opacity(0.5) }
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background {
            if store.state.selectedTabID == tab.id {
                RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.52)).matchedGeometryEffect(id: "selected-tab", in: selection)
            } else { RoundedRectangle(cornerRadius: 7).fill(.white.opacity(selected ? 0.3 : hovering ? 0.18 : 0)) }
        }
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(selected ? 0.22 : 0)))
        .contentShape(Rectangle()).onTapGesture { store.select(tab.id) }.onHover { hovering = $0 }
        .contextMenu { TabContextMenu(store: store, tab: tab) }
        .browserDragSource(.tab(tab.id), store: store)
        .browserDropTarget(.tab(tab.id), store: store)
        .animation(BrowserMotion.animation(reduceMotion: reduceMotion), value: store.state.selectedTabID)
        .animation(BrowserMotion.quick(reduceMotion: reduceMotion), value: hovering)
        .help(tab.url).accessibilityElement(children: .combine).accessibilityLabel(tab.title).accessibilityAddTraits(.isButton)
    }
}

struct TabContextMenu: View {
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab
    var body: some View {
        Button(tab.kind == .pinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(tab.id) }
        Button(tab.kind == .favorite ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(tab.id) }
        Button("Rename…") { store.rename(tab.id) }
        Button("Duplicate") { store.duplicate(tab.id) }
        Button("Open in Split View") { store.setSplit(tab.id) }.disabled(store.state.selectedTabID == tab.id)
        if tab.kind != .today {
            Button("Reset to Pinned Address") { store.reset(tab.id) }
            Button("Replace Pinned Address") { store.replacePin(tab.id) }
        }
        Menu("Move to Space") { ForEach(store.state.spaces) { space in Button("\(space.emoji)  \(space.name)") { store.move(tab.id, space: space.id) } } }
        if !store.folders.isEmpty {
            Menu("Move to Folder") {
                Button("Outside Folder") { store.move(tab.id, space: tab.spaceID) }
                ForEach(store.folders) { folder in Button(folder.name) { store.move(tab.id, space: folder.spaceID, folder: folder.id) } }
            }
        }
        Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(tab.url, forType: .string) }
        Divider()
        Button(tab.kind == .today ? "Archive Tab" : "Remove Tab") { store.close(tab.id, remove: true) }
    }
}

struct ChromePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconButton: View {
    let symbol: String
    var help = ""
    var action: () -> Void
    init(_ symbol: String, help: String = "", action: @escaping () -> Void) { self.symbol = symbol; self.help = help; self.action = action }
    @State private var hover = false
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 25, height: 27).contentShape(Rectangle()).background(.black.opacity(hover ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 5)) }
            .buttonStyle(ChromePressStyle()).foregroundStyle(.primary.opacity(0.65)).onHover { hover = $0 }.help(help)
    }
}

struct SiteIcon: View {
    var url: String
    var size: CGFloat = 18
    private var host: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? "" }
    private var symbol: String? {
        if url.hasPrefix("curve:") { return "circle.hexagongrid" }
        if host.contains("apple") { return "apple.logo" }
        if host.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if host.contains("youtube") { return "play.rectangle.fill" }
        if host.contains("mail") { return "envelope.fill" }
        if host.contains("arena") || host.contains("are.na") { return "asterisk" }
        return nil
    }
    private var hue: Double { Double(host.utf8.reduce(0) { ($0 + Int($1)) % 360 }) / 360 }
    var body: some View {
        ZStack {
            if let symbol { Image(systemName: symbol).font(.system(size: size * 0.79, weight: .medium)).foregroundStyle(Color(hue: hue, saturation: 0.32, brightness: 0.36)) }
            else {
                RoundedRectangle(cornerRadius: size * 0.23).fill(Color(hue: hue, saturation: 0.24, brightness: 0.57))
                Text(String(host.first ?? "↗").uppercased()).font(.system(size: size * 0.64, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct WindowSetup: NSViewRepresentable {
    @ObservedObject var store: BrowserStore
    @ObservedObject var chrome: WindowChrome
    final class Coordinator {
        var observer: NSObjectProtocol?
        var closeObserver: NSObjectProtocol?
        weak var preparedWindow: NSWindow?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window, coordinator: context.coordinator) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { DispatchQueue.main.async { configure(view.window, coordinator: context.coordinator) } }
    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden; window.backgroundColor = .clear; window.isMovableByWindowBackground = false
        let base: CGFloat = store.mode == .little ? 500 : 760
        let width: CGFloat = store.splitID != nil && !store.activeSpace.splitVertical ? max(base, (store.state.sidebarVisible ? store.state.sidebarWidth + 4 : 8) + 492) : base
        window.minSize = NSSize(width: width, height: 520)
        store.window = window
        chrome.attach(window)
        if coordinator.preparedWindow !== window {
            coordinator.preparedWindow = window
            // A newly opened hidden-titlebar window can arrive before SwiftUI's
            // first layout. Complete that pass once, including native page hosts.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                window.contentView?.needsLayout = true
                window.contentView?.layoutSubtreeIfNeeded()
                window.contentView?.needsDisplay = true
                window.displayIfNeeded()
            }
        }
        if window.isKeyWindow { BrowserCoordinator.shared.activeStore = store; BrowserCoordinator.shared.consumePendingURLs(in: store) }
        if coordinator.closeObserver == nil {
            coordinator.closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak store] _ in
                MainActor.assumeIsolated { store?.shutdown() }
            }
        }
        if coordinator.observer == nil {
            coordinator.observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak store] _ in
                MainActor.assumeIsolated { BrowserCoordinator.shared.activeStore = store }
            }
        }
    }
}

/// A small native drag surface leaves buttons and web content in charge of their own clicks.
struct WindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct SpaceContextMenu: View {
    @ObservedObject var store: BrowserStore
    let space: BrowserSpace
    private let colors: [(String, String)] = [("Lavender", "BDB6DD"), ("Sky", "A9CADD"), ("Sage", "B9D5C3"), ("Peach", "E7C4AE"), ("Rose", "DDBDCF"), ("Slate", "BDC7D5"), ("Sea Glass", "B2D8D6")]
    var body: some View {
        Button("Switch to \(space.name)") { store.switchSpace(space.id) }
        Divider()
        Button("Rename…") { store.editSpaceName(space.id) }
        Button("Change Icon…") { store.editSpaceIcon(space.id) }
        Menu("Change Color") { ForEach(colors, id: \.0) { name, hex in Button(name) { store.changeSpaceColor(space.id, hex: hex) } } }
        Button("Duplicate Space") { store.duplicateSpace(space.id) }
        Divider()
        Button("Remove Space") { store.removeSpace(space.id) }.disabled(store.state.spaces.count < 2)
    }
}


/// Imported Arc folder paths retain their original identities and render as a
/// native disclosure tree. Only expanded branches build their rows.
struct FolderBranch: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var engine: WebEngine
    let folder: BrowserFolder
    let selection: Namespace.ID
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var children: [BrowserFolder] {
        store.folders.filter { child in
            let parts = child.name.components(separatedBy: " / ")
            return parts.count > 1 && parts.dropLast().joined(separator: " / ") == folder.name
        }
    }
    private var tabs: [BrowserTab] { store.pinned.filter { $0.folderID == folder.id } }
    private var title: String { folder.name.components(separatedBy: " / ").last ?? folder.name }
    var body: some View {
        VStack(spacing: 4) {
            Button { withAnimation(BrowserMotion.animation(reduceMotion: reduceMotion)) { store.toggleFolder(folder.id) } } label: {
                HStack(spacing: 9) {
                    ZStack {
                        Image(systemName: "folder").font(.system(size: 16, weight: .medium)).opacity(hovering ? 0 : 1)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(folder.isExpanded ? 90 : 0)).opacity(hovering ? 1 : 0)
                    }.frame(width: 18)
                    Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 10).frame(height: 36).contentShape(Rectangle())
                    .background(.white.opacity(hovering ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(ChromePressStyle()).help(folder.name).onHover { hovering = $0 }
                .contextMenu {
                    Button("Open First Tab") { store.openFolder(folder.id) }
                    Button("New Folder Inside…") { store.addFolder(parentID: folder.id) }
                    Button("Rename…") { store.renameFolder(folder.id) }
                    Button("Remove Folder, Keep Tabs") { store.removeFolder(folder.id) }
                }
                .browserDragSource(.folder(folder.id), store: store)
                .browserDropTarget(.folder(folder.id), store: store)
            if folder.isExpanded {
                VStack(spacing: 4) {
                    ForEach(tabs) { tab in TabRow(store: store, engine: engine, tab: tab, selection: selection) }
                    ForEach(children) { child in AnyView(FolderBranch(store: store, engine: engine, folder: child, selection: selection)) }
                }.padding(.leading, 18).transition(BrowserMotion.tab(reduceMotion: reduceMotion))
            }
        }.animation(BrowserMotion.quick(reduceMotion: reduceMotion), value: hovering)
    }
}
