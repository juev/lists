import AppKit
import Quartz

/// What a row of a file asks of the card it is in.
@MainActor
struct FileActions {
    /// A click on the name: shows the file, or downloads a file that has not arrived and then shows it (R76).
    let open: (Attachment) -> Void
    let remove: (Attachment) -> Void
    /// The actions of the menu of a file that is here (R86, R91).
    let choices: (Attachment) -> [MenuChoice]
    /// Esc on the row: the card is done with (R54).
    let cancel: () -> Void
}

/// A file of an open card: its icon or a thumbnail (R55), its name, its size or what is happening to it (R76), the
/// button of its menu and the one that removes it. After a click on the name the row has the keyboard: Space shows the
/// file again in Quick Look and Esc closes the card (R54).
@MainActor
final class FileRowView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let iconSide: CGFloat = 28

    private(set) var file: Attachment
    private let actions: FileActions
    private let icon = NSImageView()
    private let name = NSButton()
    private let pointer = FilePointerView()
    private let caption = NSTextField(labelWithString: "")
    private let more = NSButton()
    private let remove = NSButton()
    private let menus = ChoiceMenu()
    private var thumbnailFor: String?
    /// The files the panel pages through, and the one it starts at.
    private var previewable: [URL] = []
    private var previewed = 0
    /// The keyboard came or left.
    var onFocus: (Bool) -> Void = { _ in }

    init(file: Attachment, actions: FileActions) {
        self.file = file
        self.actions = actions
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 4
        icon.layer?.masksToBounds = true
        name.isBordered = false
        name.target = self
        name.action = #selector(nameClicked)
        caption.textColor = .tertiaryLabelColor
        more.isBordered = false
        more.target = self
        more.action = #selector(moreClicked)
        more.toolTip = L("File actions")
        remove.isBordered = false
        remove.target = self
        remove.action = #selector(removeClicked)
        remove.toolTip = L("Remove attachment")
        pointer.url = { [weak self] in self.flatMap { AttachmentFiles.named($0.file) } }
        pointer.choices = { [weak self] in self.map { $0.actions.choices($0.file) } ?? [] }
        pointer.click = { [weak self] in self?.nameClicked() }
        for view in [icon, name, caption, more, remove, pointer] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ file: Attachment, fetching: Bool, failed: Bool, locked: Bool) {
        self.file = file
        let font = AppFont.native(.callout)
        let here = file.localPath != nil
        name.attributedTitle = NSAttributedString(string: file.name, attributes: [.font: font, .foregroundColor: NSColor.linkColor])
        name.isEnabled = !fetching
        name.toolTip = here ? nil : L("Download now")
        caption.font = AppFont.native(.caption)
        caption.stringValue = here ? ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
            : fetching ? L("downloading…") : failed ? L("could not download, try again later") : L("not downloaded yet, click to download")
        more.isHidden = !here
        more.image = .symbol("ellipsis.circle", font)
        more.contentTintColor = .secondaryLabelColor
        remove.image = .symbol("xmark.circle.fill", font)
        remove.contentTintColor = .tertiaryLabelColor
        remove.isEnabled = !locked
        // R86: over a file that is here lies a layer of its own for the pointer: a drag takes the file out, a right
        // click opens its menu.
        pointer.isHidden = !here
        loadIcon()
        needsLayout = true
    }

    private var isImage: Bool { file.mime.hasPrefix("image/") }

    /// R55: a thumbnail for an image that is here, a symbol for the rest.
    private func loadIcon() {
        let symbol = NSImage.symbol(isImage ? "photo" : "doc", AppFont.native(.callout))
        guard isImage, let path = file.localPath else {
            icon.image = symbol
            icon.contentTintColor = .secondaryLabelColor
            thumbnailFor = nil
            return
        }
        guard thumbnailFor != path else { return }
        thumbnailFor = path
        icon.image = symbol
        let pixels = Int(Self.iconSide * (window?.backingScaleFactor ?? 2))
        _Concurrency.Task { [weak self] in
            let image = await _Concurrency.Task.detached { AttachmentFiles.thumbnail(path: path, pixels: pixels) }.value
            guard let self, self.thumbnailFor == path, let image else { return }
            self.icon.image = NSImage(cgImage: image, size: NSSize(width: Self.iconSide, height: Self.iconSide))
            self.icon.contentTintColor = nil
            self.needsLayout = true
        }
    }

    var height: CGFloat {
        max(isImage && file.localPath != nil ? Self.iconSide : 0, TaskTableMetrics.lineHeight(AppFont.native(.callout)) + 4)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let height = bounds.height
        let line = TaskTableMetrics.lineHeight(AppFont.native(.callout))
        func center(_ size: NSSize, at x: CGFloat) -> NSRect { NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height) }
        let iconSize = icon.image.map { thumbnailFor != nil ? NSSize(width: Self.iconSide, height: Self.iconSide) : $0.size } ?? .zero
        icon.frame = center(iconSize, at: 0)
        var x = icon.frame.maxX + 6
        let nameWidth = min(name.fittingSize.width, max(bounds.width * 0.6, 40))
        name.frame = center(NSSize(width: nameWidth, height: line), at: x)
        pointer.frame = NSRect(x: 0, y: 0, width: name.frame.maxX, height: height)
        x = name.frame.maxX + 6
        let captionWidth = caption.fittingSize.width
        caption.frame = center(NSSize(width: captionWidth, height: TaskTableMetrics.lineHeight(AppFont.native(.caption))), at: x)
        x = caption.frame.maxX + 6
        if !more.isHidden {
            more.frame = center(more.image?.size ?? .zero, at: x)
            x = more.frame.maxX + 6
        }
        remove.frame = center(remove.image?.size ?? .zero, at: x)
    }

    // MARK: The keyboard (R54)

    override var acceptsFirstResponder: Bool { file.localPath != nil }

    override func becomeFirstResponder() -> Bool {
        onFocus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocus(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 49: show()
        case 53: actions.cancel()
        // The keys of the list are not for the selected row while the file has the keyboard.
        case 36, 76, 51, 117, 125, 126: break
        default: super.keyDown(with: event)
        }
    }

    // MARK: Actions

    @objc private func nameClicked() { actions.open(file) }

    @objc private func moreClicked() {
        menus.menu(actions.choices(file)).popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
    }

    @objc private func removeClicked() { actions.remove(file) }

    /// Shows the file inside the app (R54); the panel pages through the files of the task that are here.
    func show(among files: [Attachment]? = nil) {
        guard let url = AttachmentFiles.named(file) else { return }
        #if DEBUG
        DebugScript.shows += 1
        #endif
        window?.makeFirstResponder(self)
        let all = (files ?? [file]).compactMap(AttachmentFiles.named)
        previewable = all.isEmpty ? [url] : all
        previewed = previewable.firstIndex(of: url) ?? 0
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = previewed
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// The files of the card, for the next Space.
    var siblings: () -> [Attachment] = { [] }

    private func show() { show(among: siblings()) }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = previewed
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewable.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewable.indices.contains(index) ? previewable[index] as NSURL : nil }
    }
}

/// The files of an open card, a row each.
@MainActor
final class CardFilesView: NSView {
    private(set) var rows: [FileRowView] = []
    private let gap: CGFloat = 4

    func set(_ rows: [FileRowView]) {
        for row in self.rows where !rows.contains(where: { $0 === row }) { row.removeFromSuperview() }
        self.rows = rows
        for row in rows where row.superview !== self { addSubview(row) }
        needsLayout = true
    }

    var height: CGFloat { rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * gap }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: row.height)
            y += row.height + gap
        }
    }
}
