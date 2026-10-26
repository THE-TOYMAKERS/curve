import AppKit
import SwiftUI

/// An AppKit field whose focus changes only on mounting or an explicit token.
/// Ordinary SwiftUI updates, including page-loading updates, preserve the editor.
struct FocusTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    var selectAllOnFocus: Bool
    var focusToken: UUID
    var onSubmit: () -> Void
    var onMove: (Int) -> Void
    var onEscape: () -> Void

    init(text: Binding<String>, placeholder: String, fontSize: CGFloat = 17,
         selectAllOnFocus: Bool = false, focusToken: UUID,
         onSubmit: @escaping () -> Void,
         onMove: @escaping (Int) -> Void = { _ in },
         onEscape: @escaping () -> Void = {}) {
        _text = text
        self.placeholder = placeholder
        self.fontSize = fontSize
        self.selectAllOnFocus = selectAllOnFocus
        self.focusToken = focusToken
        self.onSubmit = onSubmit
        self.onMove = onMove
        self.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MountedFocusTextField {
        let field = MountedFocusTextField(frame: .zero)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = .labelColor
        field.stringValue = text
        field.placeholderString = placeholder
        field.selectAllOnRequestedFocus = selectAllOnFocus
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: MountedFocusTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if field.font?.pointSize != fontSize { field.font = .systemFont(ofSize: fontSize) }
        field.selectAllOnRequestedFocus = selectAllOnFocus
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            field.requestFocus()
        }
    }

    static func dismantleNSView(_ field: MountedFocusTextField, coordinator: Coordinator) {
        field.cancelPendingFocus()
        field.delegate = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusTextField
        var lastFocusToken: UUID

        init(_ parent: FocusTextField) {
            self.parent = parent
            lastFocusToken = parent.focusToken
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  parent.text != field.stringValue else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
            default:
                return false
            }
            return true
        }
    }
}

final class MountedFocusTextField: NSTextField {
    var selectAllOnRequestedFocus = false
    private var focusGeneration: UInt = 0
    private var wantsFocus = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { requestFocus() }
        else { focusGeneration &+= 1 }
    }

    func requestFocus() {
        wantsFocus = true
        focusGeneration &+= 1
        let generation = focusGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFocus, self.focusGeneration == generation,
                  let window = self.window else { return }
            guard window.makeFirstResponder(self) else { return }
            self.wantsFocus = false
            if self.selectAllOnRequestedFocus { self.selectText(nil) }
        }
    }

    func cancelPendingFocus() {
        wantsFocus = false
        focusGeneration &+= 1
    }
}
