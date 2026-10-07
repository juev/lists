// Posts key presses to one process the way the keyboard driver does, without
// bringing it forward: the check that the `code` step of apple/App/DebugScript.swift
// gives a press the window a real one has. The terminal needs the Accessibility permission.
//
//   swiftc -O scripts/postkey.swift -o /tmp/postkey
//   /tmp/postkey <pid> <key code>[+cmd] ...        # 0.4 s between presses
import CoreGraphics
import Foundation
let args = CommandLine.arguments
guard args.count > 2, let pid = Int32(args[1]) else { print("usage"); exit(2) }
let source = CGEventSource(stateID: .hidSystemState)
for item in args[2...] {
    let parts = item.split(separator: "+")
    guard let code = UInt16(parts[0]) else { continue }
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
        event.flags = parts.contains("cmd") ? .maskCommand : []
        event.postToPid(pid)
        usleep(30_000)
    }
    usleep(400_000)
}
