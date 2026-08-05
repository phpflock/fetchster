import ApplicationServices
import Foundation

// Dev tool: dump the accessibility tree of a running process.
// Build: swiftc -O -o /tmp/axdump Tools/AXDump/main.swift
// Usage:  /tmp/axdump <pid>

guard CommandLine.arguments.count > 1, let pid = pid_t(CommandLine.arguments[1]) else {
    print("usage: axdump <pid>")
    exit(1)
}

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value as AnyObject?
}

func walk(_ element: AXUIElement, depth: Int) {
    let role = attr(element, kAXRoleAttribute) as? String ?? "?"
    let title = attr(element, kAXTitleAttribute) as? String ?? ""
    let desc = attr(element, kAXDescriptionAttribute) as? String ?? ""
    let value = attr(element, kAXValueAttribute) as? String ?? ""
    var position = ""
    var size = ""
    if let rawPoint = attr(element, kAXPositionAttribute), CFGetTypeID(rawPoint) == AXValueGetTypeID() {
        var point = CGPoint.zero
        let pointValue = rawPoint as! AXValue
        AXValueGetValue(pointValue, .cgPoint, &point)
        position = "@\(Int(point.x)),\(Int(point.y))"
    }
    if let rawSize = attr(element, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() {
        var sz = CGSize.zero
        let sizeValue = rawSize as! AXValue
        AXValueGetValue(sizeValue, .cgSize, &sz)
        size = "\(Int(sz.width))x\(Int(sz.height))"
    }
    print(String(repeating: "  ", count: depth) + "\(role) \(position) \(size) | \(title) | \(desc) | \(value)")
    if let children = attr(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            walk(child, depth: depth + 1)
        }
    }
}

let app = AXUIElementCreateApplication(pid)

if CommandLine.arguments.contains("--click") {
    guard let index = CommandLine.arguments.firstIndex(of: "--click"),
          CommandLine.arguments.count > index + 1 else {
        print("usage: axdump <pid> --click <query>")
        exit(1)
    }
    let query = CommandLine.arguments[index + 1]
    var clicked = false

    // Raise the target app so synthetic clicks land on its window, not
    // whatever is currently frontmost.
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    usleep(400_000)

    func clickIfMatches(_ element: AXUIElement) {
        guard !clicked else { return }
        let title = attr(element, kAXTitleAttribute) as? String ?? ""
        let desc = attr(element, kAXDescriptionAttribute) as? String ?? ""
        let matches = title.localizedCaseInsensitiveContains(query) || desc.localizedCaseInsensitiveContains(query)
        if matches,
           let rawPos = attr(element, kAXPositionAttribute), CFGetTypeID(rawPos) == AXValueGetTypeID(),
           let rawSize = attr(element, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() {
            var point = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(rawPos as! AXValue, .cgPoint, &point)
            AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
            let center = CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(80_000)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
            print("clicked \(Int(center.x)),\(Int(center.y))")
            clicked = true
            return
        }
        if let children = attr(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                clickIfMatches(child)
                if clicked { return }
            }
        }
    }

    if let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] {
        for window in windows {
            clickIfMatches(window)
            if clicked { break }
        }
    }
    if !clicked {
        print("not found: \(query)")
        exit(2)
    }
    exit(0)
}

if CommandLine.arguments.contains("--click-exact") {
    guard let index = CommandLine.arguments.firstIndex(of: "--click-exact"),
          CommandLine.arguments.count > index + 1 else {
        print("usage: axdump <pid> --click-exact <query>")
        exit(1)
    }
    let query = CommandLine.arguments[index + 1]
    var clicked = false

    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    usleep(400_000)

    func clickIfMatches(_ element: AXUIElement) {
        guard !clicked else { return }
        let title = attr(element, kAXTitleAttribute) as? String ?? ""
        let desc = attr(element, kAXDescriptionAttribute) as? String ?? ""
        let matches = title == query || desc == query
        if matches,
           let rawPos = attr(element, kAXPositionAttribute), CFGetTypeID(rawPos) == AXValueGetTypeID(),
           let rawSize = attr(element, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() {
            var point = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(rawPos as! AXValue, .cgPoint, &point)
            AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
            let center = CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(80_000)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
            print("clicked-exact \(Int(center.x)),\(Int(center.y))")
            clicked = true
            return
        }
        if let children = attr(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                clickIfMatches(child)
                if clicked { return }
            }
        }
    }

    if let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] {
        for window in windows {
            clickIfMatches(window)
            if clicked { break }
        }
    }
    if !clicked {
        print("not found: \(query)")
        exit(2)
    }
    exit(0)
}

if let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] {
    print("windows: \(windows.count)")
    for window in windows {
        walk(window, depth: 0)
    }
} else {
    print("no windows exposed")
}
