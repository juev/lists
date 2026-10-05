import SwiftUI

extension Color {
    init?(hex: String) {
        var value: UInt64 = 0
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, Scanner(string: digits).scanHexInt64(&value) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

extension TaskList {
    var tint: Color { Color(hex: color) ?? .accentColor }
    var symbol: String { id == "inbox" ? "tray" : (icon.isEmpty ? "list.bullet" : icon) }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            TaskListView()
                .navigationTitle(model.scopeTitle)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { SyncIndicator() }
                }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: L("Search"))
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .alert(L("That did not work"), isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

/// One quiet icon: nothing when idle, a spinner while running, a warning when the last run failed.
struct SyncIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.syncStatus
        if status.configured {
            Button {
                model.syncNow()
            } label: {
                if model.syncing {
                    ProgressView().controlSize(.small)
                } else if status.lastError != nil {
                    Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                } else {
                    Image(systemName: status.pending > 0 ? "arrow.triangle.2.circlepath.icloud" : "checkmark.icloud")
                        .foregroundStyle(.secondary)
                }
            }
            .help(help(status))
        }
    }

    private func help(_ status: SyncStatus) -> String {
        if let error = status.lastError { return L("Sync failed: %@\nClick to retry.", "\(error)") }
        if status.pending > 0 { return L("Waiting to upload: %@", "\(status.pending)") }
        if let ok = status.lastOk { return L("Synced: %@", "\(Moment.label(ok))") }
        return L("Sync now")
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var editing: TaskList?
    @State private var creating = false

    var body: some View {
        @Bindable var model = model
        List(selection: Binding<Scope?>(get: { model.scope }, set: { if let s = $0 { model.search = ""; model.scope = s } })) {
            Section {
                row(.inbox, L("Inbox"), "tray", count: model.counts.inbox)
                    .dropDestination(for: String.self) { ids, _ in moveTasks(ids, to: "inbox") }
                    .contextMenu { Button(L("Configure…")) { editing = model.list("inbox") } }
                row(.today, L("Today"), "star", count: model.counts.today, alert: model.counts.overdue > 0)
                row(.upcoming, L("Upcoming"), "calendar", count: model.counts.upcoming)
                row(.all, L("All"), "square.stack", count: 0)
                row(.completed, L("Completed"), "checkmark.circle", count: 0)
                if model.counts.trash > 0 {
                    row(.trash, L("Trash"), "trash", count: model.counts.trash)
                }
            }
            Section(L("Lists")) {
                ForEach(model.lists.filter { $0.id != "inbox" && !$0.archived }, id: \.id) { list in
                    Label {
                        HStack {
                            Text(list.name)
                            Spacer()
                            if list.openCount > 0 { Text("\(list.openCount)").foregroundStyle(.secondary).monospacedDigit() }
                        }
                    } icon: {
                        Image(systemName: list.symbol).foregroundStyle(list.tint)
                    }
                    .tag(Scope.list(id: list.id))
                    .dropDestination(for: String.self) { ids, _ in moveTasks(ids, to: list.id) }
                    .contextMenu {
                        Button(L("Configure…")) { editing = list }
                        Button(L("Archive")) { model.perform { try $0.setListArchived(id: list.id, archived: true) } }
                        Divider()
                        Button(L("Delete list"), role: .destructive) { model.perform { try $0.deleteList(id: list.id) } }
                    }
                }
                .onMove { source, destination in moveList(source, destination) }
            }
            if !model.tags.isEmpty {
                Section(L("Tags")) {
                    ForEach(model.tags, id: \.name) { tag in
                        Label {
                            HStack {
                                Text(tag.name)
                                Spacer()
                                Text("\(tag.openCount)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        } icon: {
                            Image(systemName: "number")
                        }
                        .tag(Scope.tag(name: tag.name))
                    }
                }
            }
            let archived = model.lists.filter(\.archived)
            if !archived.isEmpty {
                Section(L("Archived lists")) {
                    ForEach(archived, id: \.id) { list in
                        Label(list.name, systemImage: "archivebox")
                            .foregroundStyle(.secondary)
                            .tag(Scope.list(id: list.id))
                            .contextMenu {
                                Button(L("Unarchive")) { model.perform { try $0.setListArchived(id: list.id, archived: false) } }
                                Button(L("Delete list"), role: .destructive) { model.perform { try $0.deleteList(id: list.id) } }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { creating = true } label: { Label(L("New list"), systemImage: "plus") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
        .sheet(item: $editing) { ListEditor(list: $0) }
        .sheet(isPresented: $creating) { ListEditor(list: nil) }
    }

    private func row(_ scope: Scope, _ title: String, _ symbol: String, count: UInt32, alert: Bool = false) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if count > 0 {
                    Text("\(count)").foregroundStyle(alert ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)).monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .tag(scope)
    }

    private func moveTasks(_ ids: [String], to list: String) -> Bool {
        for id in ids {
            model.perform { try $0.moveToList(id: id, listId: list) }
        }
        return !ids.isEmpty
    }

    private func moveList(_ source: IndexSet, _ destination: Int) {
        let visible = model.lists.filter { $0.id != "inbox" && !$0.archived }
        guard let from = source.first else { return }
        var order = visible
        order.move(fromOffsets: source, toOffset: destination)
        guard let index = order.firstIndex(where: { $0.id == visible[from].id }) else { return }
        let after = index > 0 ? order[index - 1].id : nil
        model.perform { try $0.moveList(id: visible[from].id, after: after) }
    }
}

extension TaskList: Identifiable {}

/// Name, colour, icon, order and defaults of a list; also used to create one.
struct ListEditor: View {
    let list: TaskList?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var color = ""
    @State private var icon = ""
    @State private var sort = SortMode.manual
    @State private var showDone = false
    @State private var defaultPriority = Priority.none
    @State private var defaultDueToday = false

    private var isInbox: Bool { list?.id == "inbox" }

    static let colors = ["", "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#007AFF", "#5856D6", "#AF52DE", "#8E8E93"]
    static let icons = ["list.bullet", "house", "briefcase", "cart", "book", "heart", "airplane", "dumbbell", "graduationcap", "gift", "wrench.and.screwdriver", "creditcard"]

    var body: some View {
        Form {
            if !isInbox { TextField(L("Title"), text: $name) }
            LabeledContent(L("Color")) {
                HStack(spacing: 6) {
                    ForEach(Self.colors, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex) ?? .accentColor)
                            .frame(width: 18, height: 18)
                            .overlay { if hex == color { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white) } }
                            .onTapGesture { color = hex }
                            .accessibilityLabel(hex.isEmpty ? L("Default color") : hex)
                    }
                }
            }
            LabeledContent(L("Icon")) {
                HStack(spacing: 4) {
                    ForEach(Self.icons, id: \.self) { symbol in
                        Image(systemName: symbol)
                            .frame(width: 24, height: 24)
                            .background(symbol == (icon.isEmpty ? "list.bullet" : icon) ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .onTapGesture { icon = symbol }
                    }
                }
            }
            Picker(L("Sort"), selection: $sort) {
                Text(L("Manually")).tag(SortMode.manual)
                Text(L("By due date")).tag(SortMode.due)
                Text(L("By priority")).tag(SortMode.priority)
                Text(L("By title")).tag(SortMode.title)
            }
            Toggle(L("Show completed"), isOn: $showDone)
            Section(L("New tasks")) {
                Picker(L("Priority"), selection: $defaultPriority) {
                    ForEach(Priority.all, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle(L("Due today"), isOn: $defaultDueToday)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(list == nil ? L("Create") : L("Done")) { save() }
                    .disabled(!isInbox && name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard let list else { return }
            name = list.name
            color = list.color
            icon = list.icon
            sort = list.sort
            showDone = list.showDone
            defaultPriority = list.defaultPriority
            defaultDueToday = list.defaultDueToday
        }
    }

    private func save() {
        let created = model.perform { store -> String in
            let id: String
            if let list {
                id = list.id
                if !isInbox, list.name != name { try store.renameList(id: id, name: name) }
            } else {
                id = try store.createList(name: name).id
            }
            let old = list
            if old?.color != color { try store.setListColor(id: id, color: color) }
            if old?.icon != icon { try store.setListIcon(id: id, icon: icon) }
            if old?.sort != sort { try store.setListSort(id: id, sort: sort) }
            if old?.showDone != showDone { try store.setListShowDone(id: id, show: showDone) }
            if old?.defaultPriority != defaultPriority || old?.defaultDueToday != defaultDueToday {
                try store.setListDefaults(id: id, priority: defaultPriority, dueToday: defaultDueToday)
            }
            return id
        }
        if list == nil, let created { model.scope = .list(id: created) }
        dismiss()
    }
}
