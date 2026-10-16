import AppKit

/// A chip of the row of fields of a card (R94): a capsule with an icon and a value for what is set, the icon alone,
/// light and thin, for what is not. It is a stop of its own for Tab (R62), whatever "Keyboard navigation" says.
@MainActor
final class ChipButton: NSButton {
    let chip: CardChip
    var symbol: String?
    var text = ""
    var tint: NSColor = .secondaryLabelColor
    /// A field that is not set.
    var plain = false
    /// Tab and ⇧Tab: one chip on or back.
    var onStep: (Int) -> Void = { _ in }
    /// Space and Return: what a click does.
    var onOpen: () -> Void = {}
    /// Esc: the card is done with.
    var onCancel: () -> Void = {}
    /// The keyboard came or left.
    var onFocus: (Bool) -> Void = { _ in }

    init(_ chip: CardChip) {
        self.chip = chip
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self
        action = #selector(clicked)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var chipFont: NSFont { AppFont.native(plain ? .body : .caption) }

    private var content: NSAttributedString {
        let text = NSMutableAttributedString()
        let color = plain ? NSColor.tertiaryLabelColor : tint
        if let symbol, let image = NSImage.symbol(symbol, chipFont, weight: plain ? .light : .regular) {
            let attachment = NSTextAttachment()
            attachment.image = image
            let size = image.size
            attachment.bounds = NSRect(x: 0, y: (chipFont.capHeight - size.height) / 2, width: size.width, height: size.height)
            text.append(NSAttributedString(attachment: attachment))
            if !self.text.isEmpty { text.append(NSAttributedString(string: " ")) }
        }
        if !self.text.isEmpty { text.append(NSAttributedString(string: self.text)) }
        text.addAttributes([.font: chipFont, .foregroundColor: color], range: NSRange(location: 0, length: text.length))
        return text
    }

    override var intrinsicContentSize: NSSize {
        let size = content.size()
        return NSSize(width: ceil(size.width) + 12, height: ceil(max(size.height, TaskTableMetrics.lineHeight(chipFont))) + 4)
    }

    func refresh() {
        invalidateIntrinsicContentSize()
        setAccessibilityLabel(toolTip ?? text)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if !plain {
            tint.withAlphaComponent(0.12).setFill()
            capsule.fill()
        }
        let size = content.size()
        content.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
        // The chip with the keyboard is outlined (R62).
        if window?.firstResponder === self {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2 - 1, yRadius: bounds.height / 2 - 1)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override var isFlipped: Bool { false }

    // Its own stop, not the key loop of the window: chips are tab stops there only with "Keyboard navigation" on.
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        onFocus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        onFocus(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 48: onStep(event.modifierFlags.contains(.shift) ? -1 : 1)
        case 49, 36, 76: onOpen()
        case 53: onCancel()
        default: super.keyDown(with: event)
        }
    }

    @objc private func clicked() { onOpen() }
}

/// The row of fields of a card (R94): what is set stands at the left with its value and wraps onto more lines, the rest
/// stands at the right as icons. Tab walks the chips in the order they are drawn (R62).
@MainActor
final class CardChipsView: NSView {
    private(set) var left: [ChipButton] = []
    private(set) var right: [ChipButton] = []

    /// The chips in the order they are drawn, which is the order Tab walks them in.
    var stops: [ChipButton] { left + right }

    func set(left: [ChipButton], right: [ChipButton]) {
        let keep = Set((left + right).map(ObjectIdentifier.init))
        for chip in stops where !keep.contains(ObjectIdentifier(chip)) { chip.removeFromSuperview() }
        self.left = left
        self.right = right
        for chip in left + right where chip.superview !== self { addSubview(chip) }
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    private struct Placed { var frames: [ObjectIdentifier: NSRect]; var height: CGFloat }

    private func place(width: CGFloat) -> Placed {
        var frames: [ObjectIdentifier: NSRect] = [:]
        let gap: CGFloat = 6
        // The icons at the right, side by side.
        let rightWidth = right.reduce(0) { $0 + $1.intrinsicContentSize.width } + CGFloat(max(right.count - 1, 0)) * 2
        let lineHeight = (left + right).map(\.intrinsicContentSize.height).max() ?? 0
        var x = width - rightWidth
        for chip in right {
            let size = chip.intrinsicContentSize
            frames[ObjectIdentifier(chip)] = NSRect(x: x, y: (lineHeight - size.height) / 2, width: size.width, height: size.height)
            x += size.width + 2
        }
        // What is set, wrapped at the room left of the icons.
        let room = max(width - rightWidth - 8, 1)
        var cx: CGFloat = 0, cy: CGFloat = 0, rowHeight: CGFloat = 0
        for chip in left {
            let size = chip.intrinsicContentSize
            if cx > 0, cx + size.width > room {
                cx = 0
                cy += rowHeight + gap
                rowHeight = 0
            }
            frames[ObjectIdentifier(chip)] = NSRect(x: cx, y: cy, width: min(size.width, room), height: size.height)
            cx += size.width + gap
            rowHeight = max(rowHeight, size.height)
        }
        return Placed(frames: frames, height: max(cy + rowHeight, lineHeight))
    }

    func height(width: CGFloat) -> CGFloat { ceil(place(width: width).height) }

    override func layout() {
        super.layout()
        let placed = place(width: bounds.width)
        for chip in stops { chip.frame = placed.frames[ObjectIdentifier(chip)] ?? .zero }
    }
}

/// A menu of AppKit from the choices of a chip, opened under it and kept until it closes.
@MainActor
final class ChoiceMenu: NSObject {
    private var actions: [() -> Void] = []

    func show(_ choices: [MenuChoice], under view: NSView) {
        view.window?.makeFirstResponder(view)
        menu(choices).popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }

    func menu(_ choices: [MenuChoice]) -> NSMenu {
        let menu = NSMenu()
        actions = choices.map(\.action)
        for (index, choice) in choices.enumerated() {
            if choice.isHeader {
                menu.addItem(.separator())
                menu.addItem(.sectionHeader(title: choice.title))
                continue
            }
            let item = NSMenuItem(title: choice.title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = choice.on == true ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard actions.indices.contains(item.tag) else { return }
        actions[item.tag]()
    }
}
