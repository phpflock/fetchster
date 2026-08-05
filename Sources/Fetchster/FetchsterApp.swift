import SwiftUI
import AppKit

@main
struct FetchsterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            DownloadStore.shared.save()
            TorrentEngine.shared.shutdown()
        }
    }

    var body: some Scene {
        // No window scenes: the menu-bar item and popover are managed manually
        // by AppDelegate (the SwiftUI `MenuBarExtra` scene is crash-prone when
        // the list updates rapidly under an open popover, e.g. a resumed
        // download completing).
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var globalMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            let image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Fetchster")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "Fetchster"
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuRootView(store: DownloadStore.shared)
        )
        self.popover = popover

        // After a right-click context menu inside the popover, AppKit's
        // transient dismissal can stop firing, leaving the popover "stuck"
        // when the user clicks the desktop or another app. A global monitor
        // closes it on any outside click (the status item is exempt so its
        // toggle action still works).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closeIfOutsideClick()
        }

        NotificationCenter.default.addObserver(
            forName: .mediaDetected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.popStatusIcon()
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let popover, let button = statusItem?.button else { return }
        // Menu-bar apps are agent apps (LSUIElement); activate so keyboard
        // input in the popover (e.g. the + URL field) works as expected.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closeIfOutsideClick() {
        guard let popover, popover.isShown else { return }
        guard let button = statusItem?.button, let window = button.window else {
            popover.performClose(nil)
            return
        }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        if buttonFrame.contains(NSEvent.mouseLocation) {
            return
        }
        popover.performClose(nil)
    }

    /// "Pop" effect: flash the menu bar icon a few times when a video is
    /// detected, so the user knows the popover now lists downloadable streams.
    private func popStatusIcon() {
        guard let button = statusItem?.button else { return }
        let plain = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Fetchster")
        let fill = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Fetchster")
        plain?.isTemplate = true
        fill?.isTemplate = true

        for i in 0..<5 {
            let showFill = i % 2 == 0
            let delay = Double(i) * 0.13
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak button] in
                button?.image = showFill ? fill : plain
                button?.contentTintColor = showFill ? .systemBlue : nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak button] in
            button?.image = plain
            button?.contentTintColor = nil
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            DownloadStore.shared.handleOpenURL(url)
        }
    }
}
