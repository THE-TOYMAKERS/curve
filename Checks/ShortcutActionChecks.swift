import AppKit
import Foundation
import BrowserCore

/// Exercises the real router-to-store path and its state effects. This is an
/// automated action test, distinct from delivery through a visible macOS window.
@main
struct ShortcutActionChecks {
    @MainActor static func waitUntil(_ predicate: @escaping () -> Bool) async -> Bool {
        for _ in 0..<100 { if predicate() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
        return predicate()
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let parent = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : FileManager.default.temporaryDirectory
            let directory = parent.appendingPathComponent("ShortcutActions-\(UUID().uuidString)")
            setenv("CURVE_DATA_DIR", directory.appendingPathComponent("shared").path, 1)
            let oldClipboard = NSPasteboard.general.pasteboardItems?.map { item in item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) } } ?? []
            var passed = 0
            var failed: [String] = []
            func check(_ result: Bool, _ name: String) { if result { passed += 1 } else { failed.append(name) } }
            let studio = BrowserSpace(name: "Studio", emoji: "S", colorHex: "B9D7DC")
            let research = BrowserSpace(name: "Research", emoji: "R", colorHex: "C8C2E2")
            let focus = BrowserSpace(name: "Focus", emoji: "F", colorHex: "E5C8AD")
            var seed = BrowserState(spaces: [studio, research, focus])
            let root = seed.addFolder(name: "Resources", spaceID: studio.id)
            let nested = seed.addFolder(name: "Resources / Reading", spaceID: studio.id)
            let favorite = seed.open(url: "curve://start", title: "Favorite", kind: .favorite, spaceID: studio.id)
            let rootPin = seed.open(url: "curve://start", title: "Root pin", kind: .pinned, spaceID: studio.id)
            let nestedPin = seed.open(url: "curve://start", title: "Nested pin", kind: .pinned, spaceID: studio.id, folderID: nested)
            _ = root
            var today: [UUID] = []
            for n in 1...9 { today.append(seed.open(url: "curve://start", title: "Today \(n)", spaceID: studio.id)) }
            _ = seed.open(url: "curve://start", title: "Research note", spaceID: research.id)
            _ = seed.open(url: "curve://start", title: "Focus note", spaceID: focus.id)
            seed.select(today[0])
            let store = BrowserStore(mode: .normal, directory: directory.appendingPathComponent("window"), seed: seed)
            @MainActor func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
                check(store.keyboard.handle(event: event), "router handles \(characters) \(flags.rawValue)")
            }
            let cmd: NSEvent.ModifierFlags = .command
            let shiftCmd: NSEvent.ModifierFlags = [.command, .shift]
            let optCmd: NSEvent.ModifierFlags = [.command, .option]
            let ctrlShift: NSEvent.ModifierFlags = [.control, .shift]
            key(17, "t", cmd)
            check(store.paletteVisible && store.query.isEmpty, "Command-T opens a clean command field")
            store.paletteVisible = false
            key(37, "l", cmd)
            check(store.paletteVisible && store.query == "curve://start", "Command-L targets current address")
            store.paletteVisible = false
            let sidebar = store.state.sidebarVisible
            key(1, "s", cmd); check(store.state.sidebarVisible != sidebar, "Command-S hides sidebar")
            key(1, "s", cmd); check(store.state.sidebarVisible == sidebar, "Command-S restores sidebar")
            key(2, "d", cmd); check(store.state.tabs.first { $0.id == today[0] }?.kind == .pinned, "Command-D pins current tab")
            key(2, "d", cmd); check(store.state.tabs.first { $0.id == today[0] }?.kind == .today, "Command-D unpins current tab")
            key(8, "C", shiftCmd)
            check(NSPasteboard.general.string(forType: .string) == "curve://start", "copy URL action reaches clipboard")
            key(8, "C", [.command, .option, .shift])
            check(NSPasteboard.general.string(forType: .string) == "[Today 1](<curve://start>)", "copy Markdown action reaches clipboard")
            let digits: [(UInt16, Int)] = [(18,1),(19,2),(20,3),(21,4),(23,5),(22,6),(26,7),(28,8),(25,9)]
            let expected = store.orderedTabs.map(\.id)
            check(Array(expected.prefix(3)) == [favorite, rootPin, nestedPin], "tab order follows visible nested folder structure")
            for (code, n) in digits {
                key(code, String(n), cmd)
                check(store.currentID == expected[n == 9 ? expected.count - 1 : n - 1], "Command-\(n) selects documented ordinal")
            }
            for (code, n) in digits.prefix(3) {
                key(code, String(n), .control)
                check(store.state.activeSpaceID == [studio.id, research.id, focus.id][n - 1], "Control-\(n) switches correct space")
            }
            key(25, "9", .control)
            check(store.state.activeSpaceID == focus.id, "out-of-range space safely preserves selection")
            store.switchSpace(studio.id)
            store.select(expected[0])
            key(126, "\u{F700}", optCmd)
            check(store.currentID == expected.last, "previous tab wraps through sidebar order")
            key(125, "\u{F701}", optCmd)
            check(store.currentID == expected.first, "next tab wraps through sidebar order")
            key(123, "\u{F702}", optCmd)
            check(store.state.activeSpaceID == focus.id, "previous space wraps to last")
            key(124, "\u{F703}", optCmd)
            check(store.state.activeSpaceID == studio.id, "next space wraps to first")
            store.select(today[1]); store.select(today[0])
            key(48, "\t", .control)
            check(store.currentID == today[1], "Control-Tab selects recent alternative")
            key(48, "\t", ctrlShift)
            check(store.currentID == today[0], "Control-Shift-Tab reverses current recent cycle")
            let release = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59)!
            _ = store.keyboard.handle(event: release)
            key(48, "\t", .control)
            check(store.currentID == today[1], "releasing Control commits recent-tab cycle")
            _ = store.keyboard.handle(event: release)
            store.select(today[0]); store.setSplit(today[1])
            key(19, "@", ctrlShift)
            check(store.currentID == today[1] && store.state.selectedTabID == today[0], "second split focus targets secondary")
            key(18, "!", ctrlShift)
            check(store.currentID == today[0], "first split focus targets primary")
            key(20, "#", ctrlShift)
            check(store.currentID == today[0], "nonexistent split focus is safe")
            key(24, "+", ctrlShift)
            check(store.paletteVisible && String(describing: store.paletteMode) == "split", "split shortcut opens split command field")
            store.paletteVisible = false
            let beforeSplitClose = store.state.tabs.map(\.id)
            key(27, "_", ctrlShift)
            check(store.splitID == nil && store.state.tabs.map(\.id) == beforeSplitClose, "close split keeps both saved tabs")
            key(3, "f", cmd)
            check(store.findVisible, "Command-F exposes Find field")
            store.findVisible = false
            key(16, "y", cmd)
            check(store.historyVisible, "Command-Y exposes history")
            store.historyVisible = false
            let beforeClose = store.state.tabs.count
            key(13, "w", cmd)
            check(store.state.tabs.count == beforeClose - 1 && store.state.archive.first?.tab.id == today[0], "Command-W archives current Today tab")
            key(17, "T", shiftCmd)
            check(store.state.tabs.count == beforeClose && store.currentID == today[0], "Shift-Command-T restores same tab")
            let saved = Set(store.state.tabs.filter { $0.kind != .today }.map(\.id))
            key(40, "K", shiftCmd)
            let cleared = await waitUntil { store.today.isEmpty }
            check(cleared && Set(store.state.tabs.filter { $0.kind != .today }.map(\.id)) == saved, "clear shortcut preserves favorites and pins")
            var modes: [String] = []
            store.onNewWindow = { mode in switch mode { case .normal: modes.append("normal"); case .incognito: modes.append("private"); case .little: modes.append("little") } }
            key(45, "n", cmd); key(45, "N", shiftCmd); key(45, "n", optCmd)
            check(modes == ["normal", "private", "little"], "window shortcuts route distinct modes")
            store.saveNow()
            let restored = store.persistence.load()
            check(restored.spaces == store.state.spaces && restored.tabs == store.state.tabs && restored.folders == store.state.folders, "shortcut mutations survive persistence roundtrip")
            store.shutdown()
            NSPasteboard.general.clearContents()
            let restoredItems = oldClipboard.map { item -> NSPasteboardItem in let output = NSPasteboardItem(); for (type,data) in item { output.setData(data, forType: type) }; return output }
            if !restoredItems.isEmpty { NSPasteboard.general.writeObjects(restoredItems) }
            try? FileManager.default.removeItem(at: directory)
            print("Shortcut actions: \(passed) checks passed, \(failed.count) failures")
            failed.forEach { print("FAIL \($0)") }
            fflush(stdout)
            exit(failed.isEmpty ? 0 : 1)
        }
        app.run()
    }
}
