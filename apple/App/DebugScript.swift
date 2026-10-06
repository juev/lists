#if DEBUG
import AppKit

/// Drives the app from inside for checks that need key presses: macOS lets no
/// outside process send them without the Accessibility permission. Debug
/// builds only. `LISTS_DEBUG_SCRIPT` holds steps separated by `;`:
/// `type:text`, `key:return`, `key:n+cmd`, `sleep:0.5`, `click:x,y`, `quick`, `settings`,
/// `state` (prints who has the keyboard and the text being typed into), `copyfiles:path,path` and `copyimage`
/// (fill the pasteboard), `draft` (prints the files of the open new-task card),
/// `files` (prints the attachments of the selected task: the name of the copy made for Quick Look, the type the system sees in it and the size of the thumbnail),
/// `inbox` (switches to the Inbox view), `open` (expands the selected task), `select:1` and `select:-1` (move the selection the way the arrow keys do),
/// `pick:title` (selects a row the way a click does), `indent` and `outdent` (move the selected task under the one above and back),
/// `newtask` (opens the card of a new task), `title:text` (fills its title), `finish` (closes it the way Esc does),
/// `due:2026-10-05` and `repeat:2` (give the new-task card a due date and the preset with that index, the way its popovers do),
/// `task` (prints the due date and the repeat of the selected task), `done` (completes it),
/// `cards` (prints the open cards and the selected row), `rows` (prints the rows in the order they are drawn), `panel` (prints whether quick entry is on screen and what runs modally),
/// `windows` (prints the windows of the app),
/// `notes` (prints the note of the open card as it is drawn: what is hidden, what is replaced and which fonts differ),
/// `shot:/path/to.png` (draws that note into a file, on screen or not),
/// `caret:5` (puts the cursor of that note at the offset), `box:0` (clicks the checkbox with that number in it),
/// `completedview:on` and `completedview:off` (flip the setting that offers the Completed view), `scope` (prints the current view),
/// `menu:Title` (prints whether the menu bar item with that title is enabled),
/// `sidebar` (prints how many rows each list of the main window has, the sidebar among them),
/// `copytext:text`, `copysecret:text` and `copyfile:path` (fill the pasteboard quick entry reads; with `LISTS_DEBUG_PASTEBOARD=name` that is a pasteboard of its own, not the general one),
/// `clipnotes:on` and `clipnotes:off` (flip the setting of R58), `quicknote` (shows quick entry transparent and without the keyboard, and prints the note it starts with; `quicknote:/path.png` also draws the card into a file),
/// `quicktrace` (shows quick entry transparent and without the keyboard, and prints its geometry frame by frame:
/// a line that differs from the next one is a card that moved after it was shown).
/// With `LISTS_DEBUG_QUIET` set the script leaves the app in the background instead of bringing its window forward;
/// key presses then go straight to the main window, which takes them hidden as well.
@MainActor
enum DebugScript {
    private static let codes: [String: (UInt16, String)] = [
        "return": (36, "\r"), "esc": (53, "\u{1b}"), "space": (49, " "), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
        "]": (30, "]"), "[": (33, "["), "tab": (48, "\t"),
    ]

    static func runIfAsked() {
        guard let script = ProcessInfo.processInfo.environment["LISTS_DEBUG_SCRIPT"] else { return }
        setlinebuf(stdout)
        let steps = script.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }
        _Concurrency.Task { @MainActor in
            try? await _Concurrency.Task.sleep(for: .seconds(1.5))
            let quiet = ProcessInfo.processInfo.environment["LISTS_DEBUG_QUIET"] != nil
            for _ in 0..<30 where !quiet && NSApp.keyWindow == nil {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                try? await _Concurrency.Task.sleep(for: .milliseconds(150))
            }
            for step in steps {
                let name = step.split(separator: ":", maxSplits: 1).first.map(String.init) ?? step
                let argument = step.contains(":") ? String(step.dropFirst(name.count + 1)) : ""
                switch name {
                case "sleep": try? await _Concurrency.Task.sleep(for: .seconds(Double(argument) ?? 0.5))
                case "type": for character in argument { press(String(character), code: 0, flags: []) }
                case "key":
                    let parts = argument.split(separator: "+").map(String.init)
                    var flags: NSEvent.ModifierFlags = []
                    if parts.contains("cmd") { flags.insert(.command) }
                    if parts.contains("opt") { flags.insert(.option) }
                    if parts.contains("shift") { flags.insert(.shift) }
                    let key = codes[parts[0]] ?? (0, parts[0])
                    press(key.1, code: key.0, flags: flags)
                case "click":
                    // Points from the top left corner of the key window.
                    let xy = argument.split(separator: ",").compactMap { Double($0) }
                    if xy.count == 2, let window = NSApp.keyWindow {
                        let point = NSPoint(x: xy[0], y: Double(window.frame.height) - xy[1])
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let event = NSEvent.mouseEvent(
                                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                // Queued, not sent: a view that tracks the mouse waits for the release in the queue.
                                NSApp.postEvent(event, atStart: false)
                            }
                        }
                    }
                case "copyfiles":
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects(argument.split(separator: ",").map { NSURL(fileURLWithPath: String($0)) })
                case "copyimage":
                    let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                        NSColor.red.setFill()
                        rect.fill()
                        return true
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(image.tiffRepresentation, forType: .tiff)
                case "draft":
                    print("debug: draft files \(AppModel.shared.draft?.files.map(\.lastPathComponent) ?? [])")
                case "files":
                    let files = AppModel.shared.selection.flatMap { try? AppModel.shared.store?.attachments(taskId: $0) } ?? []
                    for file in files {
                        let named = AttachmentFiles.named(file)
                        let thumbnail = file.localPath.flatMap { AttachmentFiles.thumbnail(path: $0, pixels: 56) }
                        let type = named.flatMap { try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier } ?? "-"
                        print("debug: file \(file.name) named=\(named?.lastPathComponent ?? "-") type=\(type) thumbnail=\(thumbnail.map { "\($0.width)x\($0.height)" } ?? "-")")
                    }
                case "open":
                    if let id = AppModel.shared.selection { AppModel.shared.toggleExpanded(id) }
                case "select": AppModel.shared.moveSelection(Int(argument) ?? 1)
                case "pick": AppModel.shared.selection = taskId(titled: argument)
                case "indent": AppModel.shared.selectedTask.map(AppModel.shared.indent)
                case "outdent": AppModel.shared.selectedTask.map(AppModel.shared.outdent)
                case "newtask": AppModel.shared.startDraft()
                case "title": AppModel.shared.draft?.title = argument
                case "finish": AppModel.shared.finishDraft()
                case "due":
                    AppModel.shared.draft?.due = argument
                    AppModel.shared.draft?.dueIsDefault = false
                case "repeat":
                    if let index = Int(argument), Repeat.presets.indices.contains(index) { AppModel.shared.draft?.repeat = Repeat.presets[index].1 }
                case "done": AppModel.shared.selectedTask.map(AppModel.shared.toggleDone)
                case "task":
                    let task = AppModel.shared.selectedTask
                    print("debug: task \(task?.title ?? "none"), due \(task?.due ?? "none"), repeat \(task?.repeat?.summary ?? "none")")
                case "inbox": AppModel.shared.scope = .inbox
                case "completedview": AppModel.shared.showCompletedView = argument != "off"
                case "scope": print("debug: scope \(AppModel.shared.scopeTitle), completed view \(AppModel.shared.showCompletedView ? "on" : "off")")
                case "menu":
                    let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
                    let item = items.first { $0.title == argument }
                    print("debug: menu \(argument) \(item.map { $0.isEnabled ? "enabled" : "disabled" } ?? "missing")")
                case "sidebar": print("debug: sidebar rows \(tableRows(in: target?.contentView?.superview))")
                case "cards":
                    let model = AppModel.shared
                    let open = model.expanded.map(taskTitle).sorted()
                    print("debug: open \(open), selected \(model.selection.map(taskTitle) ?? "none"), draft \(model.draft != nil)")
                case "rows": print("debug: rows \(AppModel.shared.visibleIds.map(taskTitle))")
                case "panel":
                    print("debug: quick entry \(QuickEntryPanel.shared.isVisible ? "shown" : "hidden"), modal \(NSApp.modalWindow.map { String(describing: type(of: $0)) } ?? "none")")
                case "quick": QuickEntryPanel.shared.present()
                case "copytext", "copysecret", "copyfile":
                    let pasteboard = ClipboardNote.pasteboard
                    pasteboard.clearContents()
                    if name == "copyfile" {
                        pasteboard.writeObjects([NSURL(fileURLWithPath: argument)])
                    } else {
                        pasteboard.setString(argument, forType: .string)
                    }
                    if name == "copysecret" { pasteboard.setString("", forType: .init("org.nspasteboard.ConcealedType")) }
                case "clipnotes": AppModel.shared.clipboardNotes = argument != "off"
                case "quicknote":
                    // Shown transparent and without the keyboard, as in `quicktrace`.
                    QuickEntryPanel.debugSilent = true
                    let panel = QuickEntryPanel.shared
                    panel.alphaValue = 0
                    panel.present()
                    try? await _Concurrency.Task.sleep(for: .milliseconds(200))
                    if argument.hasPrefix("/"), let view = panel.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: image)
                        try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
                    }
                    print("debug: quick note \"\(notesView(in: panel.contentView)?.string ?? "none")\", height \(Int(panel.frame.height))")
                    panel.close()
                    panel.alphaValue = 1
                    QuickEntryPanel.debugSilent = false
                    try? await _Concurrency.Task.sleep(for: .milliseconds(300))
                case "quicktrace":
                    QuickEntryPanel.debugSilent = true
                    let started = ProcessInfo.processInfo.systemUptime
                    let panel = QuickEntryPanel.shared
                    panel.alphaValue = 0
                    panel.present()
                    let ms = { Int((ProcessInfo.processInfo.systemUptime - started) * 1000) }
                    print("debug: trace +\(ms())ms returned  \(geometry(panel))")
                    for _ in 0..<12 {
                        try? await _Concurrency.Task.sleep(for: .milliseconds(16))
                        print("debug: trace +\(ms())ms           \(geometry(panel))")
                    }
                    panel.close()
                    panel.alphaValue = 1
                    QuickEntryPanel.debugSilent = false
                    try? await _Concurrency.Task.sleep(for: .milliseconds(300))
                case "settings": NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                case "windows":
                    for window in NSApp.windows {
                        print("debug: window \(type(of: window)) titled \(window.styleMask.contains(.titled)) resizable \(window.styleMask.contains(.resizable)) visible \(window.isVisible) key \(window.isKeyWindow) frame \(NSStringFromRect(window.frame))")
                    }
                case "state":
                    let window = target
                    print("debug: key window \(window.map { type(of: $0) }.map(String.init(describing:)) ?? "none"), first responder \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")\((window?.firstResponder as? NSText).map { " with \"\($0.string)\"" } ?? "")")
                case "shot":
                    // The note drawn into a file: it need not be on screen for that.
                    if let view = notesView(in: target?.contentView), let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: image)
                        let page = NSImage(size: view.bounds.size, flipped: false) { rect in
                            NSColor.textBackgroundColor.setFill()
                            rect.fill()
                            return image.draw(in: rect)
                        }
                        let data = page.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
                        try? data?.write(to: URL(fileURLWithPath: argument))
                    }
                case "notes": print("debug: notes \(notesView(in: target?.contentView)?.debugState ?? "none")")
                case "caret": notesView(in: target?.contentView)?.setSelectedRange(NSRange(location: Int(argument) ?? 0, length: 0))
                case "box": print("debug: box \(argument) clicked \(notesView(in: target?.contentView)?.debugClickBox(Int(argument) ?? 0) ?? false)")
                default: print("debug: unknown step \(step)")
                }
                try? await _Concurrency.Task.sleep(for: .milliseconds(60))
            }
            print("debug: script finished")
            fflush(stdout)
        }
    }

    private static func notesView(in view: NSView?) -> MarkdownTextView? {
        guard let view else { return nil }
        return (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(notesView(in:)).first
    }

    private static var shown: [TaskItem] {
        AppModel.shared.allTasks + AppModel.shared.children.values.joined()
    }

    private static func taskTitle(_ id: String) -> String {
        shown.first { $0.id == id }?.title ?? id
    }

    private static func taskId(titled title: String) -> String? {
        shown.first { $0.title == title }?.id
    }

    /// Row counts of the tables in a window: SwiftUI draws each `List` as one, the sidebar included.
    private static func tableRows(in view: NSView?) -> [Int] {
        guard let view else { return [] }
        return ((view as? NSTableView).map { [$0.numberOfRows] } ?? []) + view.subviews.flatMap(tableRows(in:))
    }

    private static func geometry(_ panel: NSPanel) -> String {
        func field(in view: NSView) -> NSTextField? {
            if let found = view as? NSTextField, found.isEditable { return found }
            return view.subviews.lazy.compactMap(field(in:)).first
        }
        let content = panel.contentView
        let title = content.flatMap(field(in:)).map { NSStringFromRect($0.convert($0.bounds, to: nil)) } ?? "none"
        return "frame \(NSStringFromRect(panel.frame)) content \(content.map { NSStringFromRect($0.frame) } ?? "none")"
            + " fitting \(content.map { NSStringFromSize($0.fittingSize) } ?? "none") title \(title)"
            + " visible \(panel.isVisible) onscreen \(panel.occlusionState.contains(.visible)) key \(panel.isKeyWindow)"
    }

    private static func press(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags) {
        guard let window = target else { return print("debug: no key window for \(characters)") }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                // The application hands key events to its key window only; a window
                // in the background takes them directly.
                if window.isKeyWindow { NSApp.sendEvent(event) } else { window.sendEvent(event) }
            }
        }
    }

    /// The window the script types into: the key window, or the main window of
    /// an app that was left in the background.
    static var target: NSWindow? { NSApp.keyWindow ?? backgroundWindow }

    /// The main window of an app that a quiet script left hidden. `canBecomeMain`
    /// is false for it, so it is told by its look.
    static var backgroundWindow: NSWindow? {
        guard ProcessInfo.processInfo.environment["LISTS_DEBUG_QUIET"] != nil else { return nil }
        return NSApp.windows.first { !($0 is NSPanel) && $0.styleMask.contains(.resizable) }
    }
}
#endif
