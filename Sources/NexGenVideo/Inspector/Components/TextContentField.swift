import AppKit
import SwiftUI

/// NSTextView-backed — SwiftUI `TextEditor`'s binding drops keystrokes when the parent re-renders per-apply.
struct TextContentField: NSViewRepresentable {
    @Environment(\.interfaceScale) private var interfaceScale
    @Binding var text: String
    let onEdit: () -> Void
    let onCommit: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ContentScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = ContentTextView()
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: CGFloat(AppTheme.Typography.ui * interfaceScale))
        textView.textColor = AppTheme.Text.primary
        textView.insertionPointColor = AppTheme.Text.primary
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(
            width: AppTheme.Spacing.xs,
            height: AppTheme.Spacing.xs
        )
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = context.coordinator
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? NSTextView else { return }
        let size = CGFloat(AppTheme.Typography.ui * interfaceScale)
        if textView.font?.pointSize != size { textView.font = .systemFont(ofSize: size) }
        // Don't stomp the insertion point mid-type.
        guard textView.window?.firstResponder !== textView else { return }
        if textView.string != text {
            textView.breakUndoCoalescing()
            textView.string = text
            textView.undoManager?.removeAllActions()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.commitPendingText()
        coordinator.textView?.delegate = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextContentField
        weak var textView: NSTextView?
        private var hasPendingCommit = false

        init(parent: TextContentField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            hasPendingCommit = true
            parent.onEdit()
            parent.text = textView.string
        }

        func textDidEndEditing(_ notification: Notification) {
            commitPendingText()
        }

        func commitPendingText() {
            guard let textView, hasPendingCommit else { return }
            hasPendingCommit = false
            textView.breakUndoCoalescing()
            parent.onCommit(textView.string)
            textView.undoManager?.removeAllActions()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                textView.window?.selectNextKeyView(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                textView.window?.selectPreviousKeyView(nil)
                return true
            }
            return false
        }
    }

    private final class ContentScrollView: NSScrollView {
        override func tile() {
            super.tile()
            guard let textView = documentView as? NSTextView else { return }
            let size = contentSize
            textView.minSize = NSSize(width: 0, height: size.height)
            if textView.frame.width != size.width {
                textView.setFrameSize(NSSize(width: size.width, height: textView.frame.height))
            }
            textView.sizeToFit()
        }
    }

    private final class ContentTextView: NSTextView {
        private let contentUndo = UndoManager()
        override var undoManager: UndoManager? { contentUndo }
    }
}
