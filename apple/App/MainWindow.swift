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
                // Set per column: the split view does not pass the font down from the window.
                .font(AppFont.style(.body))
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            TaskListView()
                .font(AppFont.style(.body))
                .navigationTitle(model.scopeTitle)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.startDraft() } label: { Image(systemName: "plus") }
                            .help(L("New task"))
                    }
                    ToolbarItem(placement: .primaryAction) { SyncIndicator() }
                }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: L("Search"))
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .alert(model.alertIsError ? L("That did not work") : "Lists", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
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
    @State private var editingFilter: SavedFilter?

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
                if model.showCompletedView {
                    row(.completed, L("Completed"), "checkmark.square", count: 0)
                }
                if model.counts.trash > 0 {
                    row(.trash, L("Trash"), "trash", count: model.counts.trash)
                }
            }
            Section {
                ForEach(model.lists.filter { $0.id != "inbox" && !$0.archived }, id: \.id) { list in
                    Label {
                        HStack {
                            Text(list.name).font(AppFont.style(.body))
                            Spacer()
                            if list.openCount > 0 { Text("\(list.openCount)").foregroundStyle(.secondary).monospacedDigit() }
                        }
                    } icon: {
                        Image(systemName: list.symbol).foregroundStyle(list.tint)
                    }
                    .font(AppFont.style(.body))
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
            } header: {
                header(L("Lists"), help: L("New list")) { model.creatingList = true }
            }
            if !model.tags.isEmpty {
                Section(L("Tags")) {
                    ForEach(model.tags, id: \.name) { tag in
                        Label {
                            HStack {
                                Text(tag.name).font(AppFont.style(.body))
                                Spacer()
                                Text("\(tag.openCount)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        } icon: {
                            Image(systemName: "number")
                        }
                        .font(AppFont.style(.body))
                        .tag(Scope.tag(name: tag.name))
                    }
                }
            }
            if !model.projects.isEmpty {
                Section(L("Projects")) {
                    ForEach(model.projects, id: \.id) { project in
                        Label {
                            HStack {
                                Text(project.title).lineLimit(1).font(AppFont.style(.body))
                                Spacer()
                                Text("\(project.subtasksDone)/\(project.subtasksTotal)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        } icon: {
                            Image(systemName: "folder").foregroundStyle(model.list(project.listId)?.tint ?? .accentColor)
                        }
                        .font(AppFont.style(.body))
                        .tag(Scope.project(id: project.id))
                        .contextMenu {
                            Button(L("Turn back into a task")) { model.perform { try $0.setProject(id: project.id, project: false) } }
                        }
                    }
                }
            }
            // Shown even when empty: the header is where a filter is made.
            do {
                Section {
                    ForEach(model.filters, id: \.id) { filter in
                        Label {
                            HStack {
                                Text(filter.name).lineLimit(1).font(AppFont.style(.body))
                                Spacer()
                                if filter.openCount > 0 { Text("\(filter.openCount)").foregroundStyle(.secondary).monospacedDigit() }
                            }
                        } icon: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        .font(AppFont.style(.body))
                        .tag(Scope.filter(id: filter.id))
                        .contextMenu {
                            Button(L("Configure…")) { editingFilter = filter }
                            Button(L("Delete filter"), role: .destructive) { model.perform { try $0.deleteFilter(id: filter.id) } }
                        }
                    }
                } header: {
                    header(L("Filters"), help: L("New filter")) { model.creatingFilter = true }
                }
            }
            let archived = model.lists.filter(\.archived)
            if !archived.isEmpty {
                Section(L("Archived lists")) {
                    ForEach(archived, id: \.id) { list in
                        Label(list.name, systemImage: "archivebox")
                            .foregroundStyle(.secondary)
                            .font(AppFont.style(.body))
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
                Menu {
                    Button(L("New list")) { model.creatingList = true }
                    Button(L("New filter")) { model.creatingFilter = true }
                } label: {
                    Label(L("New list"), systemImage: "plus")
                } primaryAction: {
                    model.creatingList = true
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
        .sheet(item: $editing) { ListEditor(list: $0) }
        .sheet(isPresented: $model.creatingList) { ListEditor(list: nil) }
        .sheet(item: $editingFilter) { FilterEditor(filter: $0) }
        .sheet(isPresented: $model.creatingFilter) { FilterEditor(filter: nil) }
    }

    /// A section title with the button that adds to the section.
    private func header(_ title: String, help: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: add) { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(help)
                .accessibilityLabel(help)
        }
    }

    private func row(_ scope: Scope, _ title: String, _ symbol: String, count: UInt32, alert: Bool = false) -> some View {
        Label {
            HStack {
                Text(title).font(AppFont.style(.body))
                Spacer()
                if count > 0 {
                    Text("\(count)").foregroundStyle(alert ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)).monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .font(AppFont.style(.body))
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
                            .overlay { if hex == color { Image(systemName: "checkmark").font(AppFont.style(.caption2, weight: .bold)).foregroundStyle(.white) } }
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
            Toggle(L("Keep completed tasks in this list"), isOn: $showDone)
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

extension SavedFilter: Identifiable {}

/// A saved view: which dates, lists, tags, priority and status it lets through.
struct FilterEditor: View {
    let filter: SavedFilter?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Window: Hashable { case any, overdue, today, next, noDate }

    @State private var name = ""
    @State private var window = Window.any
    @State private var days = 7
    @State private var lists: Set<String> = []
    @State private var tags = ""
    @State private var priority = Priority.none
    @State private var status = FilterStatus.open
    @State private var text = ""
    @State private var matching = 0

    private var spec: FilterSpec {
        let due: DueWindow
        switch window {
        case .any: due = .any
        case .overdue: due = .overdue
        case .today: due = .today
        case .next: due = .next(days: UInt32(days))
        case .noDate: due = .noDate
        }
        return FilterSpec(
            due: due, listIds: lists.sorted(),
            tags: tags.split(whereSeparator: { $0 == " " || $0 == "," }).map { String($0) },
            minPriority: priority, status: status, text: text)
    }

    var body: some View {
        Form {
            TextField(L("Title"), text: $name)
            if filter == nil {
                LabeledContent(L("Start from")) {
                    HStack {
                        Button(L("Next 7 days")) { name = L("Next 7 days"); window = .next; days = 7 }
                        Button(L("Overdue")) { name = L("Overdue"); window = .overdue }
                        Button(L("High priority")) { name = L("High priority"); window = .any; priority = .high }
                        Button(L("No date")) { name = L("No date"); window = .noDate }
                    }
                    .controlSize(.small)
                }
            }
            Picker(L("Date"), selection: $window) {
                Text(L("Any")).tag(Window.any)
                Text(L("Overdue")).tag(Window.overdue)
                Text(L("Today")).tag(Window.today)
                Text(L("The coming days")).tag(Window.next)
                Text(L("No date")).tag(Window.noDate)
            }
            if window == .next {
                Stepper(L("Days: %@", "\(days)"), value: $days, in: 1...365)
            }
            LabeledContent(L("Lists")) {
                VStack(alignment: .leading) {
                    ForEach(model.lists.filter { !$0.archived }, id: \.id) { list in
                        Toggle(model.listName(list), isOn: Binding(
                            get: { lists.contains(list.id) },
                            set: { if $0 { lists.insert(list.id) } else { lists.remove(list.id) } }))
                    }
                    Text(L("None checked means every list.")).font(AppFont.style(.caption)).foregroundStyle(.secondary)
                }
            }
            TextField(L("Tags"), text: $tags, prompt: Text(L("all of these, separated by spaces")))
            Picker(L("Priority at least"), selection: $priority) {
                ForEach(Priority.all, id: \.self) { Text($0 == .none ? L("Any") : $0.title).tag($0) }
            }
            Picker(L("Status"), selection: $status) {
                Text(L("Open")).tag(FilterStatus.open)
                Text(L("Completed")).tag(FilterStatus.done)
                Text(L("All")).tag(FilterStatus.all)
            }
            TextField(L("Contains"), text: $text)
            Text(L("Tasks matching now: %@", "\(matching)")).font(AppFont.style(.caption)).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(filter == nil ? L("Create") : L("Done"), action: save)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: load)
        .onChange(of: spec) { _, new in count(new) }
    }

    private func count(_ spec: FilterSpec) {
        matching = (try? model.store?.previewFilter(spec: spec).count) ?? 0
    }

    private func load() {
        defer { count(spec) }
        guard let filter else { return }
        name = filter.name
        switch filter.spec.due {
        case .any: window = .any
        case .overdue: window = .overdue
        case .today: window = .today
        case .next(let n): window = .next; days = Int(n)
        case .noDate: window = .noDate
        }
        lists = Set(filter.spec.listIds)
        tags = filter.spec.tags.joined(separator: " ")
        priority = filter.spec.minPriority
        status = filter.spec.status
        text = filter.spec.text
    }

    private func save() {
        let created = model.perform { store -> String in
            if let filter {
                try store.updateFilter(id: filter.id, name: name, spec: spec)
                return filter.id
            }
            return try store.createFilter(name: name, spec: spec).id
        }
        if filter == nil, let created { model.scope = .filter(id: created) }
        dismiss()
    }
}
