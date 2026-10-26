import AppKit

/// Browser shortcuts are intercepted before WebKit consumes key equivalents.
enum BrowserKeyAction: Equatable {
    case newTab, newWindow, incognitoWindow, littleArc
    case closeTab, restoreTab, togglePin, copyURL, copyMarkdown, editURL
    case toggleSidebar, clearToday
    case tabNumber(Int), spaceNumber(Int)
    case recentTab(Bool), tabStep(Int), spaceStep(Int)
    case forward, back, addSplit, closeSplit, focusSplit(Int), history
    case zoom(Double), resetZoom, reload, find
}

@MainActor
final class BrowserKeyboardRouter {
    weak var window: NSWindow?
    var onAction: ((BrowserKeyAction) -> Void)?
    var onRecentTabCycleEnded: (() -> Void)?
    /// The owner can suppress routing while an in-window palette or panel owns input.
    var isEnabled: (() -> Bool)?

    private var monitor: Any?
    private var recentCycleActive = false

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                // Never take key equivalents from another window, a native alert,
                // a save/open panel, or a SwiftUI sheet attached to this window.
                guard let window = self.window,
                      NSApp.keyWindow === window,
                      NSApp.modalWindow == nil,
                      window.attachedSheet == nil,
                      self.isEnabled?() ?? true else {
                    self.finishRecentCycle()
                    return false
                }
                return self.handle(event: event)
            }
            return handled ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        finishRecentCycle()
    }

    /// Returns true only when an action was delivered. Focus/modal checks belong
    /// to the installed monitor so this method also supports synthetic key tests.
    @discardableResult
    func handle(event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .flagsChanged {
            if !modifiers.contains(.control) { finishRecentCycle() }
            return false
        }
        guard event.type == .keyDown,
              let action = Self.action(keyCode: event.keyCode,
                                       characters: event.charactersIgnoringModifiers ?? "",
                                       modifiers: modifiers),
              let onAction else { return false }
        if case .recentTab = action { recentCycleActive = true }
        onAction(action)
        return true
    }

    private func finishRecentCycle() {
        guard recentCycleActive else { return }
        recentCycleActive = false
        onRecentTabCycleEnded?()
    }

    private static func action(keyCode: UInt16, characters: String,
                               modifiers: NSEvent.ModifierFlags) -> BrowserKeyAction? {
        let command: NSEvent.ModifierFlags = .command
        let commandShift: NSEvent.ModifierFlags = [.command, .shift]
        let commandOption: NSEvent.ModifierFlags = [.command, .option]
        let controlShift: NSEvent.ModifierFlags = [.control, .shift]
        let key = characters.lowercased()

        // Physical digit positions remain usable when Shift produces !, @, etc.
        let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
                                    22: 6, 26: 7, 28: 8, 25: 9, 29: 0]
        if let number = digits[keyCode] {
            if modifiers == command { return number == 0 ? .resetZoom : .tabNumber(number) }
            if modifiers == .control, number > 0 { return .spaceNumber(number) }
            if modifiers == controlShift, (1...4).contains(number) { return .focusSplit(number) }
        }

        if keyCode == 48 {
            if modifiers == .control { return .recentTab(false) }
            if modifiers == controlShift { return .recentTab(true) }
        }
        if keyCode == 24 || key == "+" || key == "=" {
            if modifiers == controlShift { return .addSplit }
            if modifiers == command || modifiers == commandShift { return .zoom(1.1) }
        }
        if keyCode == 27 || key == "-" || key == "_" {
            if modifiers == controlShift { return .closeSplit }
            if modifiers == command { return .zoom(1 / 1.1) }
        }

        switch keyCode {
        case 123:
            if modifiers == command { return .back }
            if modifiers == commandOption { return .spaceStep(-1) }
        case 124:
            if modifiers == command { return .forward }
            if modifiers == commandOption { return .spaceStep(1) }
        case 125:
            if modifiers == commandOption { return .tabStep(1) }
        case 126:
            if modifiers == commandOption { return .tabStep(-1) }
        default: break
        }

        if modifiers == command {
            switch key {
            case "t": return .newTab
            case "n": return .newWindow
            case "w": return .closeTab
            case "d": return .togglePin
            case "l": return .editURL
            case "s": return .toggleSidebar
            case "y": return .history
            case "r": return .reload
            case "f": return .find
            case "[": return .back
            case "]": return .forward
            default: return nil
            }
        }
        if modifiers == commandShift {
            switch key {
            case "n": return .incognitoWindow
            case "t": return .restoreTab
            case "c": return .copyURL
            case "k": return .clearToday
            default: return nil
            }
        }
        if modifiers == commandOption, key == "n" { return .littleArc }
        if modifiers == [.command, .option, .shift], key == "c" { return .copyMarkdown }
        return nil
    }
}
