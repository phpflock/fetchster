import AppKit
import CoreGraphics

// Renders the Fetchster app icon at 1024x1024: a macOS-style squircle with a
// download-into-tray motif matching the "all your downloads, caught in the
// menu bar" identity. Outputs AppIcon.iconset PNGs for iconutil.

func squirclePath(size: CGFloat) -> NSBezierPath {
    // macOS Big Sur+ icon shape: rounded rect with ~22.37% corner radius.
    let radius = size * 0.2237
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    return path
}

func drawIcon() -> NSImage {
    let size: CGFloat = 1024
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let clip = squirclePath(size: size)
    clip.addClip()

    // Base gradient (deep blue).
    let baseColors = [
        NSColor(srgbRed: 0.13, green: 0.33, blue: 0.86, alpha: 1).cgColor,
        NSColor(srgbRed: 0.10, green: 0.20, blue: 0.60, alpha: 1).cgColor,
    ]
    let baseGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: baseColors as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(baseGrad,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: 0, y: 0),
                           options: [])

    // Diagonal sheen for depth.
    let sheenColors = [
        NSColor.white.withAlphaComponent(0.18).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ]
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: sheenColors as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: size, y: 0),
                           options: [])

    // Soft radial glow top-left.
    let glowColors = [
        NSColor.white.withAlphaComponent(0.22).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ]
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: glowColors as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: 300, y: 780), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 780), endRadius: 620,
                           options: [])

    // Downward arrow, drawn as a filled path (white).
    ctx.setFillColor(NSColor.white.cgColor)
    let arrow = CGMutablePath()
    let shaftX: CGFloat = 512
    let shaftWidth: CGFloat = 116
    let shaftTop: CGFloat = 830
    let shaftBottom: CGFloat = 500
    // Shaft
    arrow.addRect(CGRect(x: shaftX - shaftWidth / 2, y: shaftBottom,
                         width: shaftWidth, height: shaftTop - shaftBottom))
    // Head
    arrow.move(to: CGPoint(x: 300, y: 520))
    arrow.addLine(to: CGPoint(x: 512, y: 260))
    arrow.addLine(to: CGPoint(x: 724, y: 520))
    arrow.closeSubpath()
    ctx.addPath(arrow)
    ctx.fillPath()

    // Tray / "caught downloads" line at the bottom.
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    let tray = NSBezierPath(roundedRect: NSRect(x: 190, y: 120, width: 644, height: 120),
                            xRadius: 60, yRadius: 60)
    tray.fill()

    // Inner tray line for a "slot" look.
    ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.20, blue: 0.60, alpha: 1).cgColor)
    let slot = NSBezierPath(roundedRect: NSRect(x: 272, y: 158, width: 480, height: 44),
                            xRadius: 22, yRadius: 22)
    slot.fill()

    image.unlockFocus()
    return image
}

let base = "/Users/shady/projects/Fetchster/Resources"
let iconset = "\(base)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let image = drawIcon()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    fatalError("Could not render icon")
}

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for s in sizes {
    let scaled = NSImage(size: NSSize(width: s.px, height: s.px))
    scaled.lockFocus()
    image.draw(in: NSRect(x: 0, y: 0, width: s.px, height: s.px),
               from: .zero, operation: .sourceOver, fraction: 1.0)
    scaled.unlockFocus()
    guard let t = scaled.tiffRepresentation,
          let r = NSBitmapImageRep(data: t),
          let png = r.representation(using: .png, properties: [:]) else {
        fatalError("Could not scale \(s.name)")
    }
    try? png.write(to: URL(fileURLWithPath: "\(iconset)/\(s.name).png"))
    print("Wrote \(s.name).png")
}
