import Foundation

// Headless smoke test for the app's core engines (no SwiftUI).
// Build + run:
//   swiftc -O -o /tmp/idltest/harness \
//     Sources/Fetchster/Models.swift \
//     Sources/Fetchster/FileUtils.swift \
//     Sources/Fetchster/HTTPDownloadManager.swift \
//     Sources/Fetchster/TorrentEngine.swift \
//     Sources/Fetchster/DownloadStore.swift \
//     Tools/TestHarness/main.swift
// (wrap in a minimal .app bundle so UserNotifications works)

let store = DownloadStore.shared
store.downloadDirectory = URL(fileURLWithPath: "/tmp/idltest")
print("download dir: \(store.downloadDirectory.path)")
print("torrent binary: \(TorrentEngine.locateBinary()?.path ?? "NOT FOUND")")

store.addURLString("https://raw.githubusercontent.com/apple/swift/main/README.md")
store.addURLString("https://webtorrent.io/torrents/sintel.torrent")

var tick = 0
Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
    tick += 1
    print("--- t=\(tick * 5)s engine.available=\(TorrentEngine.shared.available) snapshots=\(TorrentEngine.shared.snapshots.keys.count) ---")
    for item in store.downloads {
        print(
            "  \(item.kind.rawValue) | gid=\(item.ariaGID ?? "-") | \(item.title) "
                + "| \(item.status.rawValue) | progress=\(String(format: "%.3f", item.progress)) "
                + "| speed=\(item.speed) | err=\(item.errorMessage ?? "-")"
        )
    }
    if tick >= 7 {
        timer.invalidate()
        TorrentEngine.shared.shutdown()
        exit(0)
    }
}
RunLoop.main.run()
