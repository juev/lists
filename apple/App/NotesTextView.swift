import AppKit
import SwiftUI

/// The notes of an open task: a text view that grows with its text and shows
/// it as Markdown (`MarkdownTextView`).
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
    /// Esc, where it means something else than finishing: the card of a new task is thrown away by it (R37).
    var onCancel: (() -> Void)?
    /// A checkbox in the note was clicked; the text is already changed.
    var onToggle: () -> Void = {}
    /// Tab was pressed: the keyboard moves on to the chips of the card (R62). ⌥Tab still types a tab.
    var onTab: (() -> Void)?
    /// The room the view keeps while its text is shorter, in lines: the quick-entry panel keeps three (R82).
    var minLines = 1

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MarkdownTextView {
        let view = PlainTextView()
        view.prepare()
        view.delegate = context.coordinator
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.baseFont = font
        view.onToggle = { [coordinator = context.coordinator] in coordinator.parent.onToggle() }
        view.setText(text)
        return view
    }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text { view.setText(text) }
        if view.baseFont != font { view.baseFont = font }
        if wantsFocus {
            DispatchQueue.main.async {
                guard let window = view.window else { return }
                window.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
                wantsFocus = false
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MarkdownTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        // The size is asked for before the view is updated: a card that has just taken the note of its task
        // would be measured with the text the view held before, an empty one, and stay one line high (#155).
        // Not while the note is being typed into: then the view holds the newer text of the two.
        if view.string != text, view.window?.firstResponder !== view { view.setText(text) }
        // Asked for an ideal size, the view has no width to wrap at: answer with
        // the width it has, never with the text view's own (zero) idea of it.
        let offered = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let width = offered ?? max(view.bounds.width, 240)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: view.baseFont)
        return CGSize(width: width, height: max(ceil(layout.usedRect(for: container).height), ceil(line) * CGFloat(minLines)))
    }

    /// Takes text only: a dropped file belongs to the card around the notes,
    /// which attaches it, and not in the text as a path.
    private final class PlainTextView: MarkdownTextView {
        override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
            super.acceptableDragTypes.filter { $0 != .fileURL && $0.rawValue != "NSFilenamesPboardType" }
        }
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
            case #selector(NSResponder.cancelOperation(_:)):
                (parent.onCancel ?? parent.onFinish)()
                return true
            case #selector(NSResponder.insertNewline(_:)) where !parent.returnAddsLine:
                parent.onFinish()
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                return (view as? MarkdownTextView)?.continueList() ?? false
            case #selector(NSResponder.insertTab(_:)):
                guard let onTab = parent.onTab else { return false }
                onTab()
                return true
            default:
                return false
            }
        }
    }
}
