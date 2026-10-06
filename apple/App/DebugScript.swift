#if DEBUG
import AppKit

/// Drives the app from inside for checks that need key presses: macOS lets no
/// outside process send them without the Accessibility permission. Debug
/// builds only. `LISTS_DEBUG_SCRIPT` holds steps separated by `;`:
/// `type:text`, `key:return`, `key:n+cmd`, `sleep:0.5`, `click:x,y`, `quick`, `settings`,
/// `state` (prints who has the keyboard), `copyfiles:path,path` and `copyimage`
/// (fill the pasteboard), `draft` (prints the files of the open new-task card),
/// `open` (expands the selected task), `panel` (prints whether quick entry is on screen and what runs modally).
@MainActor
enum DebugScript {
    private static let codes: [String: (UInt16, String)] = [
        "return": (36, "\r"), "esc": (53, "\u{1b}"), "space": (49, " "), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
        "]": (30, "]"), "[": (33, "["),
    ]

    static func runIfAsked() {
        guard let script = ProcessInfo.processInfo.environment["LISTS_DEBUG_SCRIPT"] else { return }
        setlinebuf(stdout)
        let steps = script.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }
        _Concurrency.Task { @MainActor in
            try? await _Concurrency.Task.sleep(for: .seconds(1.5))
            for _ in 0..<30 where NSApp.keyWindow == nil {
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
                case "open":
                    if let id = AppModel.shared.selection { AppModel.shared.toggleExpanded(id) }
                case "panel":
                    print("debug: quick entry \(QuickEntryPanel.shared.isVisible ? "shown" : "hidden"), modal \(NSApp.modalWindow.map { String(describing: type(of: $0)) } ?? "none")")
                case "quick": QuickEntryPanel.shared.present()
                case "settings": NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                case "state":
                    let window = NSApp.keyWindow
                    print("debug: key window \(window.map { type(of: $0) }.map(String.init(describing:)) ?? "none"), first responder \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
                default: print("debug: unknown step \(step)")
                }
                try? await _Concurrency.Task.sleep(for: .milliseconds(60))
            }
            print("debug: script finished")
            fflush(stdout)
        }
    }

    private static func press(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags) {
        guard let window = NSApp.keyWindow else { return print("debug: no key window for \(characters)") }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                NSApp.sendEvent(event)
            }
        }
    }
}
#endif
