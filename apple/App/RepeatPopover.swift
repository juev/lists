import AppKit

/// The choice of a repeat for a card: the presets first, the custom form only when asked for.
@MainActor
final class RepeatPopoverView: NSView {
    private let value: Repeat?
    private let apply: (Repeat?) -> Void
    /// Closes the popover the view is in.
    var dismiss: () -> Void = {}
    /// The form grew or shrank: the popover takes the new size.
    var onResize: (NSSize) -> Void = { _ in }

    private let presets = NSStackView()
    private let custom = NSStackView()

    private let interval = NSTextField()
    private let intervalStepper = NSStepper()
    private let freq = NSPopUpButton()
    private var weekdays: [NSButton] = []
    private let weekdayRow = NSStackView()
    private let byDay = NSButton(radioButtonWithTitle: L("On a day of the month"), target: nil, action: nil)
    private let byWeekday = NSButton(radioButtonWithTitle: L("On a day of the week"), target: nil, action: nil)
    private let nth = NSPopUpButton()
    private let nthWeekday = NSPopUpButton()
    private let monthRows = NSStackView()
    private let nthRow = NSStackView()
    private let fromDone = NSButton(checkboxWithTitle: L("Count from the completion date"), target: nil, action: nil)
    private let ending = NSPopUpButton()
    private let count = NSTextField()
    private let countStepper = NSStepper()
    private let countRow = NSStackView()
    private let until = NSDatePicker()

    private static let freqs: [Freq] = [.daily, .weekly, .monthly, .yearly]
    private static let nths = [1, 2, 3, 4, 5, -1]

    init(value: Repeat?, apply: @escaping (Repeat?) -> Void) {
        self.value = value
        self.apply = apply
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 10))
        buildPresets()
        buildCustom()
        let root = NSStackView(views: [presets, custom])
        root.orientation = .vertical
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 280),
        ])
        load()
        showCustom(value.map { $0.presetName == nil } ?? false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildPresets() {
        presets.orientation = .vertical
        presets.alignment = .leading
        presets.spacing = 8
        for (index, (name, _)) in Repeat.presets.enumerated() {
            let button = NSButton(title: name, target: self, action: #selector(preset(_:)))
            button.isBordered = false
            button.tag = index
            if value?.presetName == name { button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil); button.imagePosition = .imageTrailing }
            presets.addArrangedSubview(button)
        }
        presets.addArrangedSubview(NSBox.separator())
        let more = NSButton(title: L("Custom…"), target: self, action: #selector(openCustom))
        more.isBordered = false
        presets.addArrangedSubview(more)
        if value != nil {
            let off = NSButton(title: L("Do not repeat"), target: self, action: #selector(noRepeat))
            off.isBordered = false
            off.contentTintColor = .systemRed
            presets.addArrangedSubview(off)
        }
    }

    private func buildCustom() {
        custom.orientation = .vertical
        custom.alignment = .leading
        custom.spacing = 10

        interval.isEditable = false
        interval.isBordered = false
        interval.drawsBackground = false
        interval.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        intervalStepper.minValue = 1
        intervalStepper.maxValue = 999
        intervalStepper.target = self
        intervalStepper.action = #selector(stepped)
        freq.addItems(withTitles: [L("days"), L("weeks"), L("months"), L("years")])
        freq.target = self
        freq.action = #selector(changed)
        let every = NSStackView(views: [NSTextField(labelWithString: L("Every")), interval, intervalStepper, freq])

        for day in 1...7 {
            let button = NSButton(title: Repeat.weekdayNames[day - 1], target: nil, action: nil)
            button.setButtonType(.pushOnPushOff)
            button.controlSize = .small
            button.tag = day
            weekdays.append(button)
            weekdayRow.addArrangedSubview(button)
        }
        weekdayRow.spacing = 4

        byDay.target = self
        byDay.action = #selector(changed)
        byWeekday.target = self
        byWeekday.action = #selector(changed)
        nth.addItems(withTitles: (1...5).map(ordinal) + [L("last")])
        nthWeekday.addItems(withTitles: Repeat.weekdayNames)
        nthRow.setViews([nth, nthWeekday], in: .leading)
        monthRows.orientation = .vertical
        monthRows.alignment = .leading
        monthRows.setViews([byDay, byWeekday, nthRow], in: .top)

        ending.addItems(withTitles: [L("Never"), L("After a number of repeats"), L("On a date")])
        ending.target = self
        ending.action = #selector(changed)
        let ends = NSStackView(views: [NSTextField(labelWithString: L("Ends")), ending])
        countStepper.minValue = 1
        countStepper.maxValue = 99
        countStepper.target = self
        countStepper.action = #selector(stepped)
        count.isEditable = false
        count.isBordered = false
        count.drawsBackground = false
        countRow.setViews([count, countStepper], in: .leading)
        until.datePickerElements = .yearMonthDay
        until.datePickerStyle = .textFieldAndStepper
        until.dateValue = Date().addingTimeInterval(30 * 86400)

        let back = NSButton(title: L("Back"), target: self, action: #selector(closeCustom))
        let done = NSButton(title: L("Done"), target: self, action: #selector(confirm))
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [back, spacer, done])

        for view in [every, weekdayRow, monthRows, fromDone, ends, countRow, until, buttons] { custom.addArrangedSubview(view) }
        buttons.widthAnchor.constraint(equalTo: custom.widthAnchor).isActive = true
    }

    private func load() {
        intervalStepper.integerValue = 1
        countStepper.integerValue = 5
        freq.selectItem(at: 1)
        byDay.state = .on
        guard let value else { return stepped() }
        freq.selectItem(at: Self.freqs.firstIndex(of: value.freq) ?? 1)
        intervalStepper.integerValue = Int(value.interval)
        for button in weekdays { button.state = value.weekdays.contains(UInt32(button.tag)) ? .on : .off }
        if let n = value.nth, let wd = value.nthWeekday {
            byWeekday.state = .on
            nth.selectItem(at: Self.nths.firstIndex(of: Int(n)) ?? 0)
            nthWeekday.selectItem(at: Int(wd) - 1)
        }
        fromDone.state = value.fromDone ? .on : .off
        if let c = value.count {
            ending.selectItem(at: 1)
            countStepper.integerValue = Int(c)
        } else if let u = value.until, let date = Moment.date(u) {
            ending.selectItem(at: 2)
            until.dateValue = date
        }
        stepped()
    }

    @objc private func stepped() {
        interval.stringValue = "\(intervalStepper.integerValue)"
        count.stringValue = L("Repeats: %@", "\(countStepper.integerValue)")
        changed()
    }

    /// Shows the controls the choices so far ask for.
    @objc private func changed() {
        let chosen = Self.freqs[max(freq.indexOfSelectedItem, 0)]
        weekdayRow.isHidden = chosen != .weekly
        monthRows.isHidden = chosen != .monthly
        nthRow.isHidden = byWeekday.state != .on
        countRow.isHidden = ending.indexOfSelectedItem != 1
        until.isHidden = ending.indexOfSelectedItem != 2
        resize()
    }

    private func showCustom(_ on: Bool) {
        presets.isHidden = on
        custom.isHidden = !on
        changed()
    }

    private func resize() {
        layoutSubtreeIfNeeded()
        let size = fittingSize
        setFrameSize(size)
        onResize(size)
    }

    private var rule: Repeat {
        let chosen = Self.freqs[max(freq.indexOfSelectedItem, 0)]
        let byWeekday = chosen == .monthly && self.byWeekday.state == .on
        return Repeat(
            freq: chosen,
            interval: UInt32(intervalStepper.integerValue),
            weekdays: chosen == .weekly ? weekdays.filter { $0.state == .on }.map { UInt32($0.tag) } : [],
            monthday: nil,
            nth: byWeekday ? Int32(Self.nths[max(nth.indexOfSelectedItem, 0)]) : nil,
            nthWeekday: byWeekday ? UInt32(nthWeekday.indexOfSelectedItem + 1) : nil,
            fromDone: fromDone.state == .on,
            count: ending.indexOfSelectedItem == 1 ? UInt32(countStepper.integerValue) : nil,
            until: ending.indexOfSelectedItem == 2 ? Moment.string(until.dateValue, withTime: false) : nil)
    }

    @objc private func preset(_ sender: NSButton) {
        apply(Repeat.presets[sender.tag].1)
        dismiss()
    }

    @objc private func openCustom() { showCustom(true) }
    @objc private func closeCustom() { showCustom(false) }

    @objc private func noRepeat() {
        apply(nil)
        dismiss()
    }

    @objc private func confirm() {
        apply(rule)
        dismiss()
    }
}

extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
