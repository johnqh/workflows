// Rotates the iOS Simulator device orientation by sending keyboard events.
// Usage: sim_rotate <portrait|landscape>
// Requires Simulator.app to be running.

import Cocoa

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: sim_rotate <portrait|landscape>\n", stderr)
    exit(1)
}

let target = CommandLine.arguments[1]

// Activate Simulator
let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.iphonesimulator" }
guard let simulator = apps.first else {
    fputs("Error: Simulator.app is not running\n", stderr)
    exit(1)
}
simulator.activate()
usleep(500_000)

// Cmd+Left rotates left (→ landscape), Cmd+Right rotates right (→ portrait from landscape)
// keycode 123 = Left Arrow, 124 = Right Arrow
let keyCode: UInt16
switch target {
case "landscape":
    keyCode = 123 // Cmd+Left
case "portrait":
    keyCode = 124 // Cmd+Right
default:
    fputs("Error: Unknown orientation '\(target)'. Use 'portrait' or 'landscape'.\n", stderr)
    exit(1)
}

guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
    fputs("Error: Failed to create keyboard events\n", stderr)
    exit(1)
}

keyDown.flags = .maskCommand
keyDown.post(tap: .cghidEventTap)
keyUp.flags = .maskCommand
keyUp.post(tap: .cghidEventTap)

usleep(1_000_000)
print("Rotated to \(target)")
