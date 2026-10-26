import AppKit
import SwiftUI

/// Sizes of the rows of the task table (#308), taken from the list they replace: a row of one line is 24 points and the
/// spacing of R122 above and below its content, so 26, 30 and 40 points at the usual size of text; a row that names the
/// list of its task (R72) is a line of small text higher.
@MainActor
enum TaskTableMetrics {
    /// The space a row leaves above and below what it draws; the selection strip is drawn inside it.
    static let rowInset: CGFloat = 4

    /// The height of a line of text, as a label and SwiftUI give it: the ascender and the descender rounded up each.
    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender) + ceil(-font.descender) + ceil(font.leading) }

    /// R122: the height of the row of a task; `origin` is the second line of R72.
    static func taskRow(origin: Bool, spacing: String) -> CGFloat {
        var content = lineHeight(AppFont.native(.body))
        if origin { content += 2 + lineHeight(AppFont.native(.caption)) }
        return content + 2 * (rowInset + RowSpacing.padding(spacing))
    }

    /// How far a task of an open project stands to the right of the project (R30).
    static let depthIndent: CGFloat = 22

    /// R72: the space after the mark and after the bar of the priority, shared by the row and the open card, so the
    /// title stays close to the mark (#427).
    static let markGap: CGFloat = 3
    static let barGap: CGFloat = 4

    /// The field for a new task of an open project.
    static func newChildRow() -> CGFloat { lineHeight(AppFont.native(.callout)) + 8 + 2 * rowInset }

    /// R22: a subtask a search found its task by, a line under the row of the task.
    static func foundRow() -> CGFloat { lineHeight(AppFont.native(.body)) + 12 + 2 * rowInset }

    static func heading() -> CGFloat { lineHeight(headingFont) + 14 }

    static var headingFont: NSFont {
        let font = AppFont.native(.subheadline)
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    /// R78: the block of the events of the day.
    static func events(_ count: Int) -> CGFloat {
        CGFloat(count) * lineHeight(AppFont.native(.callout)) + CGFloat(max(count - 1, 0)) * 4 + 16 + 2 * rowInset
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var value: UInt64 = 0
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, Scanner(string: digits).scanHexInt64(&value) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }
}

extension NSFont {
    /// The same font with digits of one width, for dates and times that stand in a column.
    var monospacedDigits: NSFont {
        let settings: [[NSFontDescriptor.FeatureKey: Int]] = [[.typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector]]
        return NSFont(descriptor: fontDescriptor.addingAttributes([.featureSettings: settings]), size: pointSize) ?? self
    }
}

extension NSFont {
    /// The same font with another weight, its design kept.
    func weighted(_ weight: NSFont.Weight) -> NSFont {
        let traits: [NSFontDescriptor.TraitKey: Any] = [.weight: weight.rawValue]
        return NSFont(descriptor: fontDescriptor.addingAttributes([.traits: traits]), size: pointSize) ?? self
    }
}

extension NSImage {
    /// A symbol of the system sized to go with the text in that font.
    static func symbol(_ name: String, _ font: NSFont, weight: NSFont.Weight = .regular, label: String? = nil) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: weight))
    }
}

/// The round mark of a task or of a subtask (#427): a click completes it or takes it back into work.
@MainActor
final class TaskMarkButton: NSButton {
    private var task: TaskItem?

    convenience init() {
        self.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        target = self
        action = #selector(clicked)
    }

    func configure(_ task: TaskItem, model: AppModel) {
        self.task = task
        // The mark of a record of a repeat takes its completion back while it can (R128, R133); after that it is a repeat icon.
        let history = task.isLog && !task.undoable
        let symbol = history ? "repeat" : task.wont ? "xmark.circle.fill" : task.done != nil ? "checkmark.circle.fill" : "circle"
        // R94: the mark is as quiet as the icons of the fields; R72: a little smaller than the text.
        image = .symbol(symbol, AppFont.native(.callout), weight: .light)
        contentTintColor = task.done != nil ? .secondaryLabelColor : .tertiaryLabelColor
        isEnabled = !(task.deleted || history)
        setAccessibilityLabel(history ? L("Repeat") : task.done != nil ? L("Reopen") : L("Complete"))
        sizeToFit()
    }

    @objc private func clicked() {
        guard let task else { return }
        AppModel.shared.toggleDone(task)
    }
}

/// A view that fills itself with one colour, which follows the look of the window.
final class FillView: NSView {
    var color: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// The row of a task in the task table (R72, R73, R125, R35, R122, R61): the mark, the bar of the priority, the icon of a
/// project, the title with the marks of what is set, the list under it where lists are mixed, the date and the chevron.
@MainActor
final class TaskRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("task")

    private(set) var task: TaskItem?
    private let mark = TaskMarkButton()
    private let bar = FillView()
    private let folder = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let marks = NSStackView()
    private let origin = NSTextField(labelWithString: "")
    private let dateIcon = NSImageView()
    private let date = NSTextField(labelWithString: "")
    private let chevron = NSButton()
    private var spacing = "normal"
    /// R30, R31: a task of an open project is moved to the right under it.
    private var depth = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        bar.radius = 1.5
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        origin.lineBreakMode = .byTruncatingTail
        marks.orientation = .horizontal
        marks.spacing = 6
        chevron.isBordered = false
        chevron.imagePosition = .imageOnly
        chevron.target = self
        chevron.action = #selector(chevronClicked)
        chevron.setAccessibilityLabel(L("Expand"))
        for view in [mark, bar, folder, title, marks, origin, dateIcon, date, chevron] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ state: TaskRowState, model: AppModel) {
        let task = state.task
        let rowOrigin = state.origin
        let dayInHeading = state.dayInHeading
        self.task = task
        depth = state.depth
        spacing = model.rowSpacing
        let body = AppFont.native(.body)
        let caption = AppFont.native(.caption)
        mark.configure(task, model: model)

        // R72: the priority is a thin bar after the mark; its place is kept, so every title starts at one line.
        bar.color = Self.priorityBar(task.priority)
        bar.setAccessibilityLabel(task.priority.title)
        bar.setAccessibilityElement(task.priority != .none)

        folder.isHidden = !task.isProject
        folder.image = .symbol("folder", body, label: L("Project"))
        folder.contentTintColor = .secondaryLabelColor

        var attributes: [NSAttributedString.Key: Any] = [
            .font: body,
            .foregroundColor: task.done != nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        if task.done != nil { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        title.attributedStringValue = NSAttributedString(string: task.title, attributes: attributes)

        // Marks after the title, only for what is set, without text or numbers (R72).
        marks.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let shown: [(Bool, String, String)] = [
            (task.repeat != nil, "repeat", L("Repeat")),
            (!task.notes.isEmpty, "text.alignleft", L("Notes")),
            (task.attachments > 0, "paperclip", L("Attachments")),
            (task.subtasksTotal > 0, "checklist", L("Subtasks")),
        ]
        for (set, symbol, label) in shown where set {
            let icon = NSImageView(image: NSImage.symbol(symbol, caption, label: label) ?? NSImage())
            icon.contentTintColor = .tertiaryLabelColor
            marks.addArrangedSubview(icon)
        }

        // R72: where lists are mixed the row says under the title which list the task is in, in the colour of the list,
        // and a task of a project says whose it is (R31).
        origin.isHidden = rowOrigin == nil
        origin.attributedStringValue = rowOrigin.map { Self.originText($0, font: caption) } ?? NSAttributedString()

        // R125: a due date taken from the project is muted, with the project's mark before it.
        let shownDate = Moment.rowDate(due: task.effectiveDue, open: task.done == nil, dayInHeading: dayInHeading)
        let inherited = task.due == nil
        let dateColor: NSColor = shownDate?.late == true ? .systemRed : inherited ? .tertiaryLabelColor : .secondaryLabelColor
        date.isHidden = shownDate == nil
        date.font = caption.monospacedDigits
        date.stringValue = shownDate?.text ?? ""
        date.textColor = dateColor
        dateIcon.isHidden = shownDate == nil || !inherited
        dateIcon.image = .symbol("folder", caption, label: L("Project"))
        dateIcon.contentTintColor = dateColor

        chevron.image = .symbol("chevron.right", caption)
        chevron.contentTintColor = .tertiaryLabelColor
        needsLayout = true
    }

    static func originText(_ origin: RowOrigin, font: NSFont) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let list = origin.list {
            let color = origin.color.flatMap(NSColor.init(hex:)) ?? .controlAccentColor
            text.append(NSAttributedString(string: list, attributes: [.font: font, .foregroundColor: color]))
        }
        if let project = origin.project {
            let rest = origin.list == nil ? project : " – \(project)"
            text.append(NSAttributedString(string: rest, attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return text
    }

    /// R72: the colour of the bar a row shows for the priority of its task; none for a task without one.
    static func priorityBar(_ priority: Priority) -> NSColor? {
        switch priority {
        case .high: .systemRed
        case .medium: .systemOrange
        case .low: .systemBlue
        case .none: nil
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let inset: CGFloat = 6
        let gap: CGFloat = 8
        var x = inset + CGFloat(depth) * TaskTableMetrics.depthIndent

        // The title and the list under it stand as one block in the middle of the row; the mark, the project icon and
        // the date stand at the middle of the title line, so in a row of two lines they go with the title (#427).
        let titleHeight = TaskTableMetrics.lineHeight(AppFont.native(.body))
        let originHeight = TaskTableMetrics.lineHeight(AppFont.native(.caption))
        let twoLines = !origin.isHidden
        let block = twoLines ? titleHeight + 2 + originHeight : titleHeight
        let top = ((height + block) / 2).rounded()
        let titleY = top - titleHeight
        func onTitle(_ viewHeight: CGFloat) -> CGFloat { (titleY + (titleHeight - viewHeight) / 2).rounded() }

        let markSize = mark.fittingSize
        mark.frame = NSRect(x: x, y: onTitle(markSize.height), width: markSize.width, height: markSize.height)
        x += markSize.width + TaskTableMetrics.markGap
        let barHeight: CGFloat = twoLines ? 28 : 16
        bar.frame = NSRect(x: x, y: ((height - barHeight) / 2).rounded(), width: 3, height: barHeight)
        x += 3 + TaskTableMetrics.barGap
        if !folder.isHidden {
            let size = folder.image?.size ?? .zero
            folder.frame = NSRect(x: x, y: onTitle(size.height), width: size.width, height: size.height)
            x += size.width + gap
        }

        // From the right edge: the chevron, then the date.
        var right = bounds.width - inset
        chevron.frame = NSRect(x: right - 20, y: 0, width: 20, height: height)
        right -= 20
        if !date.isHidden {
            right -= gap
            let size = date.fittingSize
            date.frame = NSRect(x: right - size.width, y: onTitle(size.height), width: size.width, height: size.height)
            right -= size.width
            if !dateIcon.isHidden {
                let icon = dateIcon.image?.size ?? .zero
                right -= 3 + icon.width
                dateIcon.frame = NSRect(x: right, y: onTitle(icon.height), width: icon.width, height: icon.height)
            }
        }
        right -= gap

        // The title and its marks, and under them the list; each is cut at its own width.
        let marksWidth = marks.arrangedSubviews.isEmpty ? 0 : marks.fittingSize.width
        let room = max(right - x, 0)
        let titleWidth = min(title.fittingSize.width, max(room - (marksWidth > 0 ? marksWidth + gap : 0), 0))
        title.frame = NSRect(x: x, y: titleY, width: titleWidth, height: titleHeight)
        marks.frame = NSRect(x: x + titleWidth + gap, y: titleY, width: min(marksWidth, max(room - titleWidth - gap, 0)), height: titleHeight)
        origin.frame = NSRect(x: x, y: titleY - 2 - originHeight, width: room, height: originHeight)
    }

    @objc private func chevronClicked() {
        guard let task else { return }
        let model = AppModel.shared
        model.selection = task.id
        model.toggleExpanded(task.id)
    }
}

/// R22: a subtask a search found its task by, a line with its mark and title under the row of the task.
@MainActor
final class FoundRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("found")

    private let mark = TaskMarkButton()
    private let title = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        title.lineBreakMode = .byTruncatingTail
        addSubview(mark)
        addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ task: TaskItem, model: AppModel) {
        mark.configure(task, model: model)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: AppFont.native(.body),
            .foregroundColor: task.done != nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        if task.done != nil { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        title.attributedStringValue = NSAttributedString(string: task.title, attributes: attributes)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Under the title of the task: the place of its mark and bar, then the line's own padding.
        let x: CGFloat = 6 + 22
        let size = mark.fittingSize
        mark.frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        let line = TaskTableMetrics.lineHeight(AppFont.native(.body))
        let titleX = mark.frame.maxX + 8
        title.frame = NSRect(x: titleX, y: ((bounds.height - line) / 2).rounded(), width: max(bounds.width - titleX - 6, 0), height: line)
    }
}

/// The heading of a group of rows: a day, a list, "Overdue".
@MainActor
final class HeadingCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("heading")

    private let title = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        title.lineBreakMode = .byTruncatingTail
        title.textColor = .secondaryLabelColor
        title.setAccessibilityRole(.staticText)
        addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ text: String) {
        title.font = TaskTableMetrics.headingFont
        title.stringValue = text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let line = TaskTableMetrics.lineHeight(TaskTableMetrics.headingFont)
        title.frame = NSRect(x: 6, y: 4, width: max(bounds.width - 12, 0), height: line)
    }
}

/// R78: the events of the day, a line each; a click opens the calendar.
@MainActor
final class EventsCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("events")

    private let background = FillView()
    private var lines: [(bar: FillView, time: NSTextField, title: NSTextField)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        background.radius = 8
        background.color = NSColor.labelColor.withAlphaComponent(0.05)
        addSubview(background)
        // A click opens Calendar, counted the way the system counts a click: the button goes up over the block.
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ events: [DayEvent]) {
        lines.forEach { $0.bar.removeFromSuperview(); $0.time.removeFromSuperview(); $0.title.removeFromSuperview() }
        let font = AppFont.native(.callout)
        lines = events.map { event in
            let bar = FillView()
            bar.radius = 1.5
            bar.color = NSColor(event.color)
            let time = NSTextField(labelWithString: event.time ?? "")
            time.font = font.monospacedDigits
            time.textColor = .secondaryLabelColor
            time.isHidden = event.time == nil
            let title = NSTextField(labelWithString: event.title)
            title.font = font
            title.textColor = .secondaryLabelColor
            title.lineBreakMode = .byTruncatingTail
            for view in [bar, time, title] { addSubview(view) }
            return (bar, time, title)
        }
        setAccessibilityLabel(events.map { [$0.time, $0.title].compactMap { $0 }.joined(separator: " ") }.joined(separator: ", "))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let box = bounds.insetBy(dx: 0, dy: TaskTableMetrics.rowInset)
        background.frame = box
        let line = TaskTableMetrics.lineHeight(AppFont.native(.callout))
        var y = box.maxY - 8 - line
        for (bar, time, title) in lines {
            var x = box.minX + 10
            bar.frame = NSRect(x: x, y: y, width: 3, height: line)
            x += 3 + 6
            if !time.isHidden {
                let width = time.fittingSize.width
                time.frame = NSRect(x: x, y: y, width: width, height: line)
                x += width + 6
            }
            title.frame = NSRect(x: x, y: y, width: max(box.maxX - 10 - x, 0), height: line)
            y -= line + 4
        }
    }

    /// The press is the click's alone: the table does not follow it as the press on a row.
    override func mouseDown(with event: NSEvent) {}

    @objc private func clicked() { SystemCalendars.shared.openCalendar() }
}

/// The field for a new task of an open project, under its tasks (R30): Return adds the task and the field stays for the next one.
@MainActor
final class NewChildCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("newChild")

    private let icon = NSImageView()
    private let field = NSTextField()
    private var parent = ""
    private var depth = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = L("Subtask")
        field.target = self
        field.action = #selector(submit)
        icon.contentTintColor = .tertiaryLabelColor
        addSubview(icon)
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(parent: String, depth: Int) {
        if parent != self.parent { field.stringValue = "" }
        self.parent = parent
        self.depth = depth
        let font = AppFont.native(.callout)
        field.font = font
        icon.image = .symbol("plus.circle", font)
        needsLayout = true
    }

    @objc private func submit() {
        guard !field.stringValue.isEmpty else { return }
        if AppModel.shared.add(field.stringValue, parent: parent) != nil { field.stringValue = "" }
        window?.makeFirstResponder(field)
    }

    override func layout() {
        super.layout()
        let line = TaskTableMetrics.lineHeight(AppFont.native(.callout))
        let x = 6 + 28 + CGFloat(depth - 1) * TaskTableMetrics.depthIndent
        let size = icon.image?.size ?? .zero
        icon.frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        let fieldX = icon.frame.maxX + 6
        field.frame = NSRect(x: fieldX, y: ((bounds.height - line - 2) / 2).rounded(), width: max(bounds.width - fieldX - 6, 0), height: line + 2)
    }
}
