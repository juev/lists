import AppKit

/// A text view that shows its text as Markdown while it is typed (R48–R52).
///
/// The string stays what was typed: the core says which ranges to style, hide
/// and replace, and this view does it with attributes and at the glyph level,
/// so nothing but typing, Return in a list and a click on a checkbox changes
/// the text.
class MarkdownTextView: NSTextView, NSLayoutManagerDelegate {
    /// The font of plain text; headings and code are derived from it.
    var baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize) {
        didSet { if baseFont != oldValue { restyle() } }
    }
    /// A checkbox was clicked and the text has changed.
    var onToggle: () -> Void = {}

    private var concealed = IndexSet()
    private var bullets = IndexSet()
    private var boxes: [(range: NSRange, checked: Bool)] = []
    private var links: [(range: NSRange, url: String)] = []
    private var quotes: [NSRange] = []
    private var rules: [NSRange] = []
    private var codeBlocks: [NSRange] = []
    /// R60: the bars that stand for a tab between two cells, and the tables drawn as a grid.
    private var cellTabs = IndexSet()
    private var grids: [(header: NSRange, width: CGFloat)] = []
    private var styledWidth: CGFloat = 0
    private var activeBlocks: [NSRange] = []
    private var blocks: [NSRange] = []
    private var focused = false

    /// TextKit 1: hiding works on glyphs, which TextKit 2 does not expose.
    func prepare() {
        layoutManager?.delegate = self
        isRichText = false
    }

    func setText(_ text: String) {
        string = text
        restyle()
    }

    // MARK: Styling

    override func didChangeText() {
        super.didChangeText()
        restyle()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting, focused, active(in: blocks) != activeBlocks { restyle() }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focused = true; restyle() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focused = false; restyle() }
        return resigned
    }

    /// The blocks the selection touches; their markup shows. None without the keyboard.
    private func active(in blocks: [NSRange]) -> [NSRange] {
        guard focused else { return [] }
        let selection = selectedRange()
        return blocks.filter { $0.location <= NSMaxRange(selection) && selection.location <= NSMaxRange($0) }
    }

    private func derived(_ font: NSFont, _ traits: NSFontDescriptor.SymbolicTraits, size: CGFloat? = nil) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: size ?? font.pointSize) ?? font
    }

    private func restyle() {
        // Attributes set under text that is still being composed would end the composition.
        guard let storage = textStorage, let layout = layoutManager, !hasMarkedText() else { return }
        let info = markdownLayout(text: string)
        let length = storage.length
        let full = NSRange(location: 0, length: length)
        let text = storage.string as NSString
        blocks = info.blocks.map { NSRange(location: Int($0.start), length: Int($0.end - $0.start)) }
        activeBlocks = active(in: blocks)
        let selection = selectedRange()
        let dim = NSColor.tertiaryLabelColor
        let plain: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor.secondaryLabelColor]

        var hidden = IndexSet(), bullets = IndexSet(), tabs = IndexSet()
        boxes = []; links = []; quotes = []; rules = []; codeBlocks = []; grids = []
        styledWidth = textContainer?.size.width ?? 0

        // R60: the tables to draw as a grid, each with the lines of its rows. A table
        // stays as typed while the cursor is in it, and where it does not start its
        // line: in a list item or a quote.
        var tables: [(table: MarkdownTable, lines: [NSRange], rule: NSRange)] = []
        for table in info.tables {
            let range = NSRange(location: Int(table.start), length: Int(table.end - table.start))
            guard NSMaxRange(range) <= length, Int(table.block) < blocks.count, !activeBlocks.contains(blocks[Int(table.block)]),
                  text.lineRange(for: NSRange(location: range.location, length: 0)).location == range.location else { continue }
            var lines: [NSRange] = []
            text.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, line, _, _ in lines.append(line) }
            guard lines.count == table.rows.count + 1 else { continue }
            tables.append((table, [lines[0]] + lines[2...], lines[1]))
        }
        let inGrid = { (range: NSRange) in tables.contains { $0.lines.contains { NSIntersectionRange($0, range).length > 0 } || $0.rule == range } }

        func retrait(_ range: NSRange, _ change: (NSFont) -> NSFont) {
            storage.enumerateAttribute(.font, in: range) { value, run, _ in
                if let font = value as? NSFont { storage.addAttribute(.font, value: change(font), range: run) }
            }
        }
        func indent(_ range: NSRange, first: CGFloat, rest: CGFloat) {
            let paragraph = text.paragraphRange(for: range)
            let current = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            let style = (current?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.firstLineHeadIndent += first
            style.headIndent += rest
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
        /// Markup that is a whole line, a code fence, leaves no empty line behind when hidden.
        func collapse(_ range: NSRange) {
            let line = text.lineRange(for: range)
            let content = text.substring(with: line).trimmingCharacters(in: .newlines)
            guard content.utf16.count == range.length, NSMaxRange(line) < length || line.location > 0 else { return }
            let style = NSMutableParagraphStyle()
            style.maximumLineHeight = 0.01
            storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .paragraphStyle: style], range: line)
        }
        let boxSide = ceil(baseFont.pointSize * 1.05)

        storage.beginEditing()
        storage.setAttributes(plain, range: full)
        for span in info.spans {
            let range = NSRange(location: Int(span.start), length: Int(span.end - span.start))
            guard NSMaxRange(range) <= length, Int(span.block) < blocks.count else { continue }
            let shown = activeBlocks.contains(blocks[Int(span.block)])
            switch span.kind {
            case .heading(let level):
                let scale: [CGFloat] = [1.5, 1.3, 1.15, 1, 1, 1]
                let size = baseFont.pointSize * scale[max(0, min(5, Int(level) - 1))]
                storage.addAttributes([.font: derived(baseFont, .bold, size: size), .foregroundColor: NSColor.labelColor], range: range)
            case .strong:
                retrait(range) { self.derived($0, .bold) }
            case .emphasis:
                retrait(range) { self.derived($0, .italic) }
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .code:
                retrait(range) { NSFont.monospacedSystemFont(ofSize: $0.pointSize * 0.95, weight: .regular) }
                storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range)
            case .codeBlock:
                retrait(range) { NSFont.monospacedSystemFont(ofSize: $0.pointSize * 0.95, weight: .regular) }
                codeBlocks.append(range)
            case .tableRow:
                if !inGrid(range) { retrait(range) { NSFont.monospacedSystemFont(ofSize: $0.pointSize * 0.95, weight: .regular) } }
            case .quote:
                quotes.append(range)
                indent(range, first: 12, rest: 12)
            case .link(let url):
                links.append((range, url))
                storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            case .listMarker(let ordered):
                if shown, !ordered { storage.addAttribute(.foregroundColor, value: dim, range: range) }
                if !ordered, !shown, range.length == 1 { bullets.insert(range.location) }
                // Wrapped lines of an item start under its text, not under its marker. Not
                // so behind a hidden quote sign: a line that begins with hidden glyphs is
                // set at the indent of the wrapped ones, and the marker would move.
                let line = text.lineRange(for: range)
                if !hidden.contains(line.location) {
                    let lead = text.substring(with: NSRange(location: line.location, length: NSMaxRange(range) - line.location)) + " "
                    indent(range, first: 0, rest: (lead as NSString).size(withAttributes: [.font: baseFont]).width)
                }
            case .quoteMarker:
                if shown { storage.addAttribute(.foregroundColor, value: dim, range: range) } else { hidden.insert(integersIn: range.location..<NSMaxRange(range)) }
            case .checkbox(let checked):
                // The brackets come back only when the cursor is right at them.
                let touched = focused && selection.location <= NSMaxRange(range) && range.location <= NSMaxRange(selection)
                if touched || range.length != 3 {
                    storage.addAttribute(.foregroundColor, value: dim, range: range)
                } else {
                    let mark = NSRange(location: range.location + 1, length: 1)
                    let width = (text.substring(with: mark) as NSString).size(withAttributes: [.font: baseFont]).width
                    hidden.insert(range.location)
                    hidden.insert(range.location + 2)
                    storage.addAttributes([.font: baseFont, .foregroundColor: NSColor.clear, .kern: boxSide - width], range: mark)
                    boxes.append((range, checked))
                }
            case .rule:
                if shown {
                    storage.addAttribute(.foregroundColor, value: dim, range: range)
                } else {
                    rules.append(range)
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
                }
            case .markup:
                if shown {
                    storage.addAttribute(.foregroundColor, value: dim, range: range)
                } else {
                    hidden.insert(integersIn: range.location..<NSMaxRange(range))
                    collapse(range)
                }
            }
        }
        for (table, lines, rule) in tables {
            let cells = table.rows.map { $0.cells.map { NSRange(location: Int($0.start), length: Int($0.end - $0.start)) } }
            let columns = table.columns.count
            // What the parser made of a row has to lie in its line, in order; otherwise the table stays as typed.
            let sound = columns > 0 && zip(cells, lines).allSatisfy { row, line in
                row.count == columns && row.first!.location >= line.location && NSMaxRange(row.last!) <= NSMaxRange(line)
                    && zip(row, row.dropFirst()).allSatisfy { NSMaxRange($0) <= $1.location }
            }
            for (row, header) in zip(cells, table.rows.map(\.header)) where sound && header {
                row.forEach { cell in retrait(cell) { self.derived($0, .bold) } }
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSUnionRange(row.first!, row.last!))
            }
            /// The width of a cell as it is seen: without the markup hidden in it.
            func width(_ cell: NSRange) -> CGFloat {
                let seen = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: cell))
                for index in (0..<cell.length).reversed() where hidden.contains(cell.location + index) {
                    seen.deleteCharacters(in: NSRange(location: index, length: 1))
                }
                return ceil(seen.size().width)
            }
            let widths = sound ? cells.map { $0.map(width) } : []
            let column = (0..<columns).map { index in widths.map { $0[index] }.max() ?? 0 }
            let gap = ceil(baseFont.pointSize * 1.4)
            let total = column.reduce(0, +) + gap * CGFloat(max(0, columns - 1))
            // A grid is not wrapped: a table wider than the note stays as typed.
            guard sound, styledWidth <= 0 || total <= styledWidth else {
                for line in lines + [rule] { retrait(line) { NSFont.monospacedSystemFont(ofSize: $0.pointSize * 0.95, weight: .regular) } }
                continue
            }
            var stops: [NSTextTab] = [], left: CGFloat = 0
            for index in 0..<columns {
                if index > 0 {
                    switch table.columns[index] {
                    case .right: stops.append(NSTextTab(textAlignment: .right, location: left + column[index]))
                    case .center: stops.append(NSTextTab(textAlignment: .center, location: left + column[index] / 2))
                    default: stops.append(NSTextTab(textAlignment: .left, location: left))
                    }
                }
                left += column[index] + gap
            }
            for (number, (row, line)) in zip(cells, lines).enumerated() {
                hidden.insert(integersIn: line.location..<row[0].location)
                hidden.insert(integersIn: NSMaxRange(row[columns - 1])..<NSMaxRange(line))
                for (cell, next) in zip(row, row.dropFirst()) {
                    let between = NSRange(location: NSMaxRange(cell), length: next.location - NSMaxRange(cell))
                    let bar = text.range(of: "|", range: between)
                    for index in between.location..<NSMaxRange(between) {
                        if index == bar.location { tabs.insert(index) } else { hidden.insert(index) }
                    }
                }
                let style = NSMutableParagraphStyle()
                style.tabStops = stops
                style.lineBreakMode = .byClipping
                style.paragraphSpacing = 3
                // The first cell has no tab before it: it is moved by the indent of its line.
                let spare = column[0] - widths[number][0]
                style.firstLineHeadIndent = table.columns[0] == .right ? spare : table.columns[0] == .center ? spare / 2 : 0
                storage.addAttribute(.paragraphStyle, value: style, range: text.paragraphRange(for: line))
            }
            // The line of dashes takes no room.
            hidden.insert(integersIn: rule.location..<NSMaxRange(rule))
            let gone = NSMutableParagraphStyle()
            gone.maximumLineHeight = 0.01
            storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .paragraphStyle: gone], range: text.lineRange(for: rule))
            grids.append((lines[0], total))
        }
        storage.endEditing()
        typingAttributes = plain

        if hidden != concealed || bullets != self.bullets || tabs != cellTabs {
            concealed = hidden
            self.bullets = bullets
            cellTabs = tabs
            layout.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            layout.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    // MARK: Glyphs

    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
        font: NSFont, forGlyphRange range: NSRange
    ) -> Int {
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: range.length))
        var newProperties = Array(UnsafeBufferPointer(start: properties, count: range.length))
        var changed = false
        for i in 0..<range.length {
            let character = characterIndexes[i]
            if concealed.contains(character) {
                newProperties[i] = .null
                changed = true
            } else if cellTabs.contains(character) {
                newProperties[i] = .controlCharacter
                changed = true
            } else if bullets.contains(character) {
                var bullet: [UniChar] = [0x2022]
                var glyph: [CGGlyph] = [0]
                if CTFontGetGlyphsForCharacters(font as CTFont, &bullet, &glyph, 1) {
                    newGlyphs[i] = glyph[0]
                    changed = true
                }
            }
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(newGlyphs, properties: newProperties, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
        return range.length
    }

    /// R60: the bar between two cells of a grid acts as a tab to the next column.
    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        cellTabs.contains(charIndex) ? .horizontalTab : action
    }

    /// Whether a table fits depends on the width, so the note is styled again when that changes.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let width = textContainer?.size.width, width != styledWidth, !markdownLayout(text: string).tables.isEmpty { restyle() }
    }

    // MARK: Drawing

    private func rect(of range: NSRange) -> NSRect? {
        guard let layout = layoutManager, let container = textContainer, NSMaxRange(range) <= (textStorage?.length ?? 0) else { return nil }
        // Hidden glyphs have no place of their own and would stretch the rectangle.
        var range = range
        while range.length > 1, concealed.contains(range.location) { range = NSRange(location: range.location + 1, length: range.length - 1) }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    private func boxRect(_ range: NSRange) -> NSRect? {
        guard let mark = rect(of: NSRange(location: range.location + 1, length: 1)) else { return nil }
        let side = ceil(baseFont.pointSize * 1.05)
        return NSRect(x: mark.minX, y: mark.midY - side / 2, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        for quote in quotes {
            guard let rect = rect(of: quote) else { continue }
            NSRect(x: textContainerOrigin.x, y: rect.minY, width: 3, height: rect.height).fill()
        }
        for rule in rules {
            guard let rect = rect(of: rule) else { continue }
            NSRect(x: textContainerOrigin.x, y: rect.midY, width: bounds.width - textContainerOrigin.x * 2, height: 1).fill()
        }
        for grid in grids {
            guard let rect = rect(of: grid.header) else { continue }
            NSRect(x: textContainerOrigin.x, y: rect.maxY + 1, width: grid.width, height: 1).fill()
        }
        NSColor.quaternaryLabelColor.setFill()
        for block in codeBlocks {
            guard let rect = rect(of: block) else { continue }
            let width = bounds.width - textContainerOrigin.x * 2
            NSBezierPath(roundedRect: NSRect(x: textContainerOrigin.x, y: rect.minY, width: width, height: rect.height), xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
        for box in boxes {
            guard let rect = boxRect(box.range) else { continue }
            let configuration = NSImage.SymbolConfiguration(pointSize: rect.height * 0.85, weight: .regular)
                .applying(.init(paletteColors: [box.checked ? .controlAccentColor : .secondaryLabelColor]))
            let name = box.checked ? "checkmark.square.fill" : "square"
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            image?.draw(in: rect.insetBy(dx: 1, dy: 1))
        }
    }

    // MARK: Clicks and Return

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !click(at: point, command: event.modifierFlags.contains(.command)) { super.mouseDown(with: event) }
    }

    /// Toggles the checkbox under the point, or with ⌘ opens the link there.
    @discardableResult
    func click(at point: NSPoint, command: Bool) -> Bool {
        if let box = boxes.first(where: { boxRect($0.range)?.insetBy(dx: -2, dy: -2).contains(point) == true }) {
            toggle(box.range, checked: box.checked)
            return true
        }
        guard command, let layout = layoutManager, let container = textContainer else { return false }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(inContainer) else { return false }
        let character = layout.characterIndexForGlyph(at: glyph)
        guard let link = links.first(where: { NSLocationInRange(character, $0.range) }), let url = URL(string: link.url) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    private func toggle(_ range: NSRange, checked: Bool) {
        replace(NSRange(location: range.location + 1, length: 1), with: checked ? " " : "x")
        onToggle()
    }

    /// An edit the way typing makes one, so that Undo takes it back.
    private func replace(_ range: NSRange, with text: String) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
    }

    /// Return in a list item or a quote (R52). False where it only starts a line.
    func continueList() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, !hasMarkedText(),
              let edit = markdownNewline(text: string, cursor: UInt32(selection.location)) else { return false }
        replace(NSRange(location: Int(edit.start), length: Int(edit.end - edit.start)), with: edit.text)
        setSelectedRange(NSRange(location: Int(edit.cursor), length: 0))
        scrollRangeToVisible(selectedRange())
        return true
    }

    #if DEBUG
    /// What a person would see, for the debug script: the hidden characters, the
    /// replaced ones and the fonts that differ from the plain one.
    var debugState: String {
        func list(_ set: IndexSet) -> String { set.rangeView.map { "\($0.lowerBound)..<\($0.upperBound)" }.joined(separator: ",") }
        var fonts: [String] = []
        if let storage = textStorage {
            storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
                guard let font = value as? NSFont, font != baseFont, font.pointSize > 1 else { return }
                let traits = font.fontDescriptor.symbolicTraits
                let marks = (traits.contains(.bold) ? "b" : "") + (traits.contains(.italic) ? "i" : "") + (traits.contains(.monoSpace) ? "m" : "")
                fonts.append("\(run.location)..<\(NSMaxRange(run)):\(marks)\(String(format: "%.1f", font.pointSize / baseFont.pointSize))")
            }
        }
        let visible = (string as NSString).length == 0 ? "" : String(string.utf16.enumerated().compactMap { index, unit -> Character? in
            if concealed.contains(index) { return nil }
            if bullets.contains(index) { return "•" }
            if cellTabs.contains(index) { return "\t" }
            if let box = boxes.first(where: { $0.range.location + 1 == index }) { return box.checked ? "☑" : "☐" }
            return UnicodeScalar(unit).map(Character.init) ?? "?"
        })
        let height = layoutManager.flatMap { layout in textContainer.map { layout.ensureLayout(for: $0); return layout.usedRect(for: $0).height } } ?? 0
        return "focused \(focused), text \(string.debugDescription), seen \(visible.debugDescription), hidden [\(list(concealed))], "
            + "boxes \(boxes.map { "\($0.range.location):\($0.checked)" }), links \(links.map(\.url)), quotes \(quotes.count), rules \(rules.count), code blocks \(codeBlocks.count), grids \(grids.map { Int($0.width) }), "
            + "fonts \(fonts), height \(String(format: "%.0f", height))"
    }

    /// Clicks the checkbox with this number through the same path as the mouse.
    func debugClickBox(_ index: Int) -> Bool {
        guard boxes.indices.contains(index), let rect = boxRect(boxes[index].range) else { return false }
        return click(at: NSPoint(x: rect.midX, y: rect.midY), command: false)
    }
    #endif
}
