import AppKit

/// A popover of a card with an AppKit view in it (#308). Esc closes the popover and then does what Esc does in the
/// card (R62).
@MainActor
final class CardPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    /// Called once the popover is gone, however it closed.
    var onClose: () -> Void = {}
    /// Esc in the popover, once the popover is closed.
    var onCancel: () -> Void = {}

    init(_ view: NSView) {
        super.init()
        let controller = NSViewController()
        let box = PopoverBox(frame: NSRect(origin: .zero, size: view.frame.size))
        box.onCancel = { [weak self] in
            self?.close()
            self?.onCancel()
        }
        view.autoresizingMask = [.width, .height]
        box.addSubview(view)
        controller.view = box
        popover.contentSize = view.frame.size
        (view as? RepeatPopoverView)?.onResize = { [weak self] size in self?.popover.contentSize = size }
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
    }

    func show(under anchor: NSView) {
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        // The date popover hands the keyboard to its calendar, whose arrows move the day (R39).
        if let content = popover.contentViewController?.view, let picker = Self.calendar(in: content) {
            content.window?.makeFirstResponder(picker)
        }
    }

    private static func calendar(in view: NSView) -> NSDatePicker? {
        if let picker = view as? NSDatePicker, picker.datePickerStyle == .clockAndCalendar { return picker }
        return view.subviews.lazy.compactMap(calendar(in:)).first
    }

    func close() { popover.performClose(nil) }

    var isShown: Bool { popover.isShown }

    func popoverDidClose(_ notification: Notification) { onClose() }
}

/// The content of a popover of a card: Esc anywhere in it closes the popover (R62).
private final class PopoverBox: NSView {
    var onCancel: () -> Void = {}

    override func cancelOperation(_ sender: Any?) { onCancel() }
}

/// The choice of a date with an optional time, with the common choices one key away (R39): the start, the due date and
/// the reminder of a card.
@MainActor
final class DatePopoverView: NSView {
    private let value: String?
    private let timeRequired: Bool
    private let apply: (String?) -> Void
    /// Closes the popover the view is in.
    var dismiss: () -> Void = {}

    private let calendar = NSDatePicker()
    private let time = NSDatePicker()
    private let withTime = NSButton(checkboxWithTitle: L("Time"), target: nil, action: nil)

    init(title: String, value: String?, timeRequired: Bool = false, apply: @escaping (String?) -> Void) {
        self.value = value
        self.timeRequired = timeRequired
        self.apply = apply
        super.init(frame: .zero)

        var date = Date()
        if let value, let parsed = Moment.date(value) {
            date = parsed
        } else if timeRequired {
            date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(86400)) ?? Date()
        }
        calendar.datePickerStyle = .clockAndCalendar
        calendar.datePickerElements = .yearMonthDay
        calendar.dateValue = date
        calendar.isBordered = false
        calendar.drawsBackground = false
        time.datePickerStyle = .textFieldAndStepper
        time.datePickerElements = .hourMinute
        time.dateValue = date
        time.target = self
        time.action = #selector(timeChanged)
        calendar.target = self
        calendar.action = #selector(dayChanged)
        withTime.state = timeRequired || value.map(Moment.hasTime) == true ? .on : .off
        withTime.target = self
        withTime.action = #selector(timeToggled)
        withTime.isHidden = timeRequired

        let heading = NSTextField(labelWithString: title)
        heading.font = AppFont.native(.headline)

        let choices = NSStackView(views: [
            keyed(L("Today"), key: "T", days: 0),
            keyed(L("Tomorrow"), key: "M", days: 1),
            keyed(L("In a week"), key: "W", days: 7),
            hint(L("1–9  in that many days")),
            hint(L("+ −  a day later, earlier")),
        ])
        choices.orientation = .vertical
        choices.alignment = .leading
        choices.spacing = 6

        let middle = NSStackView(views: [calendar, choices])
        middle.alignment = .top
        middle.spacing = 12

        let timeRow = NSStackView(views: [withTime, time])
        timeRow.spacing = 8

        let done = NSButton(title: L("Done"), target: self, action: #selector(confirm))
        done.keyEquivalent = "\r"
        var bottom: [NSView] = []
        if value != nil {
            let remove = NSButton(title: L("Remove") + "  ⌫", target: self, action: #selector(remove))
            remove.hasDestructiveAction = true
            bottom.append(remove)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottom += [spacer, done]
        let buttons = NSStackView(views: bottom)

        let stack = NSStackView(views: [heading, middle, timeRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: middle.widthAnchor),
        ])
        timeToggled()
        frame.size = fittingSize
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The calendar takes the keyboard first: its arrows move the day.
    override var acceptsFirstResponder: Bool { false }

    var calendarPicker: NSDatePicker { calendar }

    private func keyed(_ title: String, key: String, days: Int) -> NSButton {
        let button = NSButton(title: "\(title)  \(key)", target: self, action: #selector(choose(_:)))
        button.tag = days
        button.controlSize = .small
        return button
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = AppFont.native(.caption)
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc private func timeToggled() { time.isHidden = withTime.state != .on }

    /// The calendar and the time field show one moment.
    @objc private func dayChanged() {
        time.dateValue = merged(day: calendar.dateValue, time: time.dateValue)
    }

    @objc private func timeChanged() {
        calendar.dateValue = merged(day: calendar.dateValue, time: time.dateValue)
    }

    private var date: Date { merged(day: calendar.dateValue, time: time.dateValue) }

    private func merged(day: Date, time: Date) -> Date {
        let clock = Calendar.current.dateComponents([.hour, .minute], from: time)
        return Calendar.current.date(bySettingHour: clock.hour ?? 9, minute: clock.minute ?? 0, second: 0, of: day) ?? day
    }

    private var timed: Bool { withTime.state == .on }

    @objc private func confirm() {
        apply(Moment.string(date, withTime: timed))
        dismiss()
    }

    @objc private func remove() {
        apply(nil)
        dismiss()
    }

    @objc private func choose(_ sender: NSButton) { pick(days: sender.tag) }

    private func pick(days: Int) {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: Date())) ?? Date()
        let chosen = merged(day: day, time: time.dateValue)
        self.calendar.dateValue = chosen
        apply(Moment.string(chosen, withTime: timed))
        dismiss()
    }

    /// The common choices from the keyboard (R39), before the calendar or a button takes the press. The time field keeps
    /// its keys while it is typed into; Return confirms from there as well.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else {
            return super.performKeyEquivalent(with: event)
        }
        return press(code: event.keyCode) || super.performKeyEquivalent(with: event)
    }

    /// What a key with this code does here; false when it does nothing.
    @discardableResult
    func press(code: UInt16) -> Bool {
        guard let key = DateKey(code: code), key == .confirm || !editingTime else { return false }
        switch key {
        case .confirm: confirm()
        case .pick(let days): pick(days: days)
        case .shift(let days):
            calendar.dateValue = Calendar.current.date(byAdding: .day, value: days, to: calendar.dateValue) ?? calendar.dateValue
            dayChanged()
        case .remove:
            guard value != nil else { return false }
            remove()
        }
        return true
    }

    /// The calendar and the time field are both date pickers; only the time field takes typing.
    private var editingTime: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === time { return true }
        return (responder as? NSView)?.isDescendant(of: time) == true
    }
}

/// What a key does in the date popover. Keys are told by their place on the
/// keyboard, not by the character, so every layout gives the same choices.
enum DateKey: Equatable {
    case pick(days: Int), shift(days: Int), remove, confirm

    private static let digits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9,
    ]

    init?(code: UInt16) {
        switch code {
        case 17: self = .pick(days: 0) // T
        case 46: self = .pick(days: 1) // M
        case 13: self = .pick(days: 7) // W
        case 24, 69: self = .shift(days: 1) // = and + of the main block, + of the keypad
        case 27, 78: self = .shift(days: -1)
        case 51, 117: self = .remove // ⌫ and ⌦
        case 36, 76: self = .confirm // Return and Enter of the keypad
        default:
            guard let days = Self.digits[code] else { return nil }
            self = .pick(days: days)
        }
    }
}
