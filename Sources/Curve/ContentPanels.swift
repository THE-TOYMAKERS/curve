import SwiftUI
import AppKit
import WebKit
import BrowserCore

struct WebPane: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var engine: WebEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.browserFullscreen) private var fullscreen
    let tab: BrowserTab
    let isSplit: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !tab.url.hasPrefix("curve:") && (isSplit || !store.state.sidebarVisible) {
                HStack(spacing: 6) {
                    if !store.state.sidebarVisible && !fullscreen { Spacer().frame(width: 92) }
                    if isSplit { SiteIcon(url: tab.url, size: 14) }
                    Spacer(minLength: 0)
                    Button { store.focusedPane = tab.id; store.showPalette(.navigate) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.url.hasPrefix("https:") ? "lock" : "globe").font(.system(size: 9))
                            Text(URL(string: tab.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? tab.title)
                                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        }.foregroundStyle(.primary.opacity(0.48)).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Edit address · ⌘L")
                    Spacer(minLength: 0)
                    if isSplit {
                        IconButton("rectangle.split.1x2", help: "Rotate Split View") { store.toggleSplitOrientation() }
                        IconButton("xmark", help: "Close Split View · ⌃⇧−") { store.setSplit(nil) }
                    } else {
                        IconButton("rectangle.split.2x1", help: "Add Split View · ⌃⇧+") { store.showPalette(.split) }
                    }
                }
                .padding(.horizontal, 9).frame(height: 34)
                .background(WindowDragRegion()).background(Color(nsColor: .windowBackgroundColor))
            }
            ZStack(alignment: .topTrailing) {
                page
                if store.findVisible && store.currentID == tab.id {
                    findBar
                        .padding(8)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                        .zIndex(2)
                }
            }
            .overlay(alignment: .topLeading) {
                if engine.state(id: tab.id).isLoading && !tab.url.hasPrefix("curve:") {
                    GeometryReader { geometry in
                        Rectangle().fill(Color(hex: store.activeSpace.colorHex).opacity(0.9))
                            .frame(width: max(8, geometry.size.width * engine.state(id: tab.id).progress), height: 2)
                    }.frame(height: 2).allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { store.focusedPane = tab.id })
        }
        .foregroundStyle(Color.primary)
        .animation(BrowserMotion.quick(reduceMotion: reduceMotion), value: store.findVisible)
    }

    @ViewBuilder private var page: some View {
        ZStack {
            if tab.url.hasPrefix("curve:") { StartPage(store: store) }
            else if let url = URL(string: tab.url), ["https", "http"].contains(url.scheme ?? "") {
                WebContentView(webView: engine.webView(for: tab.id, url: url)).id(tab.id)
            } else {
                ContentUnavailableView("This address can’t be opened", systemImage: "globe", description: Text(tab.url))
            }
            if let error = store.errors[tab.id] {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text("This page couldn’t load").font(.system(size: 17, weight: .semibold))
                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    Button("Try Again") { store.errors[tab.id] = nil; engine.reload(tab.id) }.buttonStyle(.bordered)
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            FocusTextField(text: $store.findQuery, placeholder: "Find in page", fontSize: 13,
                           selectAllOnFocus: true, focusToken: store.findFocus,
                           onSubmit: { engine.find(id: tab.id, query: store.findQuery, backwards: false) },
                           onEscape: { store.findVisible = false; engine.clearFind(id: tab.id) })
                .frame(minWidth: 65, maxWidth: .infinity).frame(height: 24)
                .onChange(of: store.findQuery) { _, query in engine.find(id: tab.id, query: query, backwards: false) }
                .accessibilityIdentifier("browser.findField")
            Rectangle().fill(.primary.opacity(0.10)).frame(width: 1, height: 17).padding(.horizontal, 2)
            IconButton("chevron.up", help: "Previous Match · ⇧⌘G") { engine.find(id: tab.id, query: store.findQuery, backwards: true) }
            IconButton("chevron.down", help: "Next Match · ⌘G") { engine.find(id: tab.id, query: store.findQuery, backwards: false) }
            IconButton("xmark", help: "Close Find · Esc") { store.findVisible = false; engine.clearFind(id: tab.id) }
        }
        .padding(.horizontal, 10).frame(maxWidth: 350).frame(height: 38)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.black.opacity(0.09)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 3)
    }
}

/// Arc leaves a quiet canvas behind its command bar. Keep typography at native
/// point sizes so maximising a window never turns this into a marketing page.
struct StartPage: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color(hex: store.activeSpace.colorHex).opacity(0.12), .clear],
                           center: .center, startRadius: 10, endRadius: 420)
            VStack(spacing: 20) {
                Image(systemName: store.mode == .incognito ? "eye.slash" : "circle.hexagongrid")
                    .font(.system(size: 35, weight: .ultraLight))
                    .foregroundStyle(Color.primary.opacity(0.15))
                if store.mode == .incognito {
                    VStack(spacing: 7) {
                        Text("Private Window").font(.system(size: 17, weight: .medium)).foregroundStyle(.primary.opacity(0.72))
                        Text("This window’s tabs, history, and cookies disappear when you close it.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
                    }
                }
                Button { store.showPalette(.newTab) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.system(size: 14))
                        Text("Search or Enter URL…").font(.system(size: 14))
                        Spacer(minLength: 12)
                        Text("⌘T").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary.opacity(hovering ? 0.54 : 0.37))
                    .padding(.horizontal, 15).frame(height: 46)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 0.85 : 0.55), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.black.opacity(hovering ? 0.10 : 0.055)))
                }
                .buttonStyle(.plain).frame(maxWidth: 360)
                .onHover { hovering = $0 }
                .animation(BrowserMotion.quick(reduceMotion: reduceMotion), value: hovering)
                .accessibilityIdentifier("browser.startSearch")
            }
            .padding(28).frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color.primary)
    }
}

struct CommandPalette: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: BrowserStore
    @Namespace private var selection
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: store.paletteMode == .split ? "rectangle.split.2x1" : "magnifyingglass")
                    .font(.system(size: 19, weight: .regular)).foregroundStyle(.secondary)
                FocusTextField(text: $store.query,
                               placeholder: store.paletteMode == .split ? "Search tabs or enter a URL…" : "Search or Enter URL…",
                               fontSize: 20, selectAllOnFocus: store.paletteMode == .navigate,
                               focusToken: store.paletteFocus,
                               onSubmit: { store.runPaletteItem() },
                               onMove: { delta in
                    store.paletteIndex = min(max(0, store.paletteIndex + delta), max(0, store.paletteItems.count - 1))
                }, onEscape: { store.paletteVisible = false })
                .frame(height: 29)
                .accessibilityIdentifier("browser.commandField")
            }.padding(.horizontal, 22).frame(height: 66)
            Divider().opacity(0.35)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Text(store.query.isEmpty ? "TABS & ACTIONS" : "SUGGESTIONS")
                            .font(.system(size: 10, weight: .semibold)).tracking(0.7)
                            .foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.top, 11).padding(.bottom, 6)
                        ForEach(Array(store.paletteItems.enumerated()), id: \.element.id) { index, item in
                            Button { store.paletteIndex = index; store.runPaletteItem() } label: {
                                ZStack {
                                    if index == store.paletteIndex {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color(hex: store.activeSpace.colorHex).opacity(0.33))
                                            .matchedGeometryEffect(id: "selection", in: selection)
                                    }
                                    HStack(spacing: 10) {
                                        Image(systemName: item.symbol).font(.system(size: 15, weight: .regular)).foregroundStyle(.secondary).frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                            Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 8)
                                        Text(item.shortcut).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                                    }.padding(.horizontal, 12)
                                }.frame(height: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).id(index)
                            .onHover { hovering in
                                guard hovering, store.paletteIndex != index else { return }
                                withAnimation(BrowserMotion.quick(reduceMotion: reduceMotion)) { store.paletteIndex = index }
                            }
                        }
                    }.padding(.horizontal, 8).padding(.bottom, 8)
                }
                .frame(maxHeight: 324).scrollIndicators(.hidden)
                .onChange(of: store.paletteIndex) { _, index in
                    withAnimation(BrowserMotion.quick(reduceMotion: reduceMotion)) { reader.scrollTo(index, anchor: .center) }
                }
            }
            HStack(spacing: 5) {
                Text("↑ ↓").font(.system(size: 10, weight: .medium))
                Text("Navigate").font(.system(size: 10))
                Spacer()
                Text("↵").font(.system(size: 11))
                Text("Open").font(.system(size: 10))
            }.foregroundStyle(.tertiary).padding(.horizontal, 21).frame(height: 28).background(.black.opacity(0.018))
        }
        .foregroundStyle(Color.primary)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.85)))
        .shadow(color: .black.opacity(0.20), radius: 34, y: 12)
        .animation(BrowserMotion.quick(reduceMotion: reduceMotion), value: store.paletteIndex)
        .accessibilityIdentifier("browser.commandPalette")
    }
}

struct ArchivePanel: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            PanelHeading(title: "Archive", subtitle: "Restore closed tabs and pick up where you left off.", symbol: "archivebox", close: { dismiss() })
            TextField("Search archived tabs", text: $query).textFieldStyle(.roundedBorder)
            if filtered.isEmpty { ContentUnavailableView("Nothing here yet", systemImage: "archivebox", description: Text("Closed and auto archived tabs will appear here.")) }
            else {
                List(filtered) { item in
                    HStack(spacing: 11) {
                        SiteIcon(url: item.tab.url)
                        VStack(alignment: .leading, spacing: 3) { Text(item.tab.title).lineLimit(1); Text(URL(string: item.tab.url)?.host ?? item.tab.url).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Text(item.closedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        Button("Restore") { store.restore(item.id) }.buttonStyle(.bordered)
                    }.padding(.vertical, 4)
                }.listStyle(.inset)
            }
        }.padding(22).frame(width: 640, height: 480)
    }
    private var filtered: [ArchivedTab] { store.state.archive.filter { query.isEmpty || $0.tab.title.localizedCaseInsensitiveContains(query) || $0.tab.url.localizedCaseInsensitiveContains(query) } }
}

struct SettingsPanel: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var engine: WebEngine
    @Environment(\.dismiss) private var dismiss
    private let colors = ["BDB6DD", "A9CADD", "B9D5C3", "E7C4AE", "DDBDCF", "BDC7D5", "B2D8D6", "E4D8B3"]
    private var spaceIndex: Int { store.state.spaces.firstIndex { $0.id == store.state.activeSpaceID } ?? 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PanelHeading(title: "Settings", subtitle: "Browsing, spaces, and your data.", symbol: "slider.horizontal.3", close: { dismiss() })
            Form {
                Section("This space") {
                    TextField("Name", text: $store.state.spaces[spaceIndex].name)
                    TextField("Icon", text: $store.state.spaces[spaceIndex].emoji)
                    HStack {
                        Text("Color")
                        Spacer()
                        ForEach(colors, id: \.self) { color in
                            Button { store.changeSpaceColor(store.state.activeSpaceID, hex: color) } label: {
                                Circle().fill(Color(hex: color)).frame(width: 22, height: 22).overlay(Circle().strokeBorder(.black.opacity(store.activeSpace.colorHex == color ? 0.5 : 0), lineWidth: 2))
                            }.buttonStyle(.plain).help(color)
                        }
                    }
                }
                Section("Browsing") {
                    Picker("Search engine", selection: $store.state.searchEngine) { Text("DuckDuckGo").tag("duckduckgo"); Text("Google").tag("google") }
                    Picker("Auto archive idle tabs", selection: $store.state.autoArchiveHours) { Text("Never").tag(0.0); Text("After 12 hours").tag(12.0); Text("After 24 hours").tag(24.0); Text("After 7 days").tag(168.0); Text("After 30 days").tag(720.0) }
                    Stepper("Keep up to \(store.state.maxLiveTabs) live tabs", value: $store.state.maxLiveTabs, in: 2...16)
                    Text("Inactive tabs sleep when this limit is reached. Playing media and edited forms stay alive. Returning to a sleeping tab reloads it.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Your data") {
                    HStack {
                        Button("Import Arc Sidebar…") { store.importArc() }
                        Button("Export Session…") { store.exportSession() }
                        Spacer()
                    }
                    Text(store.mode == .incognito ? "This window has a temporary profile. Its cookies, history, and session stay out of your saved browser data." : "Websites share one persistent browser profile. Logins are independent of Arc. No account or analytics service is required.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack {
                Text("Curve 0.3 · Native WebKit").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(engine.liveCount) live views · \(store.state.tabs.count) saved tabs").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(22).frame(width: 610, height: 600).onDisappear { store.saveNow(); store.trim() }
    }
}

struct ShortcutsPanel: View {
    @Environment(\.dismiss) private var dismiss
    private let rows = [("New tab / command bar", "⌘ T"), ("New window / Incognito / Little Curve", "⌘ N / ⇧⌘N / ⌥⌘N"), ("Edit current address", "⌘ L"), ("Show / hide sidebar", "⌘ S"), ("Pin / unpin tab", "⌘ D"), ("Close / reset tab", "⌘ W"), ("Reopen last closed / clear unpinned", "⇧⌘T / ⇧⌘K"), ("Copy URL / as Markdown", "⇧⌘C / ⌥⇧⌘C"), ("Go to tab / space", "⌘1…9 / ⌃1…9"), ("Cycle recent tabs", "⌃ Tab"), ("Previous / next tab", "⌥⌘↑ / ↓"), ("Previous / next space", "⌥⌘← / →"), ("Back / forward", "⌘← / → or ⌘[ / ]"), ("Add / close Split View", "⌃⇧+ / ⌃⇧−"), ("Focus split pane", "⌃⇧1 / ⌃⇧2"), ("History / Find / Reload", "⌘Y / ⌘F / ⌘R"), ("Zoom in / out / reset", "⌘+ / ⌘− / ⌘0"), ("Peek / open link in new tab", "⇧click / ⌘click")]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PanelHeading(title: "Keyboard Shortcuts", subtitle: "The familiar browser shortcuts, all in one place.", symbol: "keyboard", close: { dismiss() })
            VStack(spacing: 0) { ForEach(rows, id: \.0) { row in HStack { Text(row.0); Spacer(); Text(row.1).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.secondary) }.font(.system(size: 12)).padding(.vertical, 9); if row.0 != rows.last?.0 { Divider().opacity(0.4) } } }
        }.padding(22).frame(width: 590)
    }
}

struct DownloadsPanel: View {
    @ObservedObject var engine: WebEngine
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PanelHeading(title: "Downloads", subtitle: "Files go exactly where you choose.", symbol: "arrow.down.circle", close: { dismiss() })
            if engine.downloads.isEmpty { ContentUnavailableView("No downloads yet", systemImage: "arrow.down.circle", description: Text("Downloads from websites will appear here.")) }
            else {
                List(engine.downloads) { download in
                    HStack {
                        Image(systemName: download.isComplete ? "doc" : "arrow.down.circle").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(download.name).lineLimit(1)
                            if !download.isComplete { ProgressView(value: download.progress).frame(width: 210) }
                            Text(download.status).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if download.isComplete { Button("Show in Finder") { engine.revealDownload(download.id) } }
                        else { Button("Cancel") { engine.cancelDownload(download.id) } }
                    }.padding(.vertical, 8)
                }.listStyle(.inset)
            }
        }.padding(22).frame(width: 590, height: 420)
    }
}
struct PanelHeading: View {
    let title: String; let subtitle: String; let symbol: String; let close: () -> Void
    var body: some View { HStack(alignment: .top, spacing: 13) {
        Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(Color(hex: "797581")).frame(width: 30).padding(.top, 1)
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 18, weight: .semibold)); Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
        Spacer(); IconButton("xmark", help: "Close", action: close).keyboardShortcut(.cancelAction)
    } }
}

struct HistoryPanel: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            PanelHeading(title: "History", subtitle: store.mode == .incognito ? "Only this private window. Nothing is saved to disk." : "Search the pages you’ve visited.", symbol: "clock", close: { dismiss() })
            TextField("Search history", text: $query).textFieldStyle(.roundedBorder)
            if filtered.isEmpty { ContentUnavailableView("A fresh trail", systemImage: "clock", description: Text("Pages you visit will appear here.")) }
            else {
                List(filtered) { item in
                    Button { store.open(item.url); dismiss() } label: {
                        HStack(spacing: 11) {
                            SiteIcon(url: item.url)
                            VStack(alignment: .leading, spacing: 4) { Text(item.title).lineLimit(1); Text(item.url).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            Text(item.visitedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                            Image(systemName: "arrow.up.right").foregroundStyle(.tertiary)
                        }.padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.listStyle(.inset)
            }
        }.padding(22).frame(width: 640, height: 480)
    }
    private var filtered: [HistoryEntry] { store.history.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) } }
}
