import AppKit
import ImageIO
import SwiftUI

/// Attachments as files the system can show (R54, R55).
///
/// The content lives under the hash of its bytes, without a name or an
/// extension, so Quick Look and the default app cannot tell what it is. They
/// get a copy under the name the file was attached with. A copy and not a
/// link: an app that saves over the file it opened must not change the content
/// behind the hash. On APFS the copy is a clone and takes no space.
enum AttachmentFiles {
    private static let root = FileManager.default.temporaryDirectory.appendingPathComponent("lists-attachments", isDirectory: true)

    /// The content of an attachment under its own name, or nil while it is not on this device.
    static func named(_ file: Attachment) -> URL? {
        guard let path = file.localPath else { return nil }
        let fm = FileManager.default
        // Two attachments may share a name; their content tells them apart.
        let dir = root.appendingPathComponent(file.sha256, isDirectory: true)
        let target = dir.appendingPathComponent(fileName(file.name))
        if fm.fileExists(atPath: target.path) { return target }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: path), to: target)
            return target
        } catch {
            return nil
        }
    }

    /// Whether the file is one of the named copies: a file dragged out of a card and dropped on a card is not a new attachment.
    static func isCopy(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    /// Writes the content of an attachment where the person asked for it (R86), in place of a file that is there.
    static func save(_ file: Attachment, to target: URL) throws {
        guard let path = file.localPath else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: URL(fileURLWithPath: path), to: target)
    }

    /// Asks where to save the attachment, under its own name, and saves it there.
    @MainActor
    static func saveAs(_ file: Attachment, failed: (String) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(file.name)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do { try save(file, to: target) } catch { failed(error.localizedDescription) }
    }

    /// Removes the named copies; they are made again when asked for.
    static func clear() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The name as a single path component: it comes from another device as it was typed there.
    static func fileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : cleaned
    }

    /// A small picture of an image file, read without loading it whole. Nil for what is not an image.
    nonisolated static func thumbnail(path: String, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// What the pointer does over a file of a card (R86): a click opens it, a drag takes it out of the app
/// under its own name, a right click opens its menu. An AppKit view: inside a list row SwiftUI gives
/// the drag and the context menu to the row, so the file gets neither from `onDrag` or `contextMenu`.
struct FilePointer: NSViewRepresentable {
    let url: () -> URL?
    let choices: () -> [MenuChoice]
    let click: () -> Void

    func makeNSView(context: Context) -> FilePointerView { FilePointerView() }

    func updateNSView(_ view: FilePointerView, context: Context) {
        view.url = url
        view.choices = choices
        view.click = click
    }
}

final class FilePointerView: NSView, NSDraggingSource {
    var url: () -> URL? = { nil }
    var choices: () -> [MenuChoice] = { [] }
    var click: () -> Void = {}
    private var pressed: NSPoint?
    private var actions: [() -> Void] = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { pressed = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressed else { return }
        let now = event.locationInWindow
        // A press that moves this far is a drag, not a click.
        guard hypot(now.x - start.x, now.y - start.y) > 4, let url = url() else { return }
        pressed = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let at = convert(now, from: nil)
        item.setDraggingFrame(NSRect(x: at.x - 16, y: at.y - 16, width: 32, height: 32), contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed != nil else { return }
        pressed = nil
        click()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    override func menu(for event: NSEvent) -> NSMenu? { fileMenu() }

    /// The menu of the file, built from the same choices as its menu button.
    func fileMenu() -> NSMenu {
        let menu = NSMenu()
        let all = choices()
        actions = all.map(\.action)
        for (index, choice) in all.enumerated() {
            let item = NSMenuItem(title: choice.title, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        return menu
    }

    /// A click that did not move, the way the pointer makes it.
    func clicked() { click() }

    @objc private func run(_ item: NSMenuItem) {
        if actions.indices.contains(item.tag) { actions[item.tag]() }
    }
}

/// The icon of an attachment row: a thumbnail for an image, a symbol for the rest.
struct AttachmentIcon: View {
    let file: Attachment
    static let side: CGFloat = 28

    @State private var thumbnail: CGImage?
    @Environment(\.displayScale) private var scale

    private var isImage: Bool { file.mime.hasPrefix("image/") }

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: scale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: isImage ? "photo" : "doc").foregroundStyle(.secondary)
            }
        }
        .task(id: file.localPath) {
            guard isImage, let path = file.localPath else { thumbnail = nil; return }
            let pixels = Int(Self.side * scale)
            thumbnail = await _Concurrency.Task.detached { AttachmentFiles.thumbnail(path: path, pixels: pixels) }.value
        }
    }
}
