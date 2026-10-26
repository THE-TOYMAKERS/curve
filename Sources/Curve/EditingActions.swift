import AppKit

/// Routes editing to the native first responder, including WebKit's content view
/// and AppKit's shared field editor. It never changes focus or the pasteboard itself.
@MainActor
enum BrowserEditing {
    static func canPerform(_ selector: Selector) -> Bool {
        guard let target = NSApp.target(forAction: selector) else { return false }
        let item = NSMenuItem(title: "", action: selector, keyEquivalent: "")
        item.target = target as AnyObject
        if let validator = target as? NSMenuItemValidation {
            return validator.validateMenuItem(item)
        }
        if let validator = target as? NSUserInterfaceValidations {
            return validator.validateUserInterfaceItem(item)
        }
        return true
    }
    static var canChangeFont: Bool { canPerform(NSSelectorFromString("changeFont:")) }

    static func perform(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    static func undo() {
        if !NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil) {
            let manager = NSApp.keyWindow?.firstResponder?.undoManager ?? NSApp.keyWindow?.undoManager
            if manager?.canUndo == true { manager?.undo() }
        }
    }

    static func redo() {
        if !NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil) {
            let manager = NSApp.keyWindow?.firstResponder?.undoManager ?? NSApp.keyWindow?.undoManager
            if manager?.canRedo == true { manager?.redo() }
        }
    }

    static func cut() { perform(#selector(NSText.cut(_:))) }
    static func copy() { perform(#selector(NSText.copy(_:))) }
    static func paste() { perform(#selector(NSText.paste(_:))) }
    static func pasteAndMatchStyle() { perform(#selector(NSTextView.pasteAsPlainText(_:))) }
    static func fontTrait(_ trait: NSFontTraitMask) {
        let sender = NSMenuItem(); sender.tag = Int(trait.rawValue)
        let manager = NSFontManager.shared
        if let font = manager.selectedFont, manager.traits(of: font).contains(trait) {
            manager.removeFontTrait(sender)
        } else {
            manager.addFontTrait(sender)
        }
    }
    static func selectAll() { perform(#selector(NSText.selectAll(_:))) }
}
