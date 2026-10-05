import AppKit
import KeyboardShortcuts
import SwiftUI
@preconcurrency import UserNotifications

extension KeyboardShortcuts.Name {
    static let quickEntry = Self("quickEntry", default: .init(.space, modifiers: [.control, .option]))
}

/// The field shared by the floating quick-entry panel and the menu bar window.
struct QuickEntryField: View {
    @Environment(AppModel.self) private var model
    var onDone: () -> Void
    @State private var text = ""
    @State private var listId = "inbox"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle").font(AppFont.style(.title2)).foregroundStyle(.secondary)
                TextField(L("New task"), text: $text)
                    .textFieldStyle(.plain)
                    .font(AppFont.style(.title3))
                    .focused($focused)
                    .onSubmit(save)
            }
            HStack(spacing: 6) {
                QuickChips(text: text)
                Spacer()
                Picker("", selection: $listId) {
                    ForEach(model.lists.filter { !$0.archived }, id: \.id) { Text(model.listName($0)).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
        }
        .onAppear { focused = true }
        .onExitCommand(perform: onDone)
    }

    private func save() {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return onDone() }
        if model.perform({ try $0.quickAdd(text: line, listId: listId) }) != nil {
            text = ""
            onDone()
        }
    }
}

/// A borderless panel that takes the keyboard without activating the app,
/// so the user stays in whatever they were doing.
final class QuickEntryPanel: NSPanel {
    static let shared = QuickEntryPanel()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 92),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }

    func toggle() {
        isVisible ? close() : present()
    }

    func present() {
        // A fresh view each time: the field starts empty and focused.
        let view = QuickEntryField(onDone: { [weak self] in self?.close() })
            .environment(AppModel.shared)
            .font(AppFont.style(.body))
            .padding(16)
            .frame(width: 560)
        contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            setFrameOrigin(NSPoint(x: frame.midX - self.frame.width / 2, y: frame.minY + frame.height * 0.68))
        }
        makeKeyAndOrderFront(nil)
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Turns the core's notification plan into local notifications.
@MainActor
final class Reminders {
    static let shared = Reminders()
    private var scheduled: [String] = []

    /// Takes the store as an argument: it is called while `AppModel.shared` is still being built.
    func refresh(_ store: Store?, settings: NotifySettings, sound: Bool) {
        guard let store, let plan = try? store.plannedNotifications(settings: settings) else { return }
        let signature = plan.map { "\($0.key)|\($0.at)|\($0.title)|\($0.count)|\(sound)" }
        guard signature != scheduled else { return }
        scheduled = signature

        let center = UNUserNotificationCenter.current()
        guard !plan.isEmpty else { return center.removeAllPendingNotificationRequests() }
        let requests: [UNNotificationRequest] = plan.compactMap { item in
            guard let date = Moment.date(item.at) else { return nil }
            let content = UNMutableNotificationContent()
            switch item.kind {
            case .summary:
                content.title = "Lists"
                content.body = L("Tasks due today or overdue: %@", "\(item.count)")
            case .reminder, .due:
                content.title = item.title
                if let due = item.due { content.body = L("Due: %@", Moment.label(due).lowercased()) }
            }
            if sound { content.sound = .default }
            if let task = item.taskId { content.userInfo = ["task": task] }
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return UNNotificationRequest(identifier: item.key, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        }
        // Permission is asked the first time there is something to show.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.removeAllPendingNotificationRequests()
            requests.forEach { center.add($0) }
        }
    }
}
