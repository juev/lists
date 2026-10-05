import AppKit
import SwiftUI

/// The notes of an open task: a text view that grows with its text.
///
/// AppKit rather than `TextEditor`: which key finishes editing is a setting,
/// and only the text view's own commands tell Return from ⌥Return reliably.
struct NotesTextView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    /// Return starts a new line; otherwise it finishes and ⌥Return starts one.
    var returnAddsLine: Bool
    /// Set to take the keyboard; the view clears it once it has.
    @Binding var wantsFocus: Bool
    var onEditingChanged: (Bool) -> Void
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textColor = .secondaryLabelColor
        view.string = text
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text { view.string = text }
        if view.font != font { view.font = font }
        if wantsFocus {
            DispatchQueue.main.async {
                guard let window = view.window else { return }
                window.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
                wantsFocus = false
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = view.textContainer, let layout = view.layoutManager
        else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: view.font ?? font)
        return CGSize(width: width, height: max(ceil(layout.usedRect(for: container).height), ceil(line)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesTextView

        init(_ parent: NotesTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
        }

        func textDidBeginEditing(_ notification: Notification) { parent.onEditingChanged(true) }

        func textDidEndEditing(_ notification: Notification) { parent.onEditingChanged(false) }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)) where !parent.returnAddsLine,
                 #selector(NSResponder.cancelOperation(_:)):
                parent.onFinish()
                return true
            default:
                return false
            }
        }
    }
}
