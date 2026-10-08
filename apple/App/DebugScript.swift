#if DEBUG
import AppKit
import Quartz
import SwiftUI
import UserNotifications

/// Drives the app from inside for checks that need key presses: macOS lets no
/// outside process send them without the Accessibility permission. Debug
/// builds only. `LISTS_DEBUG_SCRIPT` holds steps separated by `;`:
/// `type:text`, `key:return`, `key:n+cmd`, `sleep:0.5`, `click:x,y`, `quick`, `settings`,
/// `state` (prints who has the keyboard, the text being typed into and the size of its field), `copyfiles:path,path` and `copyimage`
/// (fill the pasteboard), `draft` (prints the files and the dates of the open new-task card),
/// `code:17` (presses the key with that key code, whatever the layout, in the date editor: the open popover, or the one `dateeditor` made;
/// for a popover the press carries the window the popover hangs on, as a press on the keyboard does: `scripts/postkey.swift` sends
/// such a press from outside and is the check of that),
/// `dateeditor:2026-10-05` (builds the editor of the date popover with that value, or with none, in a window that is never shown,
/// and prints each value it applies: a hidden app shows no popovers), `datefield:time` and `datefield:calendar` (give the keyboard to its time field or to its calendar),
/// `dateeditor` alone prints who has the keyboard in the date editor and the day selected in its calendar,
/// `files` (prints the attachments of the selected task: the name of the copy made for Quick Look, the type the system sees in it and the size of the thumbnail;
/// whether its content is on this device; then how many attachments wait to sync,
/// the file whose row has the keyboard and how many times a card asked Quick Look for a file),
/// `sync` (starts a sync the way the toolbar icon does), `attach:/path` (attaches the file to the selected task), `showfile:0` (shows the attachment with that number the way a click on its name does;
/// a hidden app shows no panel), `preview` (prints whether the Quick Look panel is open) and `preview:close` (closes it),
/// `inbox` (switches to the Inbox view), `open` (expands the selected task), `edit` (opens it with the caret in the title, the way Return does), `select:1` and `select:-1` (move the selection the way the arrow keys do),
/// `pick:title` (selects a row the way a click does), `indent` and `outdent` (move the selected task under the one above and back),
/// `newtask` (opens the card of a new task), `title:text` (fills its title), `finish` (closes it the way Esc does),
/// `due:2026-10-05` and `repeat:2` (give the new-task card a due date and the preset with that index, the way its popovers do),
/// `due` alone (takes the due date away the way ⌫ in its popover does), `priority:3` (chooses the priority with that index in the card, 0 for none),
/// `mklist:Name` (creates a list whose defaults for new tasks are the high priority and "due today"), `draftlist:Name` (chooses that list in the card, `draftlist:inbox` the Inbox), `start:2026-10-05` (gives the card a start date); `draft` also prints the due date, the priority, the tags and the list the card shows,
/// `task` (prints the due date, the priority, the tags and the repeat of the selected task), `done` (completes it),
/// `cards` (prints the open cards and the selected row), `rows` (prints the rows in the order they are drawn), `panel` (prints whether quick entry is on screen and what runs modally),
/// `windows` (prints the windows of the app),
/// `notes` (prints the note of the open card as it is drawn: what is hidden, what is replaced and which fonts differ),
/// `shot:/path/to.png` (draws that note into a file, on screen or not),
/// `rowshot:/path/to.png` (draws the row of the selected task into a file, eight pixels to a point: a hidden window draws no rows;
/// the launch arguments `-textScale 1.5 -fontDesign serif` choose the text for one run and save nothing),
/// `caret:5` (puts the cursor of that note at the offset), `box:0` (clicks the checkbox with that number in it),
/// `noteclick:5` (clicks the character of that note at the offset and prints the address a link there hands to the system; the browser is not opened),
/// `chips` (prints which chip of the card has the keyboard and which of its popovers is open; `key:backtab+shift` is ⇧Tab),
/// `ghost` (puts the windows of a hidden app on screen transparent, deaf to the mouse and without the keyboard, popovers that open later among them:
/// a hidden app shows no popovers; key presses then go to the open popover first, as they do when it has the keyboard),
/// `wont` (closes the selected task as "won't do"; `task` prints the state of the selected task), `go:completed`, `go:wontdo`, `go:today`, `go:#tag` and `go:List name` (switch to those views),
/// `completedview:on` and `completedview:off` (flip the setting that offers the Completed view), `scope` (prints the current view),
/// `calendarevents` (prints the setting of R78, the access the system gave, and how many calendars are listed and hidden; nothing is asked of the system),
/// `events:14:30=Bank,-=Birthday,09:00=Standup,y=Trip` (puts those events through the order of the block in place of the calendars of the system:
/// `-` is an all-day event, `y` one that began yesterday) and `events` alone print whether the block is on show and its lines,
/// `keepdone:5` (sets for how many seconds a completed task stays in view), `keepdone:day` (until the end of the day) and `keepdone` alone (prints it),
/// `sound:Glass` (chooses the sound of notifications without playing it, `sound:` the standard one; `sound` alone leaves the choice as it is) prints the choice,
/// whether a notification gets the standard sound, where the copy for the notification centre is and the sounds on offer; no notification is scheduled,
/// `appearance:dark`, `appearance:light` and `appearance:system` (choose the look the way Settings does),
/// `appearance` alone prints the choice and the look each window of the app has, the quick-entry panel among them,
/// `menu:Title` (prints whether the menu bar item with that title is enabled),
/// `sidebar` (prints how many rows each list of the main window has, the sidebar among them),
/// `copytext:text`, `copysecret:text` and `copyfile:path` (fill the pasteboard quick entry reads; with `LISTS_DEBUG_PASTEBOARD=name` that is a pasteboard of its own, not the general one),
/// `clipnotes:on` and `clipnotes:off` (flip the setting of R58), `quicknote` (shows quick entry transparent and without the keyboard, and prints the note it starts with; `quicknote:/path.png` also draws the card into a file),
/// `quicktrace` (shows quick entry transparent and without the keyboard, and prints its geometry frame by frame:
/// a line that differs from the next one is a card that moved after it was shown).
/// With `LISTS_DEBUG_QUIET` set the script leaves the app in the background instead of bringing its window forward;
/// key presses then go straight to the main window, which takes them hidden as well, and so do clicks after `ghost`.
@MainActor
enum DebugScript {
    /// The chip of the card that has the keyboard and the popover it has open, as the cards report them.
    static var chip: String?
    static var popover: String?
    /// The attachment whose row has the keyboard, as its card reports it.
    static var file: String?
    /// How many times a card asked Quick Look for a file; a hidden app shows no panel.
    static var shows = 0
    /// Asks the card of the selected task to show the attachment with the number in `object`.
    static let showFile = Notification.Name("org.evsyukov.lists.debug.showFile")

    private static let codes: [String: (UInt16, String)] = [
        "return": (36, "\r"), "esc": (53, "\u{1b}"), "space": (49, " "), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
        "]": (30, "]"), "[": (33, "["), "tab": (48, "\t"), "backtab": (48, "\u{19}"),
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
                    // Points from the top left corner of the window the script types into.
                    let xy = argument.split(separator: ",").compactMap { Double($0) }
                    if xy.count == 2, let window = target {
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
                    let draft = AppModel.shared.draft
                    print("debug: draft files \(draft?.files.map(\.lastPathComponent) ?? []), start \(draft?.start ?? "none"), due \(draft?.due ?? "none")")
                    if let draft {
                        let model = AppModel.shared
                        print("debug: draft shows due \(model.shownDue(draft) ?? "none"), priority \(model.shownPriority(draft).title), tags \(draft.tags), list \(model.list(draft.listId).map(model.listName) ?? "none")")
                    }
                case "code":
                    // A press on the keyboard comes with the window a popover hangs on, not with the popover.
                    if let code = UInt16(argument) { post(code: code, to: popoverWindow.map { $0.parent ?? $0 } ?? dateEditor) }
                case "dateeditor":
                    if step.contains(":") {
                        dateEditor = editorWindow(value: argument.isEmpty ? nil : argument)
                    } else {
                        let window = popoverWindow ?? dateEditor
                        let pickers = datePickers(in: window?.contentView)
                        let day = pickers.first { $0.datePickerStyle == .clockAndCalendar }.map { Moment.string($0.dateValue, withTime: false) }
                        print("debug: date editor \(window == nil ? "closed" : "open"), first responder \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"), selected \(day ?? "none")")
                    }
                case "datefield":
                    let window = popoverWindow ?? dateEditor
                    let field = datePickers(in: window?.contentView).first { ($0.datePickerStyle == .clockAndCalendar) == (argument == "calendar") }
                    print("debug: \(argument) field \(field.map { window?.makeFirstResponder($0) ?? false }.map { $0 ? "has the keyboard" : "refused the keyboard" } ?? "missing")")
                case "files":
                    let files = AppModel.shared.selection.flatMap { try? AppModel.shared.store?.attachments(taskId: $0) } ?? []
                    for file in files {
                        let named = AttachmentFiles.named(file)
                        let thumbnail = file.localPath.flatMap { AttachmentFiles.thumbnail(path: $0, pixels: 56) }
                        let type = named.flatMap { try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier } ?? "-"
                        print("debug: file \(file.name) named=\(named?.lastPathComponent ?? "-") type=\(type) thumbnail=\(thumbnail.map { "\($0.width)x\($0.height)" } ?? "-") content=\(file.localPath == nil ? "waiting" : "here")")
                    }
                    print("debug: attachments waiting to sync \(AppModel.shared.syncStatus.attachmentsWaiting)")
                    print("debug: file row with the keyboard \(file ?? "none"), asked to show \(shows) times")
                case "attach":
                    if let id = AppModel.shared.selection { AppModel.shared.attach([URL(fileURLWithPath: argument)], to: id) }
                case "showfile": NotificationCenter.default.post(name: showFile, object: Int(argument) ?? 0)
                case "sync": AppModel.shared.syncNow()
                case "preview":
                    if step.contains(":") {
                        if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().close() }
                    } else {
                        let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
                        print("debug: preview \(panel?.isVisible == true ? "open" : "closed"), app \(NSApp.isHidden ? "hidden" : "shown") \(NSApp.isActive ? "active" : "inactive")")
                    }
                case "open":
                    if let id = AppModel.shared.selection { AppModel.shared.toggleExpanded(id) }
                case "edit":
                    if let id = AppModel.shared.selection { AppModel.shared.edit(id) }
                case "select": AppModel.shared.moveSelection(Int(argument) ?? 1)
                case "pick": AppModel.shared.selection = taskId(titled: argument)
                case "indent": AppModel.shared.selectedTask.map(AppModel.shared.indent)
                case "outdent": AppModel.shared.selectedTask.map(AppModel.shared.outdent)
                case "newtask": AppModel.shared.startDraft()
                case "title": AppModel.shared.draft?.title = argument
                case "finish": AppModel.shared.finishDraft()
                case "due":
                    AppModel.shared.draft?.due = argument.isEmpty ? nil : argument
                    AppModel.shared.draft?.dueRemoved = argument.isEmpty
                case "priority":
                    if let index = Int(argument), Priority.all.indices.contains(index) {
                        AppModel.shared.draft?.priority = Priority.all[index]
                        AppModel.shared.draft?.priorityChosen = true
                    }
                case "mklist":
                    AppModel.shared.perform { store in
                        let id = try store.createList(name: argument).id
                        try store.setListDefaults(id: id, priority: .high, dueToday: true)
                    }
                case "draftlist":
                    if let list = AppModel.shared.lists.first(where: { $0.name == argument || $0.id == argument }) { AppModel.shared.draft?.listId = list.id }
                case "start": AppModel.shared.draft?.start = argument.isEmpty ? nil : argument
                case "repeat":
                    if let index = Int(argument), Repeat.presets.indices.contains(index) { AppModel.shared.draft?.repeat = Repeat.presets[index].1 }
                case "done": AppModel.shared.selectedTask.map(AppModel.shared.toggleDone)
                case "wont": AppModel.shared.selectedTask.map(AppModel.shared.wontDo)
                case "task":
                    let task = AppModel.shared.selectedTask
                    print("debug: task \(task?.title ?? "none"), due \(task?.due ?? "none"), priority \(task?.priority.title ?? "none"), tags \(task?.tags ?? []), repeat \(task?.repeat?.summary ?? "none"), state \(task.map { $0.wont ? "wont do" : $0.done != nil ? "completed" : "open" } ?? "none")")
                case "inbox": AppModel.shared.scope = .inbox
                case "go":
                    let model = AppModel.shared
                    switch argument {
                    case "wontdo": model.scope = .wontDo
                    case "completed": model.scope = .completed
                    case "today": model.scope = .today
                    case _ where argument.hasPrefix("#"): model.scope = .tag(name: String(argument.dropFirst()))
                    default: model.scope = model.lists.first { $0.name == argument }.map { .list(id: $0.id) } ?? .inbox
                    }
                case "completedview": AppModel.shared.showCompletedView = argument != "off"
                case "calendarevents":
                    let model = AppModel.shared
                    print("debug: calendar events \(model.showCalendarEvents ? "on" : "off"), access \(SystemCalendars.shared.access), calendars \(model.eventCalendars.count), hidden \(model.hiddenCalendars.count)")
                case "events":
                    let model = AppModel.shared
                    if !argument.isEmpty {
                        let dayStart = Calendar.current.startOfDay(for: Date())
                        let raw = argument.split(separator: ",").enumerated().map { index, item in
                            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                            let clock = parts[0].split(separator: ":").compactMap { Int($0) }
                            let start = parts[0] == "y" ? dayStart.addingTimeInterval(-7200)
                                : dayStart.addingTimeInterval(TimeInterval((clock.first ?? 0) * 3600 + (clock.count > 1 ? clock[1] : 0) * 60))
                            return RawEvent(id: "\(index)", title: parts.count > 1 ? parts[1] : "", start: start, allDay: parts[0] == "-", color: .blue)
                        }
                        model.dayEvents = DayEvents.arrange(raw, dayStart: dayStart)
                    }
                    let lines = model.dayEvents.map { [$0.time, $0.title].compactMap { $0 }.joined(separator: " ") }
                    print("debug: events \(model.eventsShown ? "shown" : "not shown") \(lines)")
                case "keepdone":
                    if argument == "day" { AppModel.shared.setKeepDone(.endOfDay) }
                    else if let seconds = UInt32(argument) { AppModel.shared.setKeepDone(.seconds(seconds: seconds)) }
                    switch AppModel.shared.keepDone {
                    case .endOfDay: print("debug: keep done day")
                    case .seconds(let seconds): print("debug: keep done \(seconds)")
                    }
                case "sound":
                    if step.contains(":") { AppModel.shared.notifySoundName = argument }
                    let chosen = AppModel.shared.notifySoundName
                    let sound = NotifySound.notification(chosen)
                    let copy = NotifySound.copy(of: chosen).map { FileManager.default.fileExists(atPath: $0.path) ? $0.path : "none" } ?? "no group"
                    print("debug: sound \(chosen.isEmpty ? "standard" : chosen), on \(AppModel.shared.notifySound), plays \(AppModel.shared.notifySoundChoice ?? "nothing"), standard \(sound == .default), copy \(copy), offered \(NotifySound.names)")
                case "appearance":
                    if step.contains(":") {
                        AppModel.shared.appearance = argument
                    } else {
                        let looks = (NSApp.windows + [QuickEntryPanel.shared]).reduce(into: [String: String]()) {
                            $0[String(describing: type(of: $1))] = $1.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
                        }
                        print("debug: appearance \(AppModel.shared.appearance), windows \(looks.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" })")
                    }
                case "ghost":
                    ghost = true
                    for window in NSApp.windows where !(window is NSPanel) && window.styleMask.contains(.titled) { hide(window) }
                    for name in [NSPopover.willShowNotification, NSPopover.didShowNotification] {
                        NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                            MainActor.assumeIsolated {
                                let popover = note.object as? NSPopover
                                popover?.animates = false
                                popover?.contentViewController?.view.window.map(hide)
                            }
                        }
                    }
                    NSApp.unhideWithoutActivation()
                    try? await _Concurrency.Task.sleep(for: .milliseconds(300))
                case "chips": print("debug: chip \(chip ?? "none"), popover \(popover ?? "none")")
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
                    print("debug: key window \(window.map { type(of: $0) }.map(String.init(describing:)) ?? "none"), first responder \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")\((window?.firstResponder as? NSText).map { " with \"\($0.string)\"" } ?? "")\(((window?.firstResponder as? NSTextView)?.delegate as? NSTextField).map { ", field \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "")")
                case "rowshot":
                    // The row of the selected task drawn into a file, eight pixels to a point.
                    if let task = AppModel.shared.selectedTask {
                        let row = TaskRow(task: task, depth: 0).environment(AppModel.shared)
                            .frame(width: 320).background(Color.white).environment(\.colorScheme, .light)
                        let renderer = ImageRenderer(content: row)
                        renderer.scale = 8
                        if let image = renderer.cgImage {
                            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
                            print("debug: row drawn, \(image.width)x\(image.height) pixels, text scale \(AppModel.shared.textScale), design \(AppModel.shared.fontDesign)")
                        }
                    }
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
                case "noteclick": print("debug: noteclick \(argument) \(notesView(in: target?.contentView)?.debugClickText(Int(argument) ?? 0) ?? "no note")")
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
                // in the background takes them directly, shortcuts as key equivalents.
                if window.isKeyWindow {
                    NSApp.sendEvent(event)
                } else if type != .keyDown || !flags.contains(.command) || !window.performKeyEquivalent(with: event) {
                    window.sendEvent(event)
                }
            }
        }
    }

    /// The window the script types into: the key window, or the main window of
    /// an app that was left in the background.
    static var target: NSWindow? { NSApp.keyWindow ?? (ghost ? popoverWindow : nil) ?? backgroundWindow }

    /// True after `ghost`: the windows are on screen, unseen.
    private static var ghost = false

    private static func hide(_ window: NSWindow) {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }

    /// The window of the popover that is open, if one is.
    private static var popoverWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
    }

    /// The date editor that `dateeditor` built off screen.
    private static var dateEditor: NSWindow?

    private static func editorWindow(value: String?) -> NSWindow {
        let editor = DateEditor(title: "debug", value: value) { print("debug: date applied \($0 ?? "none")") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: editor)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private static func datePickers(in view: NSView?) -> [NSDatePicker] {
        guard let view else { return [] }
        return ((view as? NSDatePicker).map { [$0] } ?? []) + view.subviews.flatMap(datePickers(in:))
    }

    /// A key press told by its key code alone, put in the queue the way the keyboard
    /// does, so that event monitors see it.
    private static func post(code: UInt16, to window: NSWindow?) {
        guard let window else { return print("debug: no date editor for key code \(code)") }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// The main window of an app that a quiet script left hidden. `canBecomeMain`
    /// is false for it, so it is told by its look.
    static var backgroundWindow: NSWindow? {
        guard ProcessInfo.processInfo.environment["LISTS_DEBUG_QUIET"] != nil else { return nil }
        return NSApp.windows.first { !($0 is NSPanel) && $0.styleMask.contains(.resizable) }
    }
}
#endif
