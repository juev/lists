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
        MainActor.assumeIsolated { QuickEntryPanel.shared.watchHiding() }
        NSApp.servicesProvider = self
        AttachmentFiles.clear()
        MainActor.assumeIsolated { AppModel.shared.applyAppearance() }
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
            scope(L("Won't do"), .wontDo, "6")
            Divider()
            Button(L("Sync now")) { model.syncNow() }
                .keyboardShortcut("r")
                .disabled(!model.syncStatus.configured)
        }
    }

    private func scope(_ title: String, _ scope: Scope, _ key: KeyEquivalent) -> some View {
        Button(title) {
            // R93: a view without a row is not gone to. The item is not disabled for it: one that is
            // disabled when the app starts stays so after the row comes back.
            if !model.showsInSidebar(scope) { return }
            model.search = ""
            model.searchOpen = false
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
                                Button { model.toggleDone(task) } label: { Image(systemName: "square") }
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
    /// A storage being joined with one side replacing the other, until that is confirmed (S36).
    private struct Replacement { let config: SyncConfig; let side: SyncSide }
    private static let times = ["07:00", "08:00", "09:00", "10:00", "12:00", "18:00", "20:00"]
    private static let leads = [0, 5, 15, 30, 60, 120, 1440]

    private static func keepChoices(_ current: KeepDone) -> [KeepDone] {
        var seconds: Set<UInt32> = [0, 5, 15]
        if case .seconds(let own) = current { seconds.insert(own) }
        return seconds.sorted().map { .seconds(seconds: $0) } + [.endOfDay]
    }

    /// A whole number of minutes is what an earlier version offered.
    private static func keepTitle(_ keep: KeepDone) -> String {
        switch keep {
        case .endOfDay: return L("at the end of the day")
        case .seconds(0): return L("at once")
        case .seconds(3600): return L("after an hour")
        case .seconds(let s) where s % 60 == 0: return L("after %d min", Int(s / 60))
        case .seconds(let s): return L("after %d s", Int(s))
        }
    }

    private static func leadTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: return L("At the due time")
        case 1440: return L("A day before")
        case let m where m < 60: return L("%@ min before", "\(m)")
        default: return L("%@ h before", "\(minutes / 60)")
        }
    }

    /// The tab shown; the window opens on the one used last.
    @AppStorage("settingsTab") private var tab = "general"
    @State private var kind = Kind.off
    @State private var url = ""
    @State private var user = ""
    @State private var password = ""
    @State private var folder = ""
    @State private var pushServer = ""
    @State private var pushToken = ""
    @State private var pushSignIn = false
    @State private var pushRefused = false
    @State private var message: String?
    @State private var testing = false
    /// The storage being joined while the person chooses a side (S36).
    @State private var joining: SyncConfig?
    @State private var replacing: Replacement?

    var body: some View {
        // R101: five tabs. The state of every tab lives in this view, so what is typed under Sync stays while the window is open.
        TabView(selection: $tab) {
            Form {
                Section(L("Appearance")) {
                    @Bindable var model = model
                    Picker(L("Appearance"), selection: $model.appearance) {
                        Text(L("Same as the system")).tag("system")
                        Text(L("Light")).tag("light")
                        Text(L("Dark")).tag("dark")
                    }
                }
                Section(L("Text")) {
                    @Bindable var model = model
                    Picker(L("Size"), selection: $model.textScale) {
                        ForEach(AppFont.scales, id: \.1) { name, value in Text(L(name)).tag(value) }
                    }
                    Picker(L("Typeface"), selection: $model.fontDesign) {
                        ForEach(AppFont.designs, id: \.1) { name, value in Text(L(name)).tag(value) }
                    }
                }
                Section(L("Sidebar")) {
                    @Bindable var model = model
                    ForEach(Scope.builtins, id: \.self) { scope in
                        Picker(scope.builtinTitle, selection: Binding(get: { model.sidebarShow(scope) }, set: { model.setSidebarShow(scope, $0) })) {
                            ForEach(SidebarShow.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                }
                Section(L("Completed tasks")) {
                    // What R68 offers, and the value in force when another device set something else.
                    Picker(L("Leave the view"), selection: Binding(get: { model.keepDone }, set: { model.setKeepDone($0) })) {
                        ForEach(Self.keepChoices(model.keepDone), id: \.self) { keep in
                            Text(Self.keepTitle(keep)).tag(keep)
                        }
                    }
                }
                LogSection()
            }
            .formStyle(.grouped)
            .tabItem { Label(L("General"), systemImage: "gearshape") }
            .tag("general")
            Form {
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
                    Toggle(L("Start the note with the clipboard in quick entry"), isOn: $model.clipboardNotes)
                    Text(L("Text or a link copied just before the quick-entry window is opened becomes the note. Each copy is used once."))
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
                Section(L("Calendar events")) {
                    @Bindable var model = model
                    Toggle(L("Show calendar events in Today"), isOn: $model.showCalendarEvents)
                    if model.showCalendarEvents {
                        if model.calendarAccess == .denied {
                            Button(L("Lists has no access to the calendars. Open System Settings…")) {
                                SystemCalendars.shared.openPrivacySettings()
                            }
                        }
                        // R78: the system gives all the calendars at once, the choice among them is made here.
                        ForEach(model.eventCalendars) { calendar in
                            Toggle(isOn: Binding(
                                get: { !model.hiddenCalendars.contains(calendar.id) },
                                set: { if $0 { model.hiddenCalendars.remove(calendar.id) } else { model.hiddenCalendars.insert(calendar.id) } })) {
                                HStack(spacing: 6) {
                                    Circle().fill(calendar.color).frame(width: 8, height: 8)
                                    Text(calendar.title)
                                    Text(calendar.source).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    Text(L("Events are read from the calendars of this Mac and are shown above the tasks. They are not synced, and this setting applies to this Mac only."))
                        .font(AppFont.style(.caption)).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(L("Tasks"), systemImage: "checklist") }
            .tag("tasks")
            Form {
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
                    if model.notifySound {
                        // R36: the chosen sound is heard at once.
                        Picker(L("Sound"), selection: Binding(
                            get: { NotifySound.names.contains(model.notifySoundName) ? model.notifySoundName : "" },
                            set: { model.notifySoundName = $0; NotifySound.play($0) })) {
                            Text(L("Standard")).tag("")
                            Divider()
                            ForEach(NotifySound.names, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Text(L("A reminder set on a task is always shown. These settings apply to this Mac only."))
                        .font(AppFont.style(.caption)).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(L("Notifications"), systemImage: "bell") }
            .tag("notifications")
            Form {
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
                        Text(L("Lists become calendars and tasks stay visible to other CalDAV apps. Attachments up to 5 MB are synced, up to 20 MB per task."))
                            .font(AppFont.style(.caption)).foregroundStyle(.secondary)
                    case .folder:
                        HStack {
                            TextField(L("Path"), text: $folder)
                            Button(L("Choose…"), action: chooseFolder)
                        }
                        Text(L("A folder synced by another tool or a network drive will do."))
                            .font(AppFont.style(.caption)).foregroundStyle(.secondary)
                    }
                    if kind != .off {
                        TextField(L("Push server"), text: $pushServer, prompt: Text("https://ntfy.sh"))
                        Text(L("Optional. Through an ntfy server other devices ask this Mac to sync at once. No data passes through it."))
                            .font(AppFont.style(.caption)).foregroundStyle(.secondary)
                        Toggle(L("The push server requires sign-in"), isOn: $pushSignIn)
                        if pushSignIn {
                            SecureField(L("Push token"), text: $pushToken, prompt: Text("tk_…"))
                            Text(L("An access token of the ntfy server. It is sent to this server and to no other."))
                                .font(AppFont.style(.caption)).foregroundStyle(.secondary)
                        }
                        if pushRefused {
                            Text(L("The push server refused access. Check the push token."))
                                .font(AppFont.style(.caption)).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button(L("Save and sync"), action: save)
                        if kind == .webdav || kind == .caldav {
                            Button(L("Test connection"), action: test).disabled(testing)
                        }
                        if model.syncing || testing { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let text = message ?? status {
                        Text(text).font(AppFont.style(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(L("Sync"), systemImage: "arrow.triangle.2.circlepath") }
            .tag("sync")
            Form {
                BackupsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label(L("Backups"), systemImage: "externaldrive") }
            .tag("backups")
        }
        .frame(width: 520)
        .onAppear(perform: load)
        .confirmationDialog(
            L("This Mac and the storage both hold tasks"),
            isPresented: Binding(get: { joining != nil }, set: { if !$0 { joining = nil } }),
            titleVisibility: .visible,
            presenting: joining
        ) { config in
            // The buttons carry the storage themselves: the dialog forgets it as it closes.
            Button(L("Merge")) { apply(config, side: .merge) }
            Button(L("Use the data of the storage…")) { replacing = Replacement(config: config, side: .storage) }
            Button(L("Use the data of this Mac…")) { replacing = Replacement(config: config, side: .device) }
            Button(L("Cancel"), role: .cancel) {}
        } message: { _ in
            Text(L("Merge keeps the tasks of both sides. The other two choices keep one side and replace the other."))
        }
        .alert(
            replacing?.side == .storage ? L("Replace the data of this Mac?") : L("Replace the data of the storage?"),
            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
            presenting: replacing
        ) { choice in
            Button(L("Replace"), role: .destructive) { apply(choice.config, side: choice.side) }
            Button(L("Cancel"), role: .cancel) {}
        } message: { choice in
            Text(choice.side == .storage
                ? L("The tasks, lists and filters of this Mac are erased and read again from the storage. Changes that have not been synced are lost.")
                : L("The storage and every other device get the data of this Mac. What this Mac does not have goes to the Trash on all devices, and edits made elsewhere are undone."))
        }
        // S30: the subscription is retried in the background, so the answer comes later than the save.
        .task {
            while !Task.isCancelled {
                pushRefused = model.store?.pushRefused() ?? false
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var status: String? {
        let s = model.syncStatus
        if let error = s.lastError { return L("The last attempt failed: %@", "\(error)") }
        let waiting = s.attachmentsWaiting > 0 ? L("Attachments waiting to sync: %@", "\(s.attachmentsWaiting)") : nil
        if let ok = s.lastOk { return [L("Synced: %@", "\(Moment.label(ok))"), waiting].compactMap { $0 }.joined(separator: "\n") }
        return waiting
    }

    private func load() {
        pushServer = (try? model.store?.pushServer()) ?? ""
        pushToken = pushServer.isEmpty ? "" : Keychain.load(account: Keychain.pushAccount(server: pushServer)) ?? ""
        // Off until a token is set: a public ntfy server needs none.
        pushSignIn = !pushToken.isEmpty
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

    /// Asks the server with what the fields hold now; nothing is saved (S26).
    private func test() {
        let config: SyncConfig = kind == .caldav ? .calDav(url: url, user: user) : .webDav(url: url, user: user)
        let password = password
        message = nil
        testing = true
        Task {
            let result = await Task.detached { Result { try checkSyncConnection(config: config, password: password) } }.value
            testing = false
            switch result {
            case .success(.ready): message = L("Connected.")
            case .success(.willCreate): message = L("Connected. The folder does not exist yet; the first sync creates it.")
            case .failure(let error): message = L("No connection: %@", describe(error))
            }
        }
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
        // S36: a storage that is new to this Mac may hold data of its own.
        guard config != .off, (try? store.syncConfig()) != config else { return apply(config, side: .merge) }
        let password = password
        testing = true
        Task {
            let both = await Task.detached { Result { try store.syncConflict(config: config, password: password) } }.value
            testing = false
            switch both {
            case .success(true): joining = config
            case .success(false): apply(config, side: .merge)
            case .failure(let error): message = L("No connection: %@", describe(error))
            }
        }
    }

    private func apply(_ config: SyncConfig, side: SyncSide) {
        guard let store = model.store else { return }
        guard side != .merge else { return finish(Result { try store.joinStorage(config: config, side: side) }) }
        // Replacing a side waits for a run that is under way: not on the main thread.
        testing = true
        Task {
            let joined = await Task.detached { Result { try store.joinStorage(config: config, side: side) } }.value
            testing = false
            finish(joined)
        }
    }

    /// The rest of saving, once the storage is stored.
    private func finish(_ joined: Result<Void, Error>) {
        guard let store = model.store else { return }
        do {
            try joined.get()
            try store.setPushServer(server: kind == .off ? nil : pushServer)
            // The core keeps the address without the trailing slash; the token is filed under that.
            if let server = try store.pushServer() {
                let token = pushSignIn ? pushToken.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let account = Keychain.pushAccount(server: server)
                if token.isEmpty {
                    Keychain.delete(account: account)
                } else {
                    do {
                        try Keychain.save(token, account: account, label: "Lists push token")
                    } catch {
                        message = L("The push token could not be saved in the system keychain: %@", error.localizedDescription)
                    }
                }
                store.setPushToken(token: token)
            } else {
                store.setPushToken(token: nil)
            }
            pushRefused = false
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
