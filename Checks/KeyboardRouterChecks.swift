import AppKit

@main
struct KeyboardRouterChecks {
    @MainActor
    static func main() {
        let router = BrowserKeyboardRouter()
        var delivered: BrowserKeyAction?
        var count = 0
        var failures = 0
        var endedCycles = 0
        router.onAction = { delivered = $0 }
        router.onRecentTabCycleEnded = { endedCycles += 1 }

        func check(_ name: String, _ code: UInt16, _ characters: String,
                   _ modifiers: NSEvent.ModifierFlags, _ expected: BrowserKeyAction?) {
            delivered = nil
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: modifiers, timestamp: 0,
                                        windowNumber: 0, context: nil,
                                        characters: characters,
                                        charactersIgnoringModifiers: characters,
                                        isARepeat: false, keyCode: code)!
            let handled = router.handle(event: event)
            count += 1
            if delivered != expected || handled != (expected != nil) {
                failures += 1
                print("FAIL \(name): expected \(String(describing: expected)); got \(String(describing: delivered)); handled \(handled)")
            }
        }
        let cmd: NSEvent.ModifierFlags = .command
        let shiftCmd: NSEvent.ModifierFlags = [.command, .shift]
        let optCmd: NSEvent.ModifierFlags = [.command, .option]
        let ctrlShift: NSEvent.ModifierFlags = [.control, .shift]
        check("new tab", 17, "t", cmd, .newTab)
        check("new window", 45, "n", cmd, .newWindow)
        check("private window", 45, "N", shiftCmd, .incognitoWindow)
        check("Little Curve", 45, "n", optCmd, .littleArc)
        check("close tab", 13, "w", cmd, .closeTab)
        check("restore tab", 17, "T", shiftCmd, .restoreTab)
        check("pin", 2, "d", cmd, .togglePin)
        check("copy URL", 8, "C", shiftCmd, .copyURL)
        check("copy Markdown", 8, "C", [.command, .shift, .option], .copyMarkdown)
        check("edit URL", 37, "l", cmd, .editURL)
        check("sidebar", 1, "s", cmd, .toggleSidebar)
        check("clear Today", 40, "K", shiftCmd, .clearToday)
        let digitCodes: [(UInt16, Int)] = [(18,1),(19,2),(20,3),(21,4),(23,5),(22,6),(26,7),(28,8),(25,9)]
        for (code, number) in digitCodes {
            check("tab \(number)", code, String(number), cmd, .tabNumber(number))
            check("space \(number)", code, String(number), .control, .spaceNumber(number))
            if number <= 4 { check("pane \(number)", code, "!@#$".map(String.init)[number - 1], ctrlShift, .focusSplit(number)) }
        }
        check("recent forward", 48, "\t", .control, .recentTab(false))
        check("recent backward", 48, "\t", ctrlShift, .recentTab(true))
        let release = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: false, keyCode: 59)!
        count += 1
        if router.handle(event: release) || endedCycles != 1 { failures += 1; print("FAIL recent cycle release") }
        check("previous tab", 126, "\u{F700}", optCmd, .tabStep(-1))
        check("next tab", 125, "\u{F701}", optCmd, .tabStep(1))
        check("previous space", 123, "\u{F702}", optCmd, .spaceStep(-1))
        check("next space", 124, "\u{F703}", optCmd, .spaceStep(1))
        check("back", 123, "\u{F702}", cmd, .back)
        check("forward", 124, "\u{F703}", cmd, .forward)
        check("back bracket", 33, "[", cmd, .back)
        check("forward bracket", 30, "]", cmd, .forward)
        check("add split physical", 24, "+", ctrlShift, .addSplit)
        check("add split equal", 24, "=", ctrlShift, .addSplit)
        check("close split physical", 27, "_", ctrlShift, .closeSplit)
        check("history", 16, "y", cmd, .history)
        check("zoom plus", 24, "+", shiftCmd, .zoom(1.1))
        check("zoom equal", 24, "=", cmd, .zoom(1.1))
        check("zoom keypad plus", 69, "+", cmd, .zoom(1.1))
        check("zoom minus", 27, "-", cmd, .zoom(1 / 1.1))
        check("reset zoom", 29, "0", cmd, .resetZoom)
        check("reload", 15, "r", cmd, .reload)
        check("find", 3, "f", cmd, .find)
        check("layout independent letter", 99, "t", cmd, .newTab)
        check("nonsemantic flags", 17, "T", [.command, .capsLock, .function, .numericPad], .newTab)
        check("typing", 17, "t", [], nil)
        check("unmatched modifier", 17, "t", [.command, .control], nil)
        check("preserve editing copy", 8, "c", cmd, nil)
        check("preserve editing select all", 0, "a", cmd, nil)
        check("preserve Escape", 53, "\u{1b}", [], nil)
        check("unsupported focus pane", 23, "%", ctrlShift, nil)
        check("preserve control zero", 29, "0", .control, nil)
        router.onAction = nil
        delivered = nil
        let unhandled = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: cmd,
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        characters: "t", charactersIgnoringModifiers: "t",
                                        isARepeat: false, keyCode: 17)!
        count += 1
        if router.handle(event: unhandled) { failures += 1; print("FAIL absent action callback must preserve event") }
        router.uninstall()
        print("KeyboardRouter: \(count) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
