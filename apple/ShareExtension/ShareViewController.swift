import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the host app handed over, reduced to what a task can hold.
struct SharedContent {
    var title = ""
    var notes = ""
    var files: [URL] = []
    /// R102: why an item that was shared did not arrive, for the log.
    var failures: [String] = []
}

/// Share sheet entry: shows the task about to be created and saves it straight
/// into the shared database, so it works while the main app is not running.
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 190))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collect { [weak self] content in
            guard let self else { return }
            let store = try? Storage.openStore()
            for failure in content.failures {
                store?.log(level: .error, source: "attachments", message: "a shared item was not received: \(failure)")
            }
            let form = ShareForm(
                content: content,
                // R121: hidden Inbox is not offered. R40: the form starts with the default list; the list used last
                // is a setting of the app, which the extension does not see.
                lists: (try? store?.lists())?.filter { !$0.archived && ($0.id != "inbox" || (try? store?.inboxHidden()) != true) } ?? [],
                defaultListId: (try? store?.defaultListId(lastUsed: nil)) ?? "inbox",
                onCancel: { [weak self] in
                    self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                },
                onSave: { [weak self] title, notes, listId in self?.save(title: title, notes: notes, listId: listId, files: content.files) ?? L("The extension was closed") })
            let host = NSHostingView(rootView: form)
            host.frame = self.view.bounds
            host.autoresizingMask = [.width, .height]
            self.view.addSubview(host)
        }
    }

    /// Returns an error text, or nil after finishing the request.
    private func save(title: String, notes: String, listId: String, files: [URL]) -> String? {
        do {
            let store = try Storage.openStore()
            let task = try store.createTask(new: NewTask(title: title, listId: listId, notes: notes))
            for file in files {
                _ = try? store.addAttachment(taskId: task.id, path: file.path, name: nil)
            }
            Storage.announceChange()
            extensionContext?.completeRequest(returningItems: nil)
            return nil
        } catch {
            return describe(error)
        }
    }

    private func collect(_ done: @escaping (SharedContent) -> Void) {
        var content = SharedContent()
        let group = DispatchGroup()
        let lock = NSLock()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty { content.notes = text }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { value, error in
                        if let url = Self.url(from: value) {
                            lock.withLock { content.files.append(url) }
                        } else {
                            lock.withLock { content.failures.append("file: \(error.map(logged) ?? "no address")") }
                        }
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier) { value, _ in
                        if let url = Self.url(from: value) {
                            lock.withLock { content.notes = [content.notes, url.absoluteString].filter { !$0.isEmpty }.joined(separator: "\n") }
                        }
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    group.enter()
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                        // The file is removed when this block returns: keep a copy.
                        if let url {
                            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                            try? FileManager.default.removeItem(at: copy)
                            do {
                                try FileManager.default.copyItem(at: url, to: copy)
                                lock.withLock { content.files.append(copy) }
                            } catch {
                                lock.withLock { content.failures.append("image not copied: \(logged(error))") }
                            }
                        } else {
                            lock.withLock { content.failures.append("image: \(error.map(logged) ?? "no file")") }
                        }
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { value, _ in
                        if let text = value as? String {
                            lock.withLock { content.notes = [content.notes, text].filter { !$0.isEmpty }.joined(separator: "\n") }
                        }
                        group.leave()
                    }
                }
            }
        }
        group.notify(queue: .main) {
            // The first line becomes the title; a long text stays whole in the note.
            let firstLine = content.notes.split(separator: "\n").first.map(String.init) ?? ""
            if !firstLine.isEmpty {
                content.title = String(firstLine.prefix(120))
                if content.notes == content.title { content.notes = "" }
            } else if let file = content.files.first {
                content.title = file.deletingPathExtension().lastPathComponent
            }
            done(content)
        }
    }

    private static func url(from value: NSSecureCoding?) -> URL? {
        if let url = value as? URL { return url }
        if let data = value as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let text = value as? String { return URL(string: text) }
        return nil
    }
}

struct ShareForm: View {
    let content: SharedContent
    let lists: [TaskList]
    let defaultListId: String
    let onCancel: () -> Void
    /// Returns an error text or nil.
    let onSave: (String, String, String) -> String?

    @State private var title = ""
    @State private var listId = "inbox"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L("Title"), text: $title)
                .font(.title3)
                .onSubmit(save)
            if !content.notes.isEmpty {
                Text(content.notes).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            if !content.files.isEmpty {
                Label(content.files.map(\.lastPathComponent).joined(separator: ", "), systemImage: "paperclip")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Spacer(minLength: 0)
            HStack {
                Picker("", selection: $listId) {
                    ForEach(lists, id: \.id) { Text($0.id == "inbox" ? L("Inbox") : $0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button(L("Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("Add"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .onAppear {
            title = content.title
            listId = defaultListId
        }
    }

    private func save() {
        error = onSave(title, content.notes, listId)
    }
}
