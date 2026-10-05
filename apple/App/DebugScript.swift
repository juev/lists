#if DEBUG
import AppKit

/// Drives the app from inside for checks that need key presses: macOS lets no
/// outside process send them without the Accessibility permission. Debug
/// builds only. `LISTS_DEBUG_SCRIPT` holds steps separated by `;`:
/// `type:text`, `key:return`, `key:n+cmd`, `sleep:0.5`, `quick`, `settings`,
/// `state` (prints who has the keyboard).
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
