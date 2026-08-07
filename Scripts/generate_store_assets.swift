import AppKit
import ImageIO
import UniformTypeIdentifiers

// Renders store/docs screenshots for the Chrome Web Store version of
// Fetchster Capture. Deliberately shows only file, magnet, and torrent
// downloads — no media features.

// MARK: - Colors

let accent = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1)
let dark = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
let gray = NSColor(srgbRed: 0.42, green: 0.43, blue: 0.47, alpha: 1)
let lightGray = NSColor(srgbRed: 0.92, green: 0.93, blue: 0.95, alpha: 1)
let green = NSColor(srgbRed: 0.11, green: 0.62, blue: 0.36, alpha: 1)
let yellow = NSColor(srgbRed: 0.95, green: 0.69, blue: 0.12, alpha: 1)

// MARK: - Canvas

final class Canvas {
    let width: CGFloat
    let height: CGFloat
    let rep: NSBitmapImageRep
    let ctx: NSGraphicsContext

    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
        rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width),
            pixelsHigh: Int(height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: width, height: height)
        ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
    }

    private func y(_ top: CGFloat, _ h: CGFloat) -> CGFloat {
        height - top - h
    }

    func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x, y: y(top, h), width: w, height: h)
    }

    func fill(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
        color.setFill()
        rect(x, top, w, h).fill()
    }

    func fillRounded(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat,
                     radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect(x, top, w, h), xRadius: radius, yRadius: radius).fill()
    }

    func gradient(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat,
                  colors: [NSColor], angle: CGFloat = -90) {
        NSGradient(colors: colors)!.draw(in: rect(x, top, w, h), angle: angle)
    }

    func text(_ s: String, _ x: CGFloat, _ top: CGFloat,
              size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: x, y: height - top - sz.height))
    }

    func textCentered(_ s: String, _ cx: CGFloat, _ top: CGFloat,
                      size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: cx - sz.width / 2, y: height - top - sz.height))
    }

    func textRight(_ s: String, _ right: CGFloat, _ top: CGFloat,
                   size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: right - sz.width, y: height - top - sz.height))
    }

    func symbol(_ name: String, _ x: CGFloat, _ top: CGFloat,
                _ w: CGFloat, _ h: CGFloat, colors: [NSColor]) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        var cfg = NSImage.SymbolConfiguration(pointSize: min(w, h) * 0.72, weight: .medium)
        cfg = cfg.applying(.init(paletteColors: colors))
        guard let img = base.withSymbolConfiguration(cfg) else { return }
        img.draw(in: rect(x, top, w, h))
    }

    func shadow(_ blur: CGFloat, _ color: NSColor = NSColor.black.withAlphaComponent(0.16),
                offset: NSSize = .zero) {
        let s = NSShadow()
        s.shadowBlurRadius = blur
        s.shadowColor = color
        s.shadowOffset = offset
        s.set()
    }

    func noShadow() {
        let s = NSShadow()
        s.shadowBlurRadius = 0
        s.shadowColor = .clear
        s.set()
    }

    func save(_ path: String) {
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { fatalError("no cgImage") }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let rgbCtx = CGContext(
            data: nil,
            width: cg.width,
            height: cg.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { fatalError("no rgb context") }
        rgbCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        rgbCtx.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        rgbCtx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let rgb = rgbCtx.makeImage() else { fatalError("no rgb image") }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("no image destination")
        }
        CGImageDestinationAddImage(dest, rgb, nil)
        guard CGImageDestinationFinalize(dest) else { fatalError("png write failed") }
    }
}

// MARK: - Shared chrome

func drawDesktop(_ c: Canvas) {
    c.gradient(0, 0, c.width, c.height, colors: [
        NSColor(srgbRed: 0.94, green: 0.95, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.82, green: 0.85, blue: 0.91, alpha: 1),
    ])
}

func drawMenuBar(_ c: Canvas) {
    c.fill(0, 0, c.width, 30, NSColor.white.withAlphaComponent(0.78))
    c.fill(0, 30, c.width, 1, NSColor.black.withAlphaComponent(0.08))
    c.symbol("applelogo", 16, 7, 16, 16, colors: [.black])
    c.text("Fetchster", 40, 7, size: 13, weight: .semibold, color: .black)
    c.textRight("2:41 PM", c.width - 16, 8, size: 13, weight: .medium, color: .black)
    c.symbol("battery.100percent", c.width - 62, 8, 19, 16, colors: [.black])
    c.symbol("wifi", c.width - 92, 8, 18, 15, colors: [.black])
    c.symbol("magnifyingglass", c.width - 120, 8, 16, 16, colors: [.black])
}

struct PopRow {
    let icon: String
    let iconColors: [NSColor]
    let title: String
    let subtitle: String
    let right: String
    let rightColor: NSColor
    let progress: CGFloat?
    let progressColor: NSColor
}

func drawPopover(_ c: Canvas,
                 x: CGFloat, top: CGFloat, width: CGFloat,
                 header: String, pill: String,
                 rows: [PopRow],
                 footer: String, footerRight: String) {
    let headerH: CGFloat = 74
    let rowH: CGFloat = 68
    let footerH: CGFloat = 56
    let height = headerH + CGFloat(rows.count) * rowH + footerH

    c.shadow(26)
    c.fillRounded(x, top, width, height, radius: 18, .white)
    c.noShadow()

    c.text(header, x + 26, top + 26, size: 17, weight: .semibold, color: dark)
    let pillW: CGFloat = 96
    let pillH: CGFloat = 26
    c.fillRounded(x + width - 26 - pillW, top + 16, pillW, pillH, radius: 13,
                  NSColor.black.withAlphaComponent(0.07))
    c.textCentered(pill, x + width - 26 - pillW + pillW / 2, top + 22,
                   size: 12, weight: .semibold, color: gray)

    c.fill(x + 26, top + headerH, width - 52, 1, NSColor.black.withAlphaComponent(0.07))

    for (i, row) in rows.enumerated() {
        let rowTop = top + headerH + CGFloat(i) * rowH
        c.fillRounded(x + 26, rowTop + 14, 38, 38, radius: 9, lightGray)
        c.symbol(row.icon, x + 26 + 9, rowTop + 23, 20, 20, colors: row.iconColors)
        c.text(row.title, x + 78, rowTop + 13, size: 14, weight: .medium, color: dark)
        c.text(row.subtitle, x + 78, rowTop + 34, size: 12, weight: .regular, color: gray)
        c.textRight(row.right, x + width - 26, rowTop + 15, size: 12, weight: .medium, color: row.rightColor)

        if let progress = row.progress {
            c.fillRounded(x + 78, rowTop + 51, width - 104, 5, radius: 2.5,
                          NSColor.black.withAlphaComponent(0.07))
            if progress > 0 {
                c.fillRounded(x + 78, rowTop + 51, max(8, (width - 104) * min(progress, 1)), 5,
                              radius: 2.5, row.progressColor)
            }
        }

        if i < rows.count - 1 {
            c.fill(x + 78, rowTop + rowH, width - 104, 1, NSColor.black.withAlphaComponent(0.05))
        }
    }

    c.fill(x + 26, top + height - footerH, width - 52, 1, NSColor.black.withAlphaComponent(0.07))
    c.text(footer, x + 26, top + height - footerH + 20, size: 11, weight: .regular, color: gray)
    c.textRight(footerRight, x + width - 26, top + height - footerH + 20,
                size: 11, weight: .medium, color: gray)
}

// MARK: - Asset 1: menu bar with download list

func assetMenu() {
    let c = Canvas(width: 1280, height: 800)
    drawDesktop(c)
    drawMenuBar(c)

    let rows: [PopRow] = [
        PopRow(icon: "archivebox.fill", iconColors: [accent, .white],
               title: "project-backup.zip", subtitle: "128 MB · completed",
               right: "Done", rightColor: green, progress: 1, progressColor: green),
        PopRow(icon: "doc.fill", iconColors: [gray, .white],
               title: "quarterly-report.pdf", subtitle: "3.4 MB · completed",
               right: "Done", rightColor: green, progress: 1, progressColor: green),
        PopRow(icon: "arrow.down.circle.fill", iconColors: [accent, .white],
               title: "ubuntu-24.04-desktop-amd64.iso", subtitle: "4.6 GB · 48%",
               right: "6.2 MB/s", rightColor: accent, progress: 0.48, progressColor: accent),
        PopRow(icon: "link", iconColors: [NSColor.systemPurple, .white],
               title: "magnet:?xt=urn:btih:…&dn=conference-notes", subtitle: "Torrent · fetching metadata",
               right: "—", rightColor: gray, progress: 0.12, progressColor: yellow),
        PopRow(icon: "tray.and.arrow.down.fill", iconColors: [NSColor.systemTeal, .white],
               title: "design-assets.zip", subtitle: "Queued",
               right: "—", rightColor: gray, progress: 0, progressColor: accent),
    ]

    drawPopover(c, x: 340, top: 104, width: 600,
                header: "Fetchster", pill: "5 downloads",
                rows: rows,
                footer: "Download folder: ~/Downloads/Fetchster", footerRight: "2 paused")
    c.save("docs/images/fetchster-menu.png")
}

// MARK: - Asset 2: browser capture + extension popup

func drawBrowserWindow(_ c: Canvas, x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat) {
    c.shadow(30)
    c.fillRounded(x, top, w, h, radius: 14, .white)
    c.noShadow()
    c.fill(x, top, w, 52, NSColor(srgbRed: 0.965, green: 0.97, blue: 0.98, alpha: 1))
    c.fillRounded(x, top + 52, w, 14, radius: 14, NSColor(srgbRed: 0.965, green: 0.97, blue: 0.98, alpha: 1))

    let lights = [NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1),
                  NSColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1),
                  NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)]
    for (i, color) in lights.enumerated() {
        c.fillRounded(x + 18 + CGFloat(i) * 22, top + 19, 12, 12, radius: 6, color)
    }

    c.fillRounded(x + 90, top + 13, w - 128, 26, radius: 13,
                  NSColor.black.withAlphaComponent(0.06))
    c.symbol("lock.fill", x + 106, top + 19, 12, 12, colors: [gray])
    c.text("https://example.com/releases", x + 128, top + 18, size: 12, weight: .regular, color: gray)

    c.text("Fetchster 2.4.1", x + 48, top + 108, size: 30, weight: .bold, color: dark)
    c.text("A native macOS download manager. Files, magnets,", x + 48, top + 156, size: 15, weight: .regular, color: gray)
    c.text("and torrents — all in one clean menu bar list.", x + 48, top + 180, size: 15, weight: .regular, color: gray)

    c.shadow(12)
    c.fillRounded(x + 48, top + 222, 230, 46, radius: 11, accent)
    c.noShadow()
    c.textCentered("Download (.zip)", x + 48 + 115, top + 236, size: 15, weight: .semibold, color: .white)

    // Right-click context menu
    let mx = x + 300
    let my = top + 158
    let mw: CGFloat = 250
    c.shadow(18)
    c.fillRounded(mx, my, mw, 176, radius: 10, .white)
    c.noShadow()
    c.text("Open link in new tab", mx + 18, my + 18, size: 13, weight: .regular, color: dark)
    c.text("Save link as…", mx + 18, my + 46, size: 13, weight: .regular, color: dark)
    c.fill(mx + 12, my + 68, mw - 24, 1, NSColor.black.withAlphaComponent(0.07))
    c.fillRounded(mx + 8, my + 82, mw - 16, 34, radius: 7, accent)
    c.text("Download with Fetchster", mx + 20, my + 93, size: 13, weight: .semibold, color: .white)
    c.text("Inspect", mx + 18, my + 136, size: 13, weight: .regular, color: dark)
}

func drawExtensionPopup(_ c: Canvas, x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat) {
    c.shadow(24)
    c.fillRounded(x, top, w, h, radius: 16, .white)
    c.noShadow()

    c.text("Fetchster Capture", x + 24, top + 22, size: 15, weight: .semibold, color: dark)
    c.text("Hands downloads to the Fetchster app", x + 24, top + 44, size: 11, weight: .regular, color: gray)
    c.fill(x + 24, top + 66, w - 48, 1, NSColor.black.withAlphaComponent(0.07))

    c.text("Capture downloads", x + 24, top + 92, size: 14, weight: .medium, color: dark)
    c.fillRounded(x + w - 24 - 46, top + 84, 46, 26, radius: 13, accent)
    c.fillRounded(x + w - 24 - 46 + 20, top + 88, 18, 18, radius: 9, .white)

    c.fillRounded(x + 24, top + 124, 8, 8, radius: 4, green)
    c.text("Server: connected", x + 42, top + 118, size: 13, weight: .medium, color: green)

    c.text("Files, magnets & torrents go to the", x + 24, top + 158, size: 11, weight: .regular, color: gray)
    c.text("Fetchster menu bar app on this Mac.", x + 24, top + 176, size: 11, weight: .regular, color: gray)
}

func assetCapture() {
    let c = Canvas(width: 1280, height: 800)
    drawDesktop(c)
    drawMenuBar(c)
    drawBrowserWindow(c, x: 74, top: 84, w: 700, h: 620)
    drawExtensionPopup(c, x: 848, top: 220, w: 350, h: 320)

    // Notification toast
    c.shadow(14)
    c.fillRounded(920, 84, 300, 44, radius: 11, NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1))
    c.noShadow()
    c.text("Downloading: fetchster-2.4.1.zip", 944, 99, size: 12, weight: .medium, color: .white)

    c.save("docs/images/fetchster-capture.png")
}

// MARK: - Asset 3: torrents

func assetTorrents() {
    let c = Canvas(width: 1280, height: 800)
    drawDesktop(c)
    drawMenuBar(c)

    let rows: [PopRow] = [
        PopRow(icon: "arrow.up.arrow.down", iconColors: [green, .white],
               title: "ubuntu-24.04-desktop-amd64.iso", subtitle: "72% · 3.1 MB/s",
               right: "S 42 · P 8", rightColor: gray, progress: 0.72, progressColor: green),
        PopRow(icon: "arrow.up.arrow.down", iconColors: [green, .white],
               title: "open-source-toolkit-v3.tar.gz", subtitle: "100% · seeding",
               right: "S 12 · P 0", rightColor: gray, progress: 1, progressColor: green),
        PopRow(icon: "bolt.fill", iconColors: [yellow, .white],
               title: "magnet:?xt=urn:btih:…&dn=conference-notes", subtitle: "Fetching metadata…",
               right: "S 0 · P 0", rightColor: gray, progress: 0.1, progressColor: yellow),
        PopRow(icon: "pause.fill", iconColors: [gray, .white],
               title: "design-assets.zip", subtitle: "Paused",
               right: "—", rightColor: gray, progress: 0.32, progressColor: gray),
    ]

    drawPopover(c, x: 330, top: 104, width: 620,
                header: "Fetchster", pill: "3 active",
                rows: rows,
                footer: "Torrent engine: aria2 · DHT enabled", footerRight: "1 seeding")
    c.save("docs/images/fetchster-torrents.png")
}

// MARK: - Asset 4: social / OG card

func assetOG() {
    let c = Canvas(width: 1200, height: 630)
    c.gradient(0, 0, c.width, c.height, colors: [
        NSColor(srgbRed: 0.08, green: 0.36, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.04, green: 0.20, blue: 0.56, alpha: 1),
    ])

    // Big download-into-tray mark, matching the app icon motif.
    c.shadow(40, NSColor.black.withAlphaComponent(0.28))
    c.fillRounded(c.width / 2 - 92, 118, 184, 184, radius: 46, .white)
    c.noShadow()

    let shaftW: CGFloat = 34
    let shaftTop: CGFloat = 176
    let shaftBottom: CGFloat = 248
    let cx = c.width / 2
    accent.setFill()
    let arrow = NSBezierPath()
    arrow.appendRect(NSRect(x: cx - shaftW / 2, y: c.height - shaftBottom,
                            width: shaftW, height: shaftTop - shaftBottom))
    arrow.move(to: NSPoint(x: cx - 52, y: c.height - 252))
    arrow.line(to: NSPoint(x: cx, y: c.height - 300))
    arrow.line(to: NSPoint(x: cx + 52, y: c.height - 252))
    arrow.close()
    arrow.fill()

    c.textCentered("Fetchster", c.width / 2, 368, size: 64, weight: .bold, color: .white)
    c.textCentered("All your downloads, caught in the menu bar.", c.width / 2, 452,
                   size: 26, weight: .regular, color: NSColor.white.withAlphaComponent(0.85))

    // Subtle menu-bar strip at the bottom.
    c.fillRounded(330, 548, 540, 30, radius: 8, NSColor.white.withAlphaComponent(0.14))
    c.textCentered("Files · Magnets · Torrents", c.width / 2, 558,
                   size: 13, weight: .semibold, color: .white)
    c.save("docs/images/fetchster-og.png")
}

assetMenu()
assetCapture()
assetTorrents()
assetOG()
print("done")
