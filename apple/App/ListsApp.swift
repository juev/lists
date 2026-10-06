import AppKit
import KeyboardShortcuts
import SwiftUI

@main
struct ListsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Lists", id: "main") {
            MainWindow()
                .environment(model)
                .font(AppFont.style(.body))
        }
        .defaultSize(width: 860, height: 600)
        .commands { AppCommands(model: model) }

        MenuBarExtra("Lists", systemImage: model.counts.overdue > 0 ? "checkmark.circle.badge.xmark" : "checkmark.circle") {
            MenuBarView()
                .environment(model)
                .font(AppFont.style(.body))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyboardShortcuts.onKeyUp(for: .quickEntry) { QuickEntryPanel.shared.toggle() }
        NSApp.servicesProvider = self
        #if DEBUG
        MainActor.assumeIsolated { DebugScript.runIfAsked() }
        #endif
    }

    /// The window can be closed while the menu bar item and the hotkey keep working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `lists://add?text=…` creates a task, `lists://show?id=…` opens one. Used by scripts and shortcuts.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "lists" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first(where: { $0.name == name })?.value }
            MainActor.assumeIsolated {
                switch url.host {
                case "add":
                    if let text = value("text") {
                        let model = AppModel.shared
                        _ = model.perform { try $0.quickAdd(text: text, listId: model.defaultListId) }
                    }
                case "show":
                    if let id = value("id") { AppModel.shared.reveal(id) }
                default: break
                }
            }
        }
    }

    /// Services menu: "Добавить в Lists" on selected text in any app.
    @objc func addFromService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
        MainActor.assumeIsolated {
            let model = AppModel.shared
            _ = model.perform { store in
                let task = try store.createTask(new: NewTask(title: String(lines[0].prefix(200)), listId: model.defaultListId))
                if lines.count > 1 || lines[0].count > 200 { try store.setNotes(id: task.id, notes: text) }
            }
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var selected: TaskItem? { model.selectedTask }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("New task")) {
                openWindow(id: "main")
                model.startDraft()
            }
            .keyboardShortcut("n")
            Button(L("Quick Entry")) { QuickEntryPanel.shared.present() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button(L("New List…")) {
                openWindow(id: "main")
                model.creatingList = true
            }
            Button(L("New Filter…")) {
                openWindow(id: "main")
                model.creatingFilter = true
            }
            Divider()
            Button(L("Import…")) { model.importFromFile() }
        }
        CommandMenu(L("Task")) {
            // Plain Return and Space are handled by the list itself: as menu
            // shortcuts they would be taken away from every text field.
            Button(L("Complete")) { selected.map(model.toggleDone) }
                .keyboardShortcut(.return)
                .disabled(selected == nil)
            Divider()
            Button(L("Due today")) { selected.map { model.setDue($0, Moment.today()) } }
                .keyboardShortcut("t")
                .disabled(selected == nil)
            Button(L("Due tomorrow")) { selected.map { model.setDue($0, shiftDate(date: Moment.today(), days: 1)) } }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(selected == nil)
            Divider()
            Button(L("Make subtask of the one above")) { selected.map(model.indent) }
                .keyboardShortcut("]")
                .disabled(selected == nil)
            Button(L("Move up a level")) { selected.map(model.outdent) }
                .keyboardShortcut("[")
                .disabled(selected?.parentId == nil)
        }
        CommandMenu(L("Go")) {
            scope(L("Inbox"), .inbox, "1")
            scope(L("Today"), .today, "2")
            scope(L("Upcoming"), .upcoming, "3")
            scope(L("All"), .all, "4")
            scope(L("Completed"), .completed, "5")
            Divider()
            Button(L("Sync now")) { model.syncNow() }
                .keyboardShortcut("r")
                .disabled(!model.syncStatus.configured)
        }
    }

    private func scope(_ title: String, _ scope: Scope, _ key: KeyEquivalent) -> some View {
        Button(title) {
            model.search = ""
            model.scope = scope
            openWindow(id: "main")
        }
        .keyboardShortcut(key)
    }
}

/// Menu bar window: the quick-entry field and what is due today.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuickEntryField(onDone: {})
            Divider()
            let today = (try? model.store?.tasks(view: .today)) ?? []
            if today.isEmpty {
                Text(L("All done for today")).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(today.prefix(12), id: \.id) { task in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Button { model.toggleDone(task) } label: { Image(systemName: "circle") }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L("Complete"))
                                Text(task.title).lineLimit(1)
                                Spacer()
                                if let due = task.due, Moment.isOverdue(due) {
                                    Text(Moment.label(due)).font(AppFont.style(.caption)).foregroundStyle(.red)
                                }
                            }
                        }
                        if today.count > 12 { Text(L("and %@ more", "\(today.count - 12)")).font(AppFont.style(.caption)).foregroundStyle(.secondary) }
                    }
                }
                .frame(maxHeight: 260)
            }
            Divider()
            HStack {
                Button(L("Open Lists")) {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button(L("Quit")) { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 340)
        // Reading counts keeps this view refreshed when tasks change elsewhere.
        .id(model.counts)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    private enum Kind: Hashable { case off, webdav, caldav, folder }
    private static let times = ["07:00", "08:00", "09:00", "10:00", "12:00", "18:00", "20:00"]
    private static let leads = [0, 5, 15, 30, 60, 120, 1440]

    private static func leadTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: return L("At the due time")
        case 1440: return L("A day before")
        case let m where m < 60: return L("%@ min before", "\(m)")
        default: return L("%@ h before", "\(minutes / 60)")
        }
    }

    @State private var kind = Kind.off
    @State private var url = ""
    @State private var user = ""
    @State private var password = ""
    @State private var folder = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section(L("Text")) {
                @Bindable var model = model
                Picker(L("Size"), selection: $model.textScale) {
                    ForEach(AppFont.scales, id: \.1) { name, value in Text(L(name)).tag(value) }
                }
                Picker(L("Typeface"), selection: $model.fontDesign) {
                    ForEach(AppFont.designs, id: \.1) { name, value in Text(L(name)).tag(value) }
                }
            }
            Section(L("Notifications")) {
                @Bindable var model = model
                Toggle(L("Show notifications"), isOn: $model.notifyEnabled)
                // Several can be on at once: a day before and again fifteen minutes before.
                LabeledContent(L("Task due at a time")) {
                    Menu {
                        ForEach(Self.leads, id: \.self) { minutes in
                            Toggle(Self.leadTitle(minutes), isOn: Binding(
                                get: { model.notifyLeads.contains(minutes) },
                                set: { if $0 { model.notifyLeads.insert(minutes) } else { model.notifyLeads.remove(minutes) } }))
                        }
                    } label: {
                        Text(model.notifyLeads.isEmpty
                            ? L("Off")
                            : model.notifyLeads.sorted().map(Self.leadTitle).joined(separator: ", "))
                    }
                    .fixedSize()
                }
                Picker(L("Task due on a day"), selection: $model.notifyAllDay) {
                    Text(L("Off")).tag("")
                    ForEach(Self.times, id: \.self) { Text(L("At %@", $0)).tag($0) }
                }
                Picker(L("Summary of the day"), selection: $model.notifySummary) {
                    Text(L("Off")).tag("")
                    ForEach(Self.times, id: \.self) { Text(L("At %@", $0)).tag($0) }
                }
                Toggle(L("Play a sound"), isOn: $model.notifySound)
                Text(L("A reminder set on a task is always shown. These settings apply to this Mac only."))
                    .font(AppFont.style(.caption)).foregroundStyle(.secondary)
            }
            Section(L("New tasks")) {
                @Bindable var model = model
                Picker(L("Default list"), selection: $model.newTaskList) {
                    Text(L("Inbox")).tag("inbox")
                    Text(L("Last used list")).tag("last")
                    Divider()
                    ForEach(model.lists.filter { !$0.archived && $0.id != "inbox" }, id: \.id) { Text($0.name).tag($0.id) }
                }
                Text(L("Used by quick entry and by views that show several lists, such as Today."))
                    .font(AppFont.style(.caption)).foregroundStyle(.secondary)
                Toggle(L("Recognize dates, priority, tags and lists in the title"), isOn: $model.parseQuickText)
                Text(L("“report friday 10:00 !! #work @Projects” sets the due date, the priority, a tag and the list. Off: the title is kept as typed."))
                    .font(AppFont.style(.caption)).foregroundStyle(.secondary)
                Picker(L("Return in the notes"), selection: $model.returnAddsLine) {
                    Text(L("Starts a new line")).tag(true)
                    Text(L("Finishes editing")).tag(false)
                }
                Text(model.returnAddsLine
                    ? L("Esc finishes editing.")
                    : L("⌥Return starts a new line."))
                    .font(AppFont.style(.caption)).foregroundStyle(.secondary)
            }
            Section(L("Quick Entry")) {
                KeyboardShortcuts.Recorder(L("Shortcut:"), name: .quickEntry)
            }
            Section(L("Sync")) {
                Picker(L("Storage"), selection: $kind) {
                    Text(L("Off")).tag(Kind.off)
                    Text("WebDAV").tag(Kind.webdav)
                    Text("CalDAV").tag(Kind.caldav)
                    Text(L("Folder")).tag(Kind.folder)
                }
                switch kind {
                case .off:
                    Text(L("Data is kept on this Mac only.")).foregroundStyle(.secondary)
                case .webdav:
                    TextField(L("Address"), text: $url, prompt: Text("https://example.org/remote.php/dav/files/me"))
                    TextField(L("User name"), text: $user)
                    SecureField(L("Password"), text: $password)
                    Text(L("For Nextcloud and similar servers use an app password. Data on the server is not encrypted."))
                        .font(AppFont.style(.caption)).foregroundStyle(.secondary)
                case .caldav:
                    TextField(L("Address"), text: $url, prompt: Text("https://example.org/remote.php/dav"))
                    TextField(L("User name"), text: $user)
                    SecureField(L("Password"), text: $password)
                    Text(L("Lists become calendars and tasks stay visible to other CalDAV apps. Attachments up to 5 MB are synced."))
                        .font(AppFont.style(.caption)).foregroundStyle(.secondary)
                case .folder:
                    HStack {
                        TextField(L("Path"), text: $folder)
                        Button(L("Choose…"), action: chooseFolder)
                    }
                    Text(L("A folder synced by another tool or a network drive will do."))
                        .font(AppFont.style(.caption)).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L("Save and sync"), action: save)
                    if model.syncing { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let text = message ?? status {
                    Text(text).font(AppFont.style(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private var status: String? {
        let s = model.syncStatus
        if let error = s.lastError { return L("The last attempt failed: %@", "\(error)") }
        if let ok = s.lastOk { return L("Synced: %@", "\(Moment.label(ok))") }
        return nil
    }

    private func load() {
        guard let config = try? model.store?.syncConfig() else { return }
        switch config {
        case .off: kind = .off
        case .folder(let path): kind = .folder; folder = path
        case .webDav(let u, let name), .calDav(let u, let name):
            if case .calDav = config { kind = .caldav } else { kind = .webdav }
            url = u
            user = name
            password = Keychain.load(account: Keychain.account(url: u, user: name)) ?? ""
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let picked = panel.url { folder = picked.path }
    }

    private func save() {
        let config: SyncConfig
        switch kind {
        case .off: config = .off
        case .webdav: config = .webDav(url: url, user: user)
        case .caldav: config = .calDav(url: url, user: user)
        case .folder: config = .folder(path: folder)
        }
        message = nil
        guard let store = model.store else { return }
        do {
            try store.setSyncConfig(config: config)
            if kind == .webdav || kind == .caldav {
                do {
                    try Keychain.save(password, account: Keychain.account(url: url, user: user))
                } catch {
                    // Sync still works until the app quits; say why it will ask again.
                    message = L("The password could not be saved in the system keychain: %@", error.localizedDescription)
                }
                store.setSyncPassword(password: password)
            }
            model.reload()
            model.watchSyncFolder()
            model.syncNow()
        } catch {
            message = describe(error)
        }
    }
}
