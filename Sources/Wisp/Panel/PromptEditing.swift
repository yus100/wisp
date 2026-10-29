import AppKit
import WispCore

extension PromptEditing {
    /// Applies `action` through the field editor, so it updates the binding and joins the undo stack.
    @MainActor
    static func apply(_ action: Action, to editor: NSTextView) {
        switch action {
        case .toStart:
            let selected = editor.selectedRange()
            let end = selected.location + selected.length
            guard end > 0 else { return }
            editor.setSelectedRange(NSRange(location: 0, length: end))
            editor.deleteBackward(nil)
        case .wordBackward:
            editor.deleteWordBackward(nil)
        }
    }
}
