import AppKit
import SwiftUI

/// A task that is being typed and does not exist yet.
struct TaskDraft: Equatable {
    var title = ""
    var notes = ""
    /// The note as it came from the clipboard (R58); nil when it was typed.
    var pastedNotes: String?
    var start: String?
    var due: String?
    /// The due date came from the view (Today), not from the user: a date
    /// typed in the title replaces it.
    var dueIsDefault = false
    var `repeat`: Repeat?
    var priority = Priority.none
    var tags: [String] = []
    var listId = "inbox"
    /// Set when the task is typed inside a project: it becomes a subtask of it.
    var parentId: String?
    /// Attached once the task exists.
    var files: [URL] = []

    var isBlank: Bool { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The card of a new task, the same in the main window (⌘N) and in the
/// quick-entry panel: every field can be filled before the task is created.
/// Return in the title saves; Esc saves a task that has a title and throws an
/// empty card away.
struct DraftEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: TaskDraft
    /// Called when the card is done with, saved or not.
    var onClose: () -> Void
    /// Called when the height may have changed; the quick-entry panel follows it.
    var onResize: () -> Void = {}

    private enum Popover: Identifiable {
        case due, start, `repeat`, tag
        var id: Self { self }
    }

    @State private var popover: Popover?
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "circle").font(AppFont.style(.title3)).foregroundStyle(.secondary)
                TextField(L("New task"), text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(AppFont.style(.body))
                    .focused($titleFocused)
                    .onSubmit(close)
                if model.parseQuickText { QuickChips(text: draft.title) }
            }
            Group {
                HStack(alignment: .top, spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        if draft.notes.isEmpty {
                            Text(L("Notes")).foregroundStyle(.tertiary).allowsHitTesting(false)
                        }
                        NotesTextView(
                            text: $draft.notes, font: AppFont.native(.body), returnAddsLine: model.returnAddsLine,
                            wantsFocus: .constant(false), onEditingChanged: { _ in }, onFinish: close)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // R58: the text taken from the clipboard goes in one click while it is untouched.
                    if let pasted = draft.pastedNotes, draft.notes == pasted {
                        Button { draft.notes = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Remove the text taken from the clipboard"))
                    }
                }
                .font(AppFont.style(.body))
                chips
                if !draft.files.isEmpty { files }
            }
            .padding(.leading, 30)
        }
        .background {
            // The dates and the repeat are one key away from wherever the cursor is.
            Group {
                Button("") { popover = .start }.keyboardShortcut("s", modifiers: .command)
                Button("") { popover = .due }.keyboardShortcut("d", modifiers: .command)
                Button("") { popover = .repeat }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("", action: paste).keyboardShortcut("v", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear { titleFocused = true }
        .onExitCommand(perform: close)
        .onChange(of: draft.notes) { _, _ in onResize() }
        .onChange(of: draft.tags) { _, _ in onResize() }
        .onChange(of: draft.repeat) { _, _ in onResize() }
        .onChange(of: draft.files) { _, _ in onResize() }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls.filter(\.isFileURL))
            return true
        }
    }

    private func close() {
        if draft.isBlank {
            draft.files.forEach(IncomingFiles.discard)
        } else {
            model.save(draft)
        }
        onClose()
    }

    /// ⌘V with files or an image attaches them; with text it pastes as usual.
    private func paste() {
        let pasted = IncomingFiles.pasted()
        if pasted.isEmpty {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        } else {
            add(pasted)
        }
    }

    private func add(_ urls: [URL]) {
        draft.files.append(contentsOf: urls.filter { !draft.files.contains($0) })
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(draft.files, id: \.self) { url in
                HStack(spacing: 6) {
                    Image(systemName: "paperclip").foregroundStyle(.secondary)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Button {
                        draft.files.removeAll { $0 == url }
                        IncomingFiles.discard(url)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Remove attachment"))
                }
                .font(AppFont.style(.callout))
            }
        }
    }

    private var chips: some View {
        FlowLayout(spacing: 6) {
            chipButton(.start, symbol: "calendar.badge.clock",
                       text: draft.start.map { L("Start: ") + Moment.label($0).lowercased() } ?? L("Start"),
                       tint: draft.start == nil ? .secondary : .accentColor)
                .popover(isPresented: isOpen(.start)) {
                    DateEditor(title: L("Start: hidden from Today until"), value: draft.start) { draft.start = $0 }
                }
                .help(L("Start date (⌘S)"))
            chipButton(.due, symbol: "calendar",
                       text: shownDue.map { L("Due: ") + Moment.label($0).lowercased() } ?? L("Due"),
                       tint: shownDue == nil ? .secondary : .accentColor)
                .popover(isPresented: isOpen(.due)) {
                    DateEditor(title: L("Due"), value: shownDue) {
                        draft.due = $0
                        draft.dueIsDefault = false
                    }
                }
                .help(L("Due date (⌘D)"))
            chipButton(.repeat, symbol: "repeat", text: draft.repeat?.summary ?? L("Repeat"),
                       tint: draft.repeat == nil ? .secondary : .accentColor)
                .popover(isPresented: isOpen(.repeat)) {
                    RepeatEditor(value: draft.repeat) { draft.repeat = $0 }
                }
                .help(L("Repeat (⇧⌘R)"))
            Menu {
                ForEach(Priority.all, id: \.self) { priority in
                    Toggle(priority.title, isOn: Binding(get: { draft.priority == priority }, set: { _ in draft.priority = priority }))
                }
            } label: {
                Chip(symbol: "flag", text: draft.priority == .none ? "" : draft.priority.title, tint: draft.priority == .none ? .secondary : .orange)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Priority"))

            ForEach(draft.tags, id: \.self) { tag in
                Button {
                    draft.tags.removeAll { $0 == tag }
                } label: {
                    Chip(symbol: nil, text: "#\(tag) ×")
                }
                .buttonStyle(.plain)
                .help(L("Remove tag"))
            }
            chipButton(.tag, symbol: "number", text: "", tint: .secondary)
                .popover(isPresented: isOpen(.tag)) {
                    TagEditor(known: model.tags.map(\.name).filter { !draft.tags.contains($0) }) { tag in
                        if !draft.tags.contains(tag) { draft.tags.append(tag) }
                    }
                }
                .help(L("Tag"))

            if draft.parentId == nil {
                Menu {
                    ForEach(model.lists.filter { !$0.archived }, id: \.id) { list in
                        Toggle(model.listName(list), isOn: Binding(get: { draft.listId == list.id }, set: { _ in draft.listId = list.id }))
                    }
                } label: {
                    Chip(symbol: "list.bullet", text: model.list(draft.listId).map(model.listName) ?? L("Inbox"))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("List"))
            }

            Button { add(IncomingFiles.pick()) } label: { Chip(symbol: "paperclip", text: "") }
                .buttonStyle(.plain)
                .help(L("File or image"))
        }
    }

    /// What the task will be due on: the field, unless it only holds the
    /// view's default and the title names a date.
    private var shownDue: String? {
        if draft.dueIsDefault, model.parseQuickText, let typed = model.store?.parseQuick(text: draft.title).due { return typed }
        return draft.due
    }

    private func isOpen(_ which: Popover) -> Binding<Bool> {
        Binding(get: { popover == which }, set: { if !$0 && popover == which { popover = nil } })
    }

    private func chipButton(_ which: Popover, symbol: String, text: String, tint: Color) -> some View {
        Button { popover = which } label: { Chip(symbol: symbol, text: text, tint: tint) }
            .buttonStyle(.plain)
    }
}
