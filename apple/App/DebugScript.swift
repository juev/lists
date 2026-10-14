#if DEBUG
import AppKit
import Quartz
import SwiftUI
import UserNotifications

/// Drives the app from inside for checks that need key presses: macOS lets no
/// outside process send them without the Accessibility permission. Debug
/// builds only. `LISTS_DEBUG_SCRIPT` holds steps separated by `;`:
/// `type:text`, `key:return`, `key:n+cmd`, `sleep:0.5`, `click:x,y` (`click:x,y,2` for a double click), `quick`, `settings`,
/// `state` (prints who has the keyboard, whether that is the sidebar, the text being typed into and the size of its field), `copyfiles:path,path` and `copyimage`
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
/// `sync` (starts a sync the way the toolbar icon does), `attach:/path` (attaches the file to the selected task), `filepointer` (prints the size of the layer the pointer works on over the first file of the open card, the items of its right-click menu and the file a drag would carry; `filepointer:click` also clicks it), `savefile:/path` (saves the first attachment of the selected task there, the way "Save As…" does once a place is chosen), `saveall:/folder` (saves every attachment of the selected task there, the way "Save All…" does once a folder is chosen, and prints what was saved), `showfile:0` (shows the attachment with that number the way a click on its name does;
/// a hidden app shows no panel), `preview` (prints whether the Quick Look panel is open) and `preview:close` (closes it),
/// `inbox` (switches to the Inbox view), `open` (expands the selected task), `edit` (opens it with the caret in the title, the way Return does), `select:1` and `select:-1` (move the selection the way the arrow keys do),
/// `pick:title` (selects a row the way a click does),
/// `addsub:title` (adds a subtask to the selected task the way its field does on Return), `subtasks` (prints the lines of the selected task, or of the task
/// the selected subtask belongs to: the title and the state of each, which of them is a subtask without a card, the one whose title is being edited,
/// and the lines a search shows under its rows), `renamesub:old=new` (renames the subtask in its line: starts the edit the way Return on the selected
/// subtask does, puts the text in and ends it the way Return in the field does; `renamesub:old` only starts the edit, and `renamesub:old=new=esc` ends it the way Esc does),
/// `submenu:title` (prints the items of the menu of that subtask, the ones a right click on it builds its menu from; `submenu:title=Item` also chooses the item),
/// `find:text` (searches the way typing in the search field does, `find:` ends the search),
/// `newtask` (opens the card of a new task), `title:text` (fills its title), `finish` (closes it the way Return does: a card with a title becomes a task),
/// `draftsub:title` (adds a subtask to the new-task card the way its icon of subtasks, typing and Return in the field do, R113), `draftsubfield:text` (leaves the text in
/// that field without adding it), `draftsubedit:0=title` (corrects the typed line with that number) and `draftsubdrop:0` (removes it the way its button does); `draft` also prints the typed subtasks and the field,
/// `due:2026-10-05` and `repeat:2` (give the new-task card a due date and the preset with that index, the way its popovers do),
/// `due` alone (takes the due date away the way ⌫ in its popover does), `priority:3` (chooses the priority with that index in the card, 0 for none),
/// `mklist:Name` (creates a list whose defaults for new tasks are the high priority and "due today"), `draftlist:Name` (chooses that list in the card, `draftlist:inbox` the Inbox), `start:2026-10-05` (gives the card a start date); `draft` also prints the due date, the priority, the tags and the list the card shows,
/// `task` (prints the due date, the priority, the tags and the repeat of the selected task), `done` (completes it), `project` (makes it a project, or a task again, the way its menu does),
/// `cards` (prints the open cards and the selected row), `rows` (prints the rows in the order they are drawn), `panel` (prints whether quick entry is on screen and what runs modally),
/// `windows` (prints the windows of the app),
/// `notes` (prints the note of the open card as it is drawn: what is hidden, what is replaced and which fonts differ),
/// `shot:/path/to.png` (draws that note into a file, on screen or not),
/// `settingstab:sync` (chooses the tab of the settings window: `general`, `tasks`, `notifications`, `sync`, `backups`), `settingsshot:/path/to.png` (draws the settings into a file from a window that is never shown),
/// `winshot:/path/to.png` (draws the main window into a file, on screen or not; a hidden window draws no rows, those of the sidebar among them),
/// `viewicons:/path/to.png` (draws the icons of the built-in views into a file in the light and the dark look and prints the symbol of each),
/// `rowshot:/path/to.png` (draws the row of the selected task into a file, eight pixels to a point: a hidden window draws no rows;
/// the launch arguments `-textScale 1.5 -fontDesign serif` choose the text for one run and save nothing),
/// `caret:5` (puts the cursor of that note at the offset), `box:0` (clicks the checkbox with that number in it),
/// `noteclick:5` (clicks the character of that note at the offset and prints the address a link there hands to the system; the browser is not opened),
/// `chips` (prints which chip of the card has the keyboard and which of its popovers is open; `key:backtab+shift` is ⇧Tab),
/// `ghost` (puts the windows of a hidden app on screen transparent, deaf to the mouse and without the keyboard, popovers that open later among them:
/// a hidden app shows no popovers; key presses then go to the open popover first, as they do when it has the keyboard),
/// `wont` (closes the selected task as "won't do"; `task` prints the state of the selected task), `go:completed`, `go:wontdo`, `go:today`, `go:all`, `go:trash`, `go:#tag`, `go:List name` and `go:Project title` (switch to those views),
/// `hideinbox:List name=move` (hides Inbox the way the dialog of R121 does, `=keep` without moving, `hideinbox:show` shows it; alone it prints the setting and the default list),
/// `completedview:on` and `completedview:off` (show the Completed and Won't do views always or never), `sidebarshow:wontDo=filled` (sets when a built-in view has a row in the sidebar: `always`, `filled` or `never`; `sidebarshow` alone prints the built-in rows there are), `scope` (prints the current view), `quit` (quits the app the way ⌘Q does), `search` (prints whether search is open as a field and its text),
/// `calendarevents` (prints the setting of R78, the access the system gave, and how many calendars are listed and hidden; nothing is asked of the system),
/// `events:14:30=Bank,-=Birthday,09:00=Standup,y=Trip` (puts those events through the order of the block in place of the calendars of the system:
/// `-` is an all-day event, `y` one that began yesterday) and `events` alone print whether the block is on show and its lines,
/// `keepdone:5` (sets for how many seconds a completed task stays in view), `keepdone:day` (until the end of the day) and `keepdone` alone (prints it),
/// `sound:Glass` (chooses the sound of notifications without playing it, `sound:` the standard one; `sound` alone leaves the choice as it is) prints the choice,
/// whether a notification gets the standard sound, where the copy for the notification centre is and the sounds on offer; no notification is scheduled,
/// `leads` (prints what each stored choice of "task due at a time" means, R36, and the choice of this Mac),
/// `origins` (prints what each row of the view says about the list and the project of its task and the colour of the list, R72),
/// `notifications` (prints whether the system allows notifications for the app, the requests it holds and whether Settings show the line about a refusal, R111; nothing is asked and nothing is scheduled;
/// with `LISTS_DEBUG_DIR` it also prints the plan of the run, which is not handed to the system: the requests the system holds are those of the installed copy;
/// `notifications:ask` also repeats the request for the permission and prints the answer, unless the app was never asked: that would open the dialog;
/// `notifications:denied` and `notifications:allowed` give the model that answer without asking the system and print whether Settings show the line),
/// `dock` (prints the settings of R116, the activation policy of the app, whether its item is in the menu bar and whether a start at login would be hidden;
/// `dock:item=off`, `dock:hidden=on` and `dock:window=off` choose first, the way Settings do; with `LISTS_DEBUG_AT_LOGIN` set the app takes its start for one made by the system at login),
/// `appearance:dark`, `appearance:light` and `appearance:system` (choose the look the way Settings does),
/// `appearance` alone prints the choice and the look each window of the app has, the quick-entry panel among them,
/// `dockcount:today`, `dockcount:overdue` and `dockcount:none` (choose what the Dock icon counts the way Settings does, R103),
/// `dockcount` alone prints the choice, the label the Dock tile carries and the counts it is taken from,
/// `menu:Title` (prints whether the menu bar item with that title is enabled),
/// `rowmenu:300,140` (prints the items of the menu a right click at that point of the window would open, without opening it;
/// `rowmenu:300,140=Title` also chooses the item with that title; asking the list for the menu of a row leaves its highlight over the row,
/// and a later `rowmenu` in the same run finds the highlight under the pointer in place of the row, so a subtask is asked first), `undo` (prints what ⌘Z would take back and takes it back),
/// `sidebar` (prints how many rows each list of the main window has, the sidebar among them),
/// `copytext:text`, `copysecret:text` and `copyfile:path` (fill the pasteboard quick entry reads; with `LISTS_DEBUG_PASTEBOARD=name` that is a pasteboard of its own, not the general one),
/// `clipnotes:on` and `clipnotes:off` (flip the setting of R58), `quicknote` (shows quick entry transparent and without the keyboard, and prints the note it starts with; `quicknote:/path.png` also draws the card into a file),
/// `veil` (makes the windows of the app transparent and deaf to the mouse and leaves the app hidden) and
/// `hideapp` (hides the app the way Hide Lists does), `unhideapp` (shows it again without making it active),
/// `quickopen` and `quickclose` (show quick entry transparent and without the keyboard, and close it; while it is open that way, `type` and `key` go to its card),
/// `apphidden` (prints whether the app is hidden, whether it is active and how many of its main windows are ordered in),
/// `quicktrace` (shows quick entry transparent and without the keyboard, and prints its geometry frame by frame:
/// a line that differs from the next one is a card that moved after it was shown).
/// `undostate` (prints whether a group of changes is open in the undo manager; `undo` after several scripted presses takes all of them back at once,
/// which a person at the keyboard does not get: `scripts/postkey.swift` sends presses each of which is undone on its own, #230).
/// With `LISTS_DEBUG_DIR=/folder` the run has its data in that folder, and its settings as well, in `settings.plist`: it starts with the defaults
/// and leaves the settings and the notifications of the installed copy alone. The key of quick entry is still the one of the installed copy.
/// A setting the installed copy holds is read in place of the one the check wrote (seen with `lastUsedList`, #255): what was written is
/// in `settings.plist`, read it with `defaults read`.
/// `keychain:…` (the secrets of sync in the keychain, #241: `former=account=secret`, `save=account=secret`, `load=account`, `delete=account`, `forget`, `wipe=account,account`;
/// prints the answer and how many items of the keychain were opened since `forget`; with `LISTS_DEBUG_DIR` the items are those of the check, not of the installed copy).
/// With `LISTS_DEBUG_LAUNCH_PROBE` set the launch carries a probe that stops the app when the event loop is run while the model is built,
/// and prints a line when it is not; `scripts/check-launch.sh` is the check that uses it.
/// With `LISTS_DEBUG_HOLD_START=10` the launch is held for that many seconds right after the helper is restarted (R115): the stand-in for a launch
/// that waits for an answer about the keychain.
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
        "tab": (48, "\t"), "backtab": (48, "\u{19}"),
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
                    // `click:x,y,2` is a double click: a press and a release, and the same again as the second of a pair.
                    let xy = argument.split(separator: ",").compactMap { Double($0) }
                    if xy.count >= 2, let window = target {
                        let point = NSPoint(x: xy[0], y: Double(window.frame.height) - xy[1])
                        for count in 1...max(1, xy.count > 2 ? Int(xy[2]) : 1) {
                            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                if let event = NSEvent.mouseEvent(
                                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
                                    // Queued, not sent: a view that tracks the mouse waits for the release in the queue.
                                    NSApp.postEvent(event, atStart: false)
                                }
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
                        print("debug: draft subtasks \(draft.subtasks), field \"\(draft.subtaskText)\", \(draft.subtasksShown ? "shown" : "not shown"), saves \(draft.typedSubtasks)")
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
                case "filepointer":
                    // The layer over a file of the open card: what its right click offers and what a drag would carry.
                    func find(_ view: NSView?) -> FilePointerView? {
                        guard let view else { return nil }
                        if let found = view as? FilePointerView { return found }
                        for sub in view.subviews { if let found = find(sub) { return found } }
                        return nil
                    }
                    if let pointer = find(target?.contentView) {
                        print("debug: file pointer \(Int(pointer.frame.width))x\(Int(pointer.frame.height)), menu \(pointer.fileMenu().items.map(\.title)), drags \(pointer.url()?.lastPathComponent ?? "nothing")")
                        if argument == "click" { pointer.clicked() }
                    } else {
                        print("debug: file pointer none")
                    }
                case "savefile":
                    // Saves the first attachment of the selected task the way "Save As…" does once a place is chosen.
                    if let task = AppModel.shared.selectedTask, let file = (try? AppModel.shared.store?.attachments(taskId: task.id))?.first {
                        let result = Result { try AttachmentFiles.save(file, to: URL(fileURLWithPath: argument)) }
                        print("debug: saved \(file.name) to \(argument): \(result)")
                    }
                case "saveall":
                    // Saves every attachment of the selected task the way "Save All…" does once a folder is chosen.
                    if let id = AppModel.shared.selection { AppModel.shared.saveAttachments(of: id, into: URL(fileURLWithPath: argument)) }
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
                // R117: `pickmore:title` is a click with ⌘, `pickto:title` one with Shift, `extend:1` Shift with an arrow,
                // `selectall` is ⌘A, `unpick` Esc; `picked` prints the selected rows in the order of the view.
                case "pickmore": taskId(titled: argument).map { AppModel.shared.click($0, command: true) }
                case "pickto": taskId(titled: argument).map { AppModel.shared.click($0, shift: true) }
                case "extend": AppModel.shared.extendSelection(Int(argument) ?? 1)
                case "selectall": AppModel.shared.selectAll()
                case "unpick": print("debug: unpick \(AppModel.shared.clearPicked())")
                case "picked":
                    let model = AppModel.shared
                    print("debug: picked \(model.selectedTasks.map(\.title)), several \(!model.picked.isEmpty), lead \(model.selectedTask?.title ?? "none")")
                case "batch":
                    // R117: `batch:complete`, `wont`, `delete`, `restore`, `due=2026-10-20`, `start=…`, `priority=high`, `move=List name`, `tag=name`.
                    let model = AppModel.shared
                    let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
                    let value = parts.count > 1 ? parts[1] : ""
                    let action: BatchAction? = switch parts.first ?? "" {
                    case "complete": .complete
                    case "wont": .wontDo
                    case "delete": .delete
                    case "restore": .restore
                    case "due": .due(value)
                    case "start": .start(value)
                    case "priority": .priority(value == "high" ? .high : value == "medium" ? .medium : value == "low" ? .low : .none)
                    case "move": (value == "inbox" ? "inbox" : model.lists.first { $0.name == value }?.id).map { .move(listId: $0) }
                    case "tag": .tag(AppModel.cleanTag(value))
                    default: nil
                    }
                    print("debug: batch \(argument) changed \(action.map { model.batch($0) } ?? -1)")
                case "batchmenu":
                    // The menu a right click on the selected row builds while several rows are selected.
                    let model = AppModel.shared
                    let items = model.selectedTask.flatMap { TaskRow.batchItems(for: $0, model) }
                    print("debug: batch menu \(items.map { $0.filter { !$0.isDivider }.map { item in item.children.map { "\(item.title) ▸ \($0.count)" } ?? item.title } }.map(String.init(describing:)) ?? "none")")
                case "addsub":
                    let model = AppModel.shared
                    if let id = model.selection {
                        model.showSubtasks(id)
                        model.add(argument, parent: id)
                    }
                case "subtasks":
                    let model = AppModel.shared
                    let selected = model.selectedTask
                    let parent = selected.flatMap { model.isSubtask($0) ? $0.parentId : $0.id }
                    let lines = (parent.flatMap { model.children[$0] } ?? []).map { line in
                        "\(line.title) [\(line.wont ? "wont do" : line.done != nil ? "completed" : "open")\(model.isSubtask(line) ? ", line" : ", task")]"
                    }
                    let found = model.found.map { "\(taskTitle($0.key)): \($0.value.map(\.title))" }.sorted()
                    print("debug: subtasks of \(parent.map(taskTitle) ?? "none") \(lines), renaming \(model.renaming.map(taskTitle) ?? "none"), found \(found)")
                case "renamesub":
                    let parts = argument.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
                    let model = AppModel.shared
                    if let task = shown.first(where: { $0.title == parts[0] }) {
                        // The same calls as Return on the selected subtask, typing, and Return or Esc in its field.
                        model.toggleEditing(task.id)
                        if parts.count > 1 {
                            model.renamingTitle = parts[1]
                            model.finishRenaming(task.id, save: parts.count < 3)
                        }
                    } else {
                        print("debug: no subtask \(parts[0])")
                    }
                case "submenu":
                    let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
                    if let task = shown.first(where: { $0.title == parts.first }), AppModel.shared.isSubtask(task) {
                        let items = SubtaskRow.menuItems(task, AppModel.shared)
                        print("debug: subtask menu \(items.map(\.title))")
                        if parts.count == 2 { items.first { $0.title == parts[1] }?.action() }
                    } else {
                        print("debug: no subtask \(parts.first ?? "")")
                    }
                case "find": AppModel.shared.search = argument
                case "newtask": AppModel.shared.startDraft()
                case "title": AppModel.shared.draft?.title = argument
                case "finish": AppModel.shared.finishDraft()
                case "draftsub", "draftsubfield":
                    // The same calls as a click on the icon of subtasks, typing, and Return in the field (R113).
                    AppModel.shared.draft?.subtasksShown = true
                    AppModel.shared.draft?.subtaskText = argument
                    if name == "draftsub" { AppModel.shared.draft?.addSubtask() }
                case "draftsubedit":
                    let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    if let index = Int(parts[0]), AppModel.shared.draft?.subtasks.indices.contains(index) == true {
                        AppModel.shared.draft?.subtasks[index] = parts.count > 1 ? parts[1] : ""
                    }
                case "draftsubdrop":
                    if let index = Int(argument), AppModel.shared.draft?.subtasks.indices.contains(index) == true {
                        AppModel.shared.draft?.subtasks.remove(at: index)
                    }
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
                case "project":
                    // What "Make project" of the menu of the selected task does.
                    if let task = AppModel.shared.selectedTask { AppModel.shared.perform { try $0.setProject(id: task.id, project: !task.isProject) } }
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
                    case "all": model.scope = .all
                    case "trash": model.scope = .trash
                    case _ where argument.hasPrefix("#"): model.scope = .tag(name: String(argument.dropFirst()))
                    default:
                        model.scope = model.lists.first { $0.name == argument }.map { .list(id: $0.id) }
                            ?? model.projects.first { $0.title == argument }.map { .project(id: $0.id) } ?? .inbox
                    }
                case "completedview":
                    for scope in [Scope.completed, .wontDo] { AppModel.shared.setSidebarShow(scope, argument != "off" ? .always : .never) }
                case "sidebarshow":
                    // `sidebarshow:wontDo=filled` sets when a built-in view has a row; alone it prints the rows there are.
                    let parts = argument.split(separator: "=").map(String.init)
                    if parts.count == 2, let scope = Scope.builtins.first(where: { $0.builtinName == parts[0] }), let show = SidebarShow(rawValue: parts[1]) {
                        AppModel.shared.setSidebarShow(scope, show)
                    } else {
                        print("debug: sidebar shows \(AppModel.shared.shownBuiltins.compactMap(\.builtinName))")
                    }
                case "hideinbox":
                    // `hideinbox:List name=move` hides Inbox the way the dialog of R121 does (`=keep` without moving);
                    // `hideinbox:show` shows it again; alone it prints the setting, the default lists and the Inbox counter.
                    let model = AppModel.shared
                    let parts = argument.split(separator: "=").map(String.init)
                    if argument == "show" { model.showInbox() }
                    else if parts.count == 2, let list = model.listsForHiddenInbox.first(where: { $0.name == parts[0] }) {
                        model.hideInbox(movingTo: list.id, moveTasks: parts[1] == "move")
                    }
                    let name = { (id: String) in model.lists.first { $0.id == id }.map { $0.id == "inbox" ? "Inbox" : $0.name } ?? id }
                    print("debug: inbox \(model.inboxHidden ? "hidden" : "shown"), open \(model.counts.inbox), new tasks \(model.newTaskList == "last" || model.newTaskList == "inbox" ? model.newTaskList : name(model.newTaskList)), default \(name(model.defaultListId))")
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
                case "leads":
                    // R36: what the stored choice of "task due at a time" means, case by case, and the choice of this Mac.
                    let cases: [(String, [Int]?, Int?, Bool)] = [
                        ("nothing stored", nil, nil, false), ("15 before the update", [15], nil, false), ("single 15 before the update", nil, 15, false),
                        ("15 after the update", [15], nil, true), ("15 and 60", [15, 60], nil, false), ("off", [], nil, false), ("single off", nil, -1, false),
                    ]
                    let lines = cases.map { "\($0.0) \(AppModel.leads(stored: $0.1, legacy: $0.2, moved: $0.3).sorted())" }
                    print("debug: leads \(lines.joined(separator: "; ")); this Mac \(AppModel.shared.notifyLeads.sorted())")
                case "notifications" where argument == "denied" || argument == "allowed":
                    // R111: gives the model the answer of the system without asking the system, and prints what Settings show for it.
                    AppModel.shared.noteNotificationAccess(argument == "denied" ? .denied : .granted, refusal: argument == "denied" ? "debug" : nil)
                    print("debug: notifications taken as \(argument), line in settings \(AppModel.shared.notificationAccess == .denied ? "shown" : "not shown")")
                case "notifications":
                    // What the system holds for the app: nothing is asked of the person and nothing is scheduled.
                    let center = UNUserNotificationCenter.current()
                    let status = await center.notificationSettings().authorizationStatus
                    let names: [UNAuthorizationStatus: String] = [.notDetermined: "not asked", .denied: "denied", .authorized: "allowed", .provisional: "provisional"]
                    let pending = await center.pendingNotificationRequests().map { request in
                        "\(request.identifier) \((request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate().map(String.init(describing:)) ?? "no date")"
                    }
                    print("debug: notifications \(names[status] ?? "status \(status.rawValue)"), pending \(pending)")
                    // With `LISTS_DEBUG_DIR` the plan stays in the app, and the requests above are those of the installed copy.
                    if Storage.debugDirectory != nil { print("debug: notifications planned and not handed over \(Reminders.shared.withheld)") }
                    // R111: the line of Settings follows the same answer.
                    print("debug: notifications line in settings \(AppModel.shared.notificationAccess == .denied ? "shown" : "not shown")")
                    // `notifications:ask` repeats the request the app makes. Only where the answer is already
                    // there: an app that was never asked would put the dialog of the system on screen.
                    if argument == "ask", status != .notDetermined {
                        do {
                            print("debug: notifications asked, granted \(try await center.requestAuthorization(options: [.alert, .sound]))")
                        } catch {
                            print("debug: notifications asked, error \((error as NSError).domain) \((error as NSError).code): \(error.localizedDescription)")
                        }
                    }
                case "appearance":
                    if step.contains(":") {
                        AppModel.shared.appearance = argument
                    } else {
                        let looks = (NSApp.windows + [QuickEntryPanel.shared]).reduce(into: [String: String]()) {
                            $0[String(describing: type(of: $1))] = $1.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
                        }
                        print("debug: appearance \(AppModel.shared.appearance), windows \(looks.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" })")
                    }
                case "dock":
                    // R116: `dock:item=off`, `dock:hidden=on` and `dock:window=off` choose the way Settings do; then what holds.
                    let parts = argument.split(separator: "=").map(String.init)
                    if parts.count == 2 {
                        switch parts[0] {
                        case "item": AppModel.shared.menuBarItem = parts[1] == "on"
                        case "hidden": AppModel.shared.hiddenFromDock = parts[1] == "on"
                        case "window": AppModel.shared.windowAtLogin = parts[1] == "on"
                        default: break
                        }
                        try? await _Concurrency.Task.sleep(for: .milliseconds(500))
                    }
                    let model = AppModel.shared
                    let policy = NSApp.activationPolicy() == .regular ? "regular" : NSApp.activationPolicy() == .accessory ? "accessory" : "prohibited"
                    let bars = NSApp.windows.filter { String(describing: type(of: $0)) == "NSStatusBarWindow" }
                    let item = bars.map { "\($0.isVisible ? "visible" : "hidden") \(Int($0.frame.width))x\(Int($0.frame.height))" }
                    print("debug: dock item \(model.menuBarItem), hidden asked \(model.hiddenFromDock), out of dock \(model.outOfDock), policy \(policy), item in the menu bar \(item), window at login \(model.windowAtLogin), starts hidden \(AppDelegate.startsHidden(atLogin: AppDelegate.launchedAtLogin, windowAtLogin: model.windowAtLogin)), main menu \(NSApp.mainMenu?.items.count ?? 0) items")
                case "dockcount":
                    if step.contains(":") { AppModel.shared.dockCount = argument }
                    let model = AppModel.shared
                    print("debug: dock count \(model.dockCount), badge \(NSApp.dockTile.badgeLabel ?? "none"), today \(model.counts.today), overdue \(model.counts.overdue)")
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
                case "quit": NSApp.terminate(nil)
                case "scope": print("debug: scope \(AppModel.shared.scopeTitle), completed view \(AppModel.shared.showsInSidebar(.completed) ? "on" : "off")")
                case "search": print("debug: search field \(AppModel.shared.searchOpen || AppModel.shared.isSearching ? "open" : "closed"), text \"\(AppModel.shared.search)\"")
                case "menu":
                    let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
                    let item = items.first { $0.title == argument }
                    print("debug: menu \(argument) \(item.map { $0.isEnabled ? "enabled" : "disabled" } ?? "missing")")
                case "rowmenu":
                    // The menu a right click at the point would open, asked of the views without opening it.
                    let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
                    let xy = (parts.first ?? "").split(separator: ",").compactMap { Double($0) }
                    if xy.count == 2, let window = target, let root = window.contentView?.superview ?? window.contentView,
                       let event = NSEvent.mouseEvent(
                        with: .rightMouseDown, location: NSPoint(x: xy[0], y: Double(window.frame.height) - xy[1]), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1) {
                        // A subtask inside the row of its parent answers first, as it does to the click.
                        var menu = SubtaskMenuView.area(at: event.locationInWindow, in: window)?.subtaskMenu()
                        var view = root.hitTest(event.locationInWindow)
                        while let current = view, menu == nil {
                            menu = current.menu(for: event)
                            view = current.superview
                        }
                        menu?.update()
                        print("debug: row menu \(menu?.items.map(\.title) ?? [])")
                        if parts.count == 2, let menu, let index = menu.items.firstIndex(where: { $0.title == parts[1] }) {
                            menu.performActionForItem(at: index)
                        }
                    } else {
                        print("debug: row menu none")
                    }
                case "keychain":
                    // #241: `keychain:former=account=secret` keeps a secret the former way, in an item of its own; `save=account=secret`,
                    // `load=account` and `delete=account` are what the app does; `forget` is what a new run starts with;
                    // `wipe=account,account` removes the items of the check. Then how many items were opened since `forget`.
                    let parts = argument.split(separator: "=", maxSplits: 2).map(String.init)
                    let (account, secret) = (parts.count > 1 ? parts[1] : "", parts.count > 2 ? parts[2] : "")
                    var said = ""
                    switch parts.first ?? "" {
                    case "former": said = (try? Keychain.saveFormer(secret, account: account)) == nil ? "refused" : "kept"
                    case "save": said = (try? Keychain.save(secret, account: account)) == nil ? "refused" : "saved"
                    case "load": said = Keychain.load(account: account) ?? "none"
                    case "delete": Keychain.delete(account: account); said = "deleted"
                    case "forget": Keychain.forget(); said = "forgotten"
                    case "wipe": Keychain.wipe(formerAccounts: account.split(separator: ",").map(String.init)); said = "wiped"
                    default: break
                    }
                    print("debug: keychain \(argument) \(said), items opened \(Keychain.opened)")
                case "undostate":
                    // Whether a group of changes is still open. A press of the script is handed to the app directly, and the
                    // undo manager closes a group only after an event taken from the queue: the changes of several scripted
                    // presses fall into one group and are undone together. Presses of `scripts/postkey.swift` come through
                    // the queue, and each is a group of its own, as with a keyboard (#230).
                    let manager = AppModel.shared.undoManager
                    print("debug: undo state level \(manager?.groupingLevel ?? -1), by event \(manager?.groupsByEvent == true), can undo \(manager?.canUndo == true), run loop modes \(manager?.runLoopModes.map(\.rawValue) ?? []), same as the window's \(manager === NSApp.mainWindow?.undoManager)")
                case "undo":
                    // What ⌘Z does: a hidden window has no keyboard to take the press.
                    let manager = AppModel.shared.undoManager
                    print("debug: undo \(manager?.canUndo == true ? manager?.undoActionName ?? "" : "nothing")")
                    manager?.undo()
                case "sidebar": print("debug: sidebar rows \(tableRows(in: target?.contentView?.superview))")
                case "cards":
                    let model = AppModel.shared
                    let open = model.expanded.map(taskTitle).sorted()
                    print("debug: open \(open), selected \(model.selection.map(taskTitle) ?? "none"), draft \(model.draft != nil)")
                case "rows": print("debug: rows \(AppModel.shared.visibleIds.map(taskTitle))")
                case "origins":
                    // R72: what each row of the view says about its list and its project, and in which colour.
                    let model = AppModel.shared
                    let rows = model.sections.flatMap(\.tasks).map { task in
                        "\(task.title): \((model.mixesLists ? model.origin(of: task) : nil).map { "\($0.label) [\($0.color ?? "no colour")]" } ?? "nothing")"
                    }
                    print("debug: origins \(rows)")
                case "panel":
                    print("debug: quick entry \(QuickEntryPanel.shared.isVisible ? "shown" : "hidden"), modal \(NSApp.modalWindow.map { String(describing: type(of: $0)) } ?? "none")")
                case "quick": QuickEntryPanel.shared.present()
                case "veil":
                    // Unlike `ghost`, the app stays hidden: its windows are only made transparent, for the case they come on screen.
                    for window in NSApp.windows where !(window is NSPanel) { hide(window) }
                case "quickopen":
                    // Shown transparent and without the keyboard, and left open until `quickclose`.
                    QuickEntryPanel.debugSilent = true
                    QuickEntryPanel.shared.alphaValue = 0
                    QuickEntryPanel.shared.present()
                    try? await _Concurrency.Task.sleep(for: .milliseconds(300))
                case "quickclose":
                    QuickEntryPanel.shared.close()
                    QuickEntryPanel.shared.alphaValue = 1
                    QuickEntryPanel.debugSilent = false
                    try? await _Concurrency.Task.sleep(for: .milliseconds(300))
                case "unhideapp":
                    NSApp.unhideWithoutActivation()
                    try? await _Concurrency.Task.sleep(for: .milliseconds(300))
                case "hideapp":
                    // What Hide Lists (⌘H) does.
                    NSApp.hide(nil)
                    try? await _Concurrency.Task.sleep(for: .milliseconds(300))
                case "apphidden":
                    let shown = NSApp.windows.filter { !($0 is NSPanel) && $0.canBecomeMain && $0.isVisible }.count
                    print("debug: app \(NSApp.isHidden ? "hidden" : "shown"), active \(NSApp.isActive), main windows in the window list \(shown), quick entry \(QuickEntryPanel.shared.isVisible ? "shown" : "hidden")")
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
                case "loginitems":
                    // R115: what the system holds; `loginitems:helper=on` and the like change it first.
                    let parts = argument.split(separator: "=").map(String.init)
                    if parts.count == 2 { AppModel.shared.setLoginItem(parts[0] == "helper" ? .helper : .app, on: parts[1] == "on") }
                    AppModel.shared.reloadLoginItems()
                    let helpers = NSRunningApplication.runningApplications(withBundleIdentifier: LoginItems.helperIdentifier).filter { !$0.isTerminated }
                    print("debug: login items app \(AppModel.shared.opensAtLogin) helper \(AppModel.shared.helperAtLogin) refusal \(AppModel.shared.loginItemRefusal.values.sorted()) helper running \(helpers.map { "\($0.processIdentifier) \($0.bundleURL?.path ?? "?")" })")
                case "editmenu":
                    print("debug: main menu \(NSApp.mainMenu?.items.map(\.title) ?? []), paste \(NSApp.mainMenu?.items.contains { $0.submenu?.items.contains { $0.action == #selector(NSText.paste(_:)) } == true } == true)")
                case "helperkey":
                    // What the key of quick entry does in this program.
                    #if LISTS_HELPER
                    // Transparent and without the keyboard, as `quickopen` shows it.
                    QuickEntryPanel.debugSilent = true
                    QuickEntryPanel.shared.alphaValue = 0
                    HelperDelegate.present()
                    try? await _Concurrency.Task.sleep(for: .milliseconds(300))
                    #else
                    QuickEntryPanel.shared.toggle()
                    #endif
                case "settings": NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                case "windows":
                    for window in NSApp.windows {
                        print("debug: window \(type(of: window)) titled \(window.styleMask.contains(.titled)) resizable \(window.styleMask.contains(.resizable)) visible \(window.isVisible) key \(window.isKeyWindow) frame \(NSStringFromRect(window.frame))")
                    }
                case "state":
                    let window = target
                    print("debug: key window \(window.map { type(of: $0) }.map(String.init(describing:)) ?? "none"), first responder \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")\((window?.firstResponder as? NSTableView)?.style == .sourceList ? " (sidebar)" : "")\((window?.firstResponder as? NSText).map { " with \"\($0.string)\"" } ?? "")\(((window?.firstResponder as? NSTextView)?.delegate as? NSTextField).map { ", field \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "")")
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
                case "viewicons":
                    let scopes: [Scope] = [.inbox, .today, .upcoming, .all, .completed, .wontDo, .trash]
                    let icons = scopes.compactMap { scope in scope.viewIcon.map { (scope, $0) } }
                    func column(_ scheme: ColorScheme) -> some View {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(icons, id: \.1.symbol) { icon in
                                Label { Text(icon.1.symbol) } icon: { Image(systemName: icon.1.symbol).foregroundStyle(icon.1.tint) }
                            }
                        }
                        .padding(10).frame(width: 220, alignment: .leading)
                        .background(scheme == .dark ? Color.black : Color.white).environment(\.colorScheme, scheme)
                    }
                    let renderer = ImageRenderer(content: HStack(spacing: 0) { column(.light); column(.dark) })
                    renderer.scale = 4
                    if let image = renderer.cgImage {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
                    }
                    print("debug: view icons \(icons.map { "\($0.0): \($0.1.symbol)" })")
                case "winshot":
                    // The whole main window drawn into a file, hidden or not.
                    if let view = target?.contentView?.superview ?? target?.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: image)
                        try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
                        print("debug: window drawn, \(image.pixelsWide)x\(image.pixelsHigh) pixels")
                    }
                case "settingstab": Storage.defaults.set(argument, forKey: "settingsTab")
                case "settingsshot":
                    // The settings drawn into a file from a window that is never shown: a hidden app opens no settings window.
                    let window = settingsWindow ?? {
                        let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
                        made.isReleasedWhenClosed = false
                        made.contentView = NSHostingView(rootView: SettingsView().environment(AppModel.shared))
                        settingsWindow = made
                        return made
                    }()
                    if let view = window.contentView {
                        view.layoutSubtreeIfNeeded()
                        window.setContentSize(view.fittingSize)
                        view.layoutSubtreeIfNeeded()
                        if let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: image)
                            try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
                            print("debug: settings drawn, \(image.pixelsWide)x\(image.pixelsHigh) pixels, tab \(Storage.defaults.string(forKey: "settingsTab") ?? "general")")
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
    static var target: NSWindow? { NSApp.keyWindow ?? (ghost ? popoverWindow : nil) ?? silentQuickEntry ?? backgroundWindow }

    /// Quick entry while `quickopen` has it on show without the keyboard: the key presses of the script are for its card.
    private static var silentQuickEntry: NSWindow? {
        QuickEntryPanel.debugSilent && QuickEntryPanel.shared.isVisible ? QuickEntryPanel.shared : nil
    }

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

    /// The settings that `settingsshot` built off screen.
    private static var settingsWindow: NSWindow?

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
