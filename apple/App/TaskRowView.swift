import AppKit

/// The row of the task table (#308). The selection is a quiet strip behind the row, as in the list before it, and not the
/// blue of the system; the text of the row keeps its colours while selected.
final class TaskRowView: NSTableRowView {
    /// Whether the row is an open card, which is set apart by its outline and not by the strip (R94).
    var isCard = false {
        didSet { if isCard != oldValue { needsDisplay = true } }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The outline of an open card reaches past the edges of the row.
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func drawSelection(in dirtyRect: NSRect) {
        guard !isCard else { return }
        // The strip covers the content of the row and leaves the space the rows keep between them.
        // The cell of an inset table starts past the edge of the row view; the strip follows the cell.
        let cell = subviews.first { $0 is NSTableCellView }?.frame ?? bounds
        let strip = NSRect(x: cell.minX, y: bounds.minY, width: cell.width, height: bounds.height).insetBy(dx: 0, dy: TaskTableMetrics.rowInset)
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: strip, xRadius: 6, yRadius: 6).fill()
    }
}
