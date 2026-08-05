import CoreGraphics
import Foundation

// Types arbitrary text into the focused field using Unicode keyboard events.
// Usage: swiftc -O -o /tmp/uitest/type Tools/UITest/TypeText/main.swift
//        /tmp/uitest/type "text to type"

let text = CommandLine.arguments.dropFirst().joined(separator: " ")
let source = CGEventSource(stateID: .hidSystemState)

for scalar in text.unicodeScalars {
    var chars = Array(String(scalar).utf16)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { continue }
    down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
    down.post(tap: .cghidEventTap)
    usleep(25_000)
    guard let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
    up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
    up.post(tap: .cghidEventTap)
    usleep(25_000)
}
