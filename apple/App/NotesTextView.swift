import AppKit

/// Takes text only: a dropped file belongs to the card around the notes,
/// which attaches it, and not in the text as a path.
final class NoteTextView: MarkdownTextView {
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes.filter { $0 != .fileURL && $0.rawValue != "NSFilenamesPboardType" }
    }
}
