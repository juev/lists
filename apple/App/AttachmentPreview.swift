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
