import SwiftUI
import AppKit
import BrowserCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        NSApp.windows.first?.setFrameAutosaveName("CurveMainWindow")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { BrowserCoordinator.shared.openNormalWindow?() }
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in BrowserCoordinator.shared.receive(urls) }
    }
    func applicationWillTerminate(_ notification: Notification) { MainActor.assumeIsolated { BrowserCoordinator.shared.activeStore?.saveNow() } }
}

@main
struct CurveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Curve", id: "browser", for: UUID.self) { $sessionID in BrowserWindowHost(mode: .normal, sessionID: sessionID) } defaultValue: { BrowserCoordinator.mainID }
            .windowStyle(.hiddenTitleBar).defaultSize(width: 1280, height: 820)
            .commands { BrowserCommands() }
        WindowGroup("Private · Curve", id: "private") { BrowserWindowHost(mode: .incognito) }
            .windowStyle(.hiddenTitleBar).defaultSize(width: 1160, height: 780)
        WindowGroup("Little Curve · Curve", id: "little") { BrowserWindowHost(mode: .little) }
            .windowStyle(.hiddenTitleBar).defaultSize(width: 720, height: 600)
    }
}

struct BrowserCommands: Commands {
    @FocusedObject private var focusedStore: BrowserStore?
    @Environment(\.openWindow) private var openWindow
    private var store: BrowserStore? { focusedStore ?? BrowserCoordinator.shared.activeStore }
    private var tab: BrowserTab? { store.flatMap { store in store.state.tabs.first { $0.id == store.currentID } } }
    private var page: WebPageState { store.flatMap { store in store.currentID.map { store.engine.state(id: $0) } } ?? WebPageState() }
    private var hasPage: Bool { tab.map { ["http", "https"].contains(URL(string: $0.url)?.scheme ?? "") } ?? false }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { store?.showPalette(.newTab) }.keyboardShortcut("t", modifiers: .command)
            Button("New Window") { openWindow(id: "browser", value: UUID()) }.keyboardShortcut("n", modifiers: .command)
            Button("New Incognito Window") { openWindow(id: "private") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Little Curve") { openWindow(id: "little") }.keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("New Space…") { store?.addSpace() }
            Button("New Folder…") { store?.addFolder() }
            Button("Open Location…") { store?.showPalette(.navigate) }.keyboardShortcut("l", modifiers: .command)
            Button("Import from Arc…") { store?.importArc() }
            Button("Export Session…") { store?.exportSession() }
            Divider()
            Button(tab == nil ? "Close Window" : "Close Tab") { store?.performKeyAction(.closeTab) }.keyboardShortcut("w", modifiers: .command)
            Button("Close Window") { store?.window?.performClose(nil) }.keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { store?.settingsVisible = true }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Button(store?.state.sidebarVisible == true ? "Hide Sidebar" : "Show Sidebar") { store?.performKeyAction(.toggleSidebar) }.keyboardShortcut("s", modifiers: .command)
            Button("Reload Page") { store?.performKeyAction(.reload) }.keyboardShortcut("r", modifiers: .command).disabled(!hasPage)
            Button("Back") { store?.performKeyAction(.back) }.keyboardShortcut("[", modifiers: .command).disabled(!page.canGoBack)
            Button("Forward") { store?.performKeyAction(.forward) }.keyboardShortcut("]", modifiers: .command).disabled(!page.canGoForward)
            Button("History") { store?.performKeyAction(.history) }.keyboardShortcut("y", modifiers: .command)
            Divider()
            Button("Zoom In") { store?.performKeyAction(.zoom(1.1)) }.keyboardShortcut("+", modifiers: .command).disabled(!hasPage)
            Button("Zoom Out") { store?.performKeyAction(.zoom(1 / 1.1)) }.keyboardShortcut("-", modifiers: .command).disabled(!hasPage)
            Button("Actual Size") { store?.performKeyAction(.resetZoom) }.keyboardShortcut("0", modifiers: .command).disabled(!hasPage)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy URL") { store?.copyURL() }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(tab == nil)
            Button("Copy URL as Markdown") { store?.copyURL(markdown: true) }.keyboardShortcut("c", modifiers: [.command, .shift, .option]).disabled(tab == nil)
            Button("Copy URL as Quote") { store?.copyQuote() }.disabled(!hasPage)
            ResponderCommand("Paste and Match Style", "pasteAsPlainText:").keyboardShortcut("v", modifiers: [.command, .option, .shift])
        }
        CommandGroup(after: .textEditing) {
            Menu("Find") {
                Button("Find…") { store?.performKeyAction(.find) }.keyboardShortcut("f", modifiers: .command).disabled(!hasPage)
                Button("Find Next") { if let store, let id = store.currentID { store.engine.find(id: id, query: store.findQuery, backwards: false) } }.keyboardShortcut("g", modifiers: .command).disabled(!hasPage || store?.findQuery.isEmpty != false)
                Button("Find Previous") { if let store, let id = store.currentID { store.engine.find(id: id, query: store.findQuery, backwards: true) } }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!hasPage || store?.findQuery.isEmpty != false)
                Button("Use Selection to Find") { store?.useSelectionToFind() }.keyboardShortcut("e", modifiers: .command).disabled(!hasPage)
            }
            Menu("Spelling and Grammar") {
                ResponderCommand("Show Spelling and Grammar", "showGuessPanel:")
                ResponderCommand("Check Document Now", "checkSpelling:")
                Divider()
                ResponderCommand("Check Spelling While Typing", "toggleContinuousSpellChecking:")
                ResponderCommand("Check Grammar With Spelling", "toggleGrammarChecking:")
                ResponderCommand("Correct Spelling Automatically", "toggleAutomaticSpellingCorrection:")
            }
            Menu("Substitutions") {
                ResponderCommand("Show Substitutions", "orderFrontSubstitutionsPanel:")
                Divider()
                ResponderCommand("Smart Copy/Paste", "toggleSmartInsertDelete:")
                ResponderCommand("Smart Quotes", "toggleAutomaticQuoteSubstitution:")
                ResponderCommand("Smart Dashes", "toggleAutomaticDashSubstitution:")
                ResponderCommand("Smart Links", "toggleAutomaticLinkDetection:")
                ResponderCommand("Data Detectors", "toggleAutomaticDataDetection:")
                ResponderCommand("Text Replacement", "toggleAutomaticTextReplacement:")
            }
            Menu("Transformations") {
                ResponderCommand("Make Upper Case", "uppercaseWord:")
                ResponderCommand("Make Lower Case", "lowercaseWord:")
                ResponderCommand("Capitalize", "capitalizeWord:")
            }
            Menu("Speech") {
                ResponderCommand("Start Speaking", "startSpeaking:")
                ResponderCommand("Stop Speaking", "stopSpeaking:")
            }
            Menu("Format") {
                Menu("Font") {
                    Button("Bold") { BrowserEditing.fontTrait(.boldFontMask) }.keyboardShortcut("b", modifiers: .command).disabled(!BrowserEditing.canChangeFont)
                    Button("Italic") { BrowserEditing.fontTrait(.italicFontMask) }.keyboardShortcut("i", modifiers: .command).disabled(!BrowserEditing.canChangeFont)
                    ResponderCommand("Underline", "underline:").keyboardShortcut("u", modifiers: .command)
                }
            }
        }
        CommandMenu("Spaces") {
            if let store {
                ForEach(Array(store.state.spaces.enumerated()), id: \.element.id) { index, space in
                    if index < 9 {
                        Button("\(space.emoji)  \(space.name)") { store.switchSpace(space.id) }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .control)
                    } else {
                        Button("\(space.emoji)  \(space.name)") { store.switchSpace(space.id) }
                    }
                }
            }
            Divider()
            Button("New Space…") { store?.addSpace() }
            Button("Edit Space…") { store?.settingsVisible = true }
            if let store, store.removedSpace != nil { Button("Restore Removed Space") { store.restoreRemovedSpace() } }
            Divider()
            Button("Previous Space") { store?.nextSpace(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next Space") { store?.nextSpace(1) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        }
        CommandMenu("Tabs") {
            Button(tab?.kind == .pinned ? "Unpin Tab" : "Pin Tab") { store?.togglePin() }.keyboardShortcut("d", modifiers: .command).disabled(tab == nil)
            Button(tab?.kind == .favorite ? "Remove from Favorites" : "Add to Favorites") { if let store, let id = store.currentID { store.toggleFavorite(id) } }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(tab == nil)
            Button("Duplicate Tab") { if let store, let id = store.currentID { store.duplicate(id) } }.disabled(tab == nil)
            Divider()
            Button("Add Split View…") { store?.showPalette(.split) }.keyboardShortcut("+", modifiers: [.control, .shift])
            Button("Close Split View") { store?.setSplit(nil) }.keyboardShortcut("-", modifiers: [.control, .shift]).disabled(store?.splitID == nil)
            Button("Rotate Split View") { store?.toggleSplitOrientation() }.disabled(store?.splitID == nil)
            Button("Focus First Split") { store?.focusSplit(1) }.keyboardShortcut("1", modifiers: [.control, .shift]).disabled(store?.splitID == nil)
            Button("Focus Second Split") { store?.focusSplit(2) }.keyboardShortcut("2", modifiers: [.control, .shift]).disabled(store?.splitID == nil)
            Divider()
            Button("Clear Unpinned Tabs") { store?.clearToday() }.keyboardShortcut("k", modifiers: [.command, .shift]).disabled(store?.today.isEmpty != false)
            Button("Reopen Last Closed Tab") { store?.restoreLast() }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(store?.state.archive.isEmpty != false)
            Button("Open Archive") { store?.archiveVisible = true }
            Button("Downloads") { store?.downloadsVisible = true }.keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button("Previous Tab") { store?.stepTab(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(store?.orderedTabs.isEmpty != false)
            Button("Next Tab") { store?.stepTab(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(store?.orderedTabs.isEmpty != false)
            Divider()
            ForEach(1..<10) { number in
                Button(number == 9 ? "Go to Last Tab" : "Go to Tab \(number)") { store?.selectNumber(number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                    .disabled(number == 9 ? store?.orderedTabs.isEmpty != false : (store?.orderedTabs.count ?? 0) < number)
            }
        }
        CommandMenu("Archive") {
            Button("View Archive…") { store?.archiveVisible = true }
            Button("Reopen Last Closed Tab") { store?.restoreLast() }.disabled(store?.state.archive.isEmpty != false)
            Button("Clear Unpinned Tabs") { store?.clearToday() }.disabled(store?.today.isEmpty != false)
            Divider()
            Button("View History…") { store?.performKeyAction(.history) }
        }
        CommandGroup(replacing: .help) { Button("Curve Keyboard Shortcuts") { store?.helpVisible = true } }
    }
}


struct ResponderCommand: View {
    let title: String
    let selector: String
    init(_ title: String, _ selector: String) { self.title = title; self.selector = selector }
    var body: some View {
        Button(title) { BrowserEditing.perform(NSSelectorFromString(selector)) }
            .disabled(!BrowserEditing.canPerform(NSSelectorFromString(selector)))
    }
}
