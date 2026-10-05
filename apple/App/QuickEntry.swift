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

/// Mirrors reminders of open tasks into local notifications.
@MainActor
final class Reminders {
    static let shared = Reminders()
    private var scheduled: [String: String] = [:]

    /// Takes the store as an argument: it is called while `AppModel.shared` is still being built.
    func refresh(_ store: Store?) {
        guard let store, let tasks = try? store.reminders() else { return }
        let wanted = Dictionary(uniqueKeysWithValues: tasks.compactMap { task in task.remind.map { (task.id, "\($0)|\(task.title)") } })
        guard wanted != scheduled else { return }
        scheduled = wanted

        let center = UNUserNotificationCenter.current()
        guard !tasks.isEmpty else { return center.removeAllPendingNotificationRequests() }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.removeAllPendingNotificationRequests()
            for task in tasks {
                guard let remind = task.remind, let date = Moment.date(remind), date > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = task.title
                if let due = task.due { content.body = L("Due: %@", "\(Moment.label(due).lowercased())") }
                content.sound = .default
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                center.add(UNNotificationRequest(identifier: task.id, content: content, trigger: trigger))
            }
        }
    }
}
