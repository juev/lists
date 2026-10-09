import AppKit
import KeyboardShortcuts
import SwiftUI
@preconcurrency import UserNotifications

extension KeyboardShortcuts.Name {
    static let quickEntry = Self("quickEntry", default: .init(.space, modifiers: [.control, .option]))
}

/// The new-task card shared by the floating quick-entry panel and the menu bar window.
struct QuickEntryField: View {
    @Environment(AppModel.self) private var model
    var onDone: () -> Void
    var onResize: () -> Void
    /// The floating panel: the card pads itself and ends with the strip of the list and the buttons (R82).
    var footer: Bool
    @State private var draft: TaskDraft

    /// `notes` is what the card starts with when it was taken from the clipboard (R58).
    init(notes: String? = nil, footer: Bool = false, onDone: @escaping () -> Void, onResize: @escaping () -> Void = {}) {
        self.onDone = onDone
        self.onResize = onResize
        self.footer = footer
        _draft = State(initialValue: TaskDraft(notes: notes ?? "", pastedNotes: notes))
    }

    var body: some View {
        DraftEditor(draft: $draft, onClose: {
            draft = TaskDraft(listId: model.defaultListId)
            onDone()
        }, onResize: onResize, footer: footer)
            .onAppear { draft.listId = model.defaultListId }
    }
}

/// A borderless panel that takes the keyboard without activating the app,
/// so the user stays in whatever they were doing.
final class QuickEntryPanel: NSPanel {
    static let shared = QuickEntryPanel()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 92),
            // No frame of the system: the card draws the panel itself, with corners rounder than a window has (R82).
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    /// The radius of the corners the panel is drawn with.
    static let corner: CGFloat = 16

    #if DEBUG
    /// Set by the debug script to measure the panel without taking the keyboard from the person at the machine.
    static var debugSilent = false
    override var canBecomeKey: Bool { !Self.debugSilent }
    #else
    override var canBecomeKey: Bool { true }
    #endif

    func toggle() {
        isVisible ? close() : present()
    }

    func present() {
        // A fresh view each time: the field starts empty and focused.
        // R58: what was copied since the panel was last shown becomes the note.
        let notes = AppModel.shared.clipboardNotes ? ClipboardNote.take() : nil
        let view = QuickEntryField(notes: notes, footer: true, onDone: { [weak self] in self?.close() }, onResize: { [weak self] in self?.refit() })
            .environment(AppModel.shared)
            .font(AppFont.style(.body))
            .frame(width: 520)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        let hosting = NSHostingView(rootView: view)
        hosting.safeAreaRegions = []
        contentView = hosting
        setContentSize(hosting.fittingSize)
        // The card was placed for the size the panel had before, which on the
        // first show is not the size of a card at all. Lay it out again before
        // the panel is shown, or the first frame is drawn with the card off
        // its place.
        hosting.layoutSubtreeIfNeeded()
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            setFrameTopLeftPoint(NSPoint(x: frame.midX - self.frame.width / 2, y: frame.minY + frame.height * 0.78))
        }
        setAsideWindowsOfHiddenApp()
        makeKeyAndOrderFront(nil)
        // SwiftUI asks for focus when the view appears, which is before the
        // panel is the key window, and the request is dropped. Hand the
        // keyboard to the field once the panel has it.
        DispatchQueue.main.async { [weak self] in self?.focusField() }
    }

    private func focusField() {
        contentView?.layoutSubtreeIfNeeded()
        func field(in view: NSView) -> NSTextField? {
            if let found = view as? NSTextField, found.isEditable { return found }
            return view.subviews.lazy.compactMap(field(in:)).first
        }
        if let target = contentView.flatMap(field(in:)) { makeFirstResponder(target) }
    }

    /// Grows or shrinks with the card, keeping the top edge where it is.
    private func refit() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let size = self.contentView?.fittingSize, size.height != self.contentView?.frame.height else { return }
            let top = NSPoint(x: self.frame.minX, y: self.frame.maxY)
            self.setContentSize(size)
            self.setFrameTopLeftPoint(top)
            // The shadow follows the shape the card draws.
            self.invalidateShadow()
        }
    }

    override func resignKey() {
        super.resignKey()
        // A popover of the card (a date, a tag) takes the keyboard for a
        // moment; the panel goes away only when something else does.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isKeyWindow else { return }
            // The open panel of "File or image" is not the user leaving either.
            if NSApp.modalWindow != nil { return }
            if let key = NSApp.keyWindow, key.parent === self || self.childWindows?.contains(key) == true { return }
            self.close()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// The windows that were on screen when the app was hidden: the ones that come back with it.
    private var hiddenWith: [NSWindow] = []
    /// The windows taken off screen so that the panel could be shown alone, and their transparency before that.
    private var setAside: [(window: NSWindow, alpha: CGFloat)] = []
    private var observers: [NSObjectProtocol] = []

    /// Starts keeping track of what Hide Lists (⌘H) hides. Called once, when the app starts: a hidden app
    /// no longer tells which of its windows were on screen.
    func watchHiding() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.willHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.setAside.isEmpty else { return }
                    self.hiddenWith = NSApp.windows.filter { $0 !== self && !($0 is NSPanel) && $0.canBecomeMain && $0.isVisible }
                }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.returnWindows(hide: false) }
            },
        ]
    }

    /// A hidden app is shown again with all its windows as soon as one of them is ordered front, the panel among
    /// them. Only the panel is wanted: the windows the app was hidden with are ordered out first, transparent so
    /// that not a frame of them is drawn, and then the app is shown. They return when the panel closes or the
    /// person comes back to the app.
    private func setAsideWindowsOfHiddenApp() {
        guard NSApp.isHidden else { return }
        for window in hiddenWith where NSApp.windows.contains(window) {
            setAside.append((window, window.alphaValue))
            window.alphaValue = 0
            window.orderOut(nil)
        }
        hiddenWith = []
        NSApp.unhideWithoutActivation()
    }

    /// Puts back what `setAsideWindowsOfHiddenApp` took away. With `hide` the app goes back to being hidden, as it
    /// was before the panel: the windows are ordered in transparent and are seen again when the app is shown.
    private func returnWindows(hide: Bool) {
        guard !setAside.isEmpty else { return }
        let windows = setAside
        setAside = []
        guard hide else {
            for (window, alpha) in windows {
                window.alphaValue = alpha
                window.orderFront(nil)
            }
            return
        }
        windows.forEach { $0.window.orderBack(nil) }
        hiddenWith = windows.map(\.window)
        var token: NSObjectProtocol?
        let restore = {
            windows.forEach { $0.window.alphaValue = $0.alpha }
            token.map(NotificationCenter.default.removeObserver)
            token = nil
        }
        token = NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated(restore)
        }
        NSApp.hide(nil)
        // Whatever becomes of the hiding, a window is not left transparent.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if token != nil { restore() } }
    }

    override func close() {
        super.close()
        // The person went on in another app: Lists is hidden again. They came to Lists itself: its windows are back.
        returnWindows(hide: !NSApp.isActive)
    }
}

/// The sounds a notification can play besides the standard one (R36): the alert sounds of the system.
enum NotifySound {
    private static let folder = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)

    /// Without the extension, as System Settings shows them.
    static let names: [String] = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "aiff" }
        .map { $0.deletingPathExtension().lastPathComponent }
        .sorted()

    static func play(_ name: String) {
        guard names.contains(name) else { return }
        NSSound(named: name)?.play()
    }

    /// Where the copy of a sound is kept for the notification centre; nil in a build without a group.
    static func copy(of name: String) -> URL? {
        guard let group = Storage.groupIdentifier,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container.appendingPathComponent("Library/Sounds/\(name).aiff")
    }

    /// The empty name and a name the system no longer has give the standard sound.
    ///
    /// A notification finds a sound by its file name in `Library/Sounds` of the
    /// app's containers and in its bundle; the system folder is not among the
    /// places the documentation names. So the sound is copied into the group
    /// container before it is asked for by name.
    static func notification(_ name: String) -> UNNotificationSound {
        guard names.contains(name) else { return .default }
        let fm = FileManager.default
        if let copy = copy(of: name), !fm.fileExists(atPath: copy.path) {
            try? fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: folder.appendingPathComponent("\(name).aiff"), to: copy)
        }
        return UNNotificationSound(named: UNNotificationSoundName("\(name).aiff"))
    }
}

/// Turns the core's notification plan into local notifications.
@MainActor
final class Reminders {
    static let shared = Reminders()
    private var scheduled: [String] = []

    /// Takes the store as an argument: it is called while `AppModel.shared` is still being built.
    /// `sound` is the name of a system sound, empty for the standard one and nil for silence.
    func refresh(_ store: Store?, settings: NotifySettings, sound: String?) {
        guard let store, let plan = try? store.plannedNotifications(settings: settings) else { return }
        let signature = plan.map { "\($0.key)|\($0.at)|\($0.title)|\($0.count)|\(sound ?? "-")" }
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
            if let sound { content.sound = NotifySound.notification(sound) }
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
