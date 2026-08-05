import AppKit
import Foundation

// Generates simple down-arrow app icons for the browser extension.
// Usage: swift Tools/GenerateIcons/main.swift <output-directory>

guard CommandLine.arguments.count > 1 else {
    print("usage: GenerateIcons <output-directory>")
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for size in [16, 32, 48, 128] {
    let dimension = CGFloat(size)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: dimension, height: dimension)
    let background = NSBezierPath(roundedRect: rect, xRadius: dimension * 0.22, yRadius: dimension * 0.22)
    NSColor(calibratedRed: 0.10, green: 0.48, blue: 0.95, alpha: 1).setFill()
    background.fill()

    let arrow = NSBezierPath()
    let centerX = dimension / 2
    let stemHalf = dimension * 0.09
    let headHalf = dimension * 0.27
    let stemTop = dimension * 0.68
    let headStart = dimension * 0.42
    let tip = dimension * 0.18
    arrow.move(to: NSPoint(x: centerX - stemHalf, y: stemTop))
    arrow.line(to: NSPoint(x: centerX + stemHalf, y: stemTop))
    arrow.line(to: NSPoint(x: centerX + stemHalf, y: headStart))
    arrow.line(to: NSPoint(x: centerX + headHalf, y: headStart))
    arrow.line(to: NSPoint(x: centerX, y: tip))
    arrow.line(to: NSPoint(x: centerX - headHalf, y: headStart))
    arrow.line(to: NSPoint(x: centerX - stemHalf, y: headStart))
    arrow.close()
    NSColor.white.setFill()
    arrow.fill()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not render icon")
    }
    let target = outDir.appendingPathComponent("icon\(size).png")
    try? png.write(to: target)
    print("wrote \(target.path)")
}
