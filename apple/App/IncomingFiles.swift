import AppKit

/// Files on their way into a task: picked in the open panel or pasted.
@MainActor
enum IncomingFiles {
    private static let pastedPrefix = "lists-pasted-"

    /// What ⌘V would attach. Files copied in Finder come as they are; a bare
    /// image (a screenshot, "Copy Image") is written out as a PNG first.
    /// Empty when the pasteboard holds text: an image that only accompanies
    /// text, as a copied table does, is not what the user is pasting.
    static func pasted(_ pasteboard: NSPasteboard = .general) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls }
        guard pasteboard.string(forType: .string) == nil, let png = png(pasteboard) else { return [] }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(pastedPrefix + UUID().uuidString, isDirectory: true)
        // The name travels to other devices with the task, so it does not follow
        // the language of this one; the time tells two pasted images apart.
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let file = dir.appendingPathComponent("Image \(stamp.string(from: Date())).png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: file)
            return [file]
        } catch {
            return []
        }
    }

    /// Asks for files. Modal, so that the quick-entry panel can tell the
    /// open panel from the user leaving for another app.
    static func pick() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Removes the temporary copy of a pasted image; other files are left alone.
    static func discard(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        if dir.lastPathComponent.hasPrefix(pastedPrefix) { try? FileManager.default.removeItem(at: dir) }
    }

    private static func png(_ pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png) { return data }
        guard let tiff = pasteboard.data(forType: .tiff) else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}
