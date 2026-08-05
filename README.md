# Fetchster

A native macOS menu-bar download manager. It lives in the top bar (no Dock icon,
no full window), with a dropdown that shows every download's progress, speed,
ETA, and status — in the same look and feel as native macOS menu bar menus.

Website: <https://phpflock.github.io/fetchster/>

## Features

- **Menu bar only** — a native `NSStatusItem` + `NSPopover` in the top bar,
  `LSUIElement` (no Dock icon), no main window.
- **Add any link** — click the **+** in the popover header, paste a URL, and it
  starts downloading. Any file type is supported.
- **All download types**
  - Regular HTTP/HTTPS/FTP files via native `URLSession` (with byte-range
    pause/resume: interrupted downloads keep a `.part` file and resume from
    the exact byte with `Range: bytes=N-`, plus queued concurrency control).
  - `.torrent` URLs and files, plus `magnet:` links, via the
    [aria2](https://aria2.github.io/) engine (DHT, peer exchange, magnet
    metadata). Completed torrents keep seeding, and rows show seeders/peers,
    up/down speed, and share ratio. Right-click a torrent for **Update
    Trackers** (re-announce / add public trackers), **Copy Magnet Link**,
    **Copy Info Hash**, **Stop Seeding**, and **Remove & Delete Files**.
  - **YouTube and other yt-dlp sites** — per-quality rows (2160p down
    to audio-only) via [yt-dlp](https://github.com/yt-dlp/yt-dlp), merged into
    a single MP4 with ffmpeg. Works with your logged-in browser session.
- **Browser capture (Chrome/Edge/Brave/Firefox)** — the companion extension
  hands downloads to the app with the browser's exact request context
  (User-Agent, cookies, Referer, all headers), so servers see a real browser
  request. Right-click *Download with Fetchster* works for links and `magnet:`
  URLs too. The extension lives in `Extensions/chrome` and `Extensions/firefox`.
- **Video grab** — when a page plays a video, the extension
  reports the streams and the menu bar icon "pops". Open the popover for a
  **Video detected** section listing every format — direct files (MP4, WebM,
  MKV, …) with their size, HLS playlists, and DASH manifests expanded into
  per-quality rows (e.g. "1080p MP4"). Click one and it downloads with the
  page's headers; HLS and DASH streams are assembled with ffmpeg, and YouTube
  videos are listed/downloaded with yt-dlp. Blob/DRM streams aren't grab-able.
- **Parallel to Apple's downloads** — Fetchster runs its own download system
  with its own list and folder, independent of the Downloads dock stack:
  - Browsers (Chrome/Brave/Edge/Firefox): true interception via the extension,
    no save dialogs — files land straight in the app's Downloads folder.
  - Magnet links anywhere on the system: Fetchster registers as the handler
    for `magnet:` and opens `.torrent` files, so clicking a magnet in any app
    routes it here (one-time "Always allow" prompt).
- **Native touches**
  - Live progress bars, speed, ETA, and file sizes in the dropdown.
  - Icon pop + media list when a playing video is detected on a page.
  - Pause / resume / remove from the row or a context menu.
  - Torrent details: seeders, peers, upload speed, and ratio while seeding.
  - Reveal in Finder, open the download folder.
  - Sleep timer (☕) — keep the Mac awake for 30 min / 1 hr / 2 hrs / 6 hrs
    (runs `caffeinate`), with a live countdown in the header.
  - Completion notifications.
  - Launch at login.
  - Downloads list persists across relaunches; interrupted HTTP downloads are
    restored as paused (resume later), torrents are re-added automatically.
- **Settings** — download folder, concurrent download count, notifications,
  launch at login, plus on-demand engines:
  - **Torrent downloads** — downloads and starts the aria2 engine.
  - **Media downloads** — downloads yt-dlp + ffmpeg for YouTube, HLS & DASH.
  Engines are fetched only when enabled, so the app bundle stays small:
  - yt-dlp and ffmpeg come from their official sources automatically
    (yt-dlp's GitHub release, ffmpeg.org's recommended macOS builds), so
    updates arrive with upstream releases.
  - aria2 publishes no official macOS binary; upload `dist/aria2.zip`
    (aria2c + its dylibs) as a GitHub release and set the `engine.aria2.url`
    UserDefaults key to its download URL (see `dist/README-upload.md`).
    Per-engine overrides: `engine.ytdlp.url`, `engine.ffmpeg.url`.

## Requirements

- macOS 13 or later (built and tested on Apple Silicon).
- Xcode Command Line Tools (Swift).

No extra installation is needed: the app bundles `aria2c` (with its relinked
runtime libraries) for torrents, and a static `ffmpeg` for HLS/DASH media
assembly — both inside the app bundle, so nothing needs to be installed.

## Build & run

```sh
./Scripts/build.sh   # produces build/Fetchster.app
./Scripts/run.sh     # build + launch
./Scripts/install.sh # build + copy to /Applications (needed for Launch at Login)
```

Then click the download arrow in the menu bar. The **+** button accepts:

- `https://example.com/file.zip`
- `magnet:?xt=urn:btih:…&dn=…`
- a `.torrent` URL, or "Torrent File…" to pick a local `.torrent`

## Browser capture

The app runs a small loopback server on `127.0.0.1:8765`. Install the
extension from [Extensions/chrome](Extensions/chrome) (`chrome://extensions` →
Developer mode → Load unpacked). Then:

- Clicking a download link sends it to Fetchster with the page's headers;
  the browser's copy is cancelled instantly (no save dialog appears) and the
  file lands in Fetchster's Downloads folder. If the app isn't running, the
  browser downloads normally.
- Right-click any link → **Download with Fetchster** (works for `magnet:`).
- Toggle capture on/off from the extension popup, which also shows whether the
  app's server is reachable.

### Why not "hijack Apple's download system" entirely?

macOS has no public API to intercept another app's file writes or downloads —
Apple's "download system" is just the Downloads folder plus each app's own
download UI. True system-wide interception would require a network extension /
transparent proxy with HTTPS interception (an installed root certificate,
admin approval, and a paid Apple developer account), which breaks
certificate-pinned apps and is generally not worth it. So Fetchster runs as
a parallel system: it owns its own downloads (browsers, magnets, torrents),
while Apple's Downloads folder remains untouched.

The app also registers the `fetchster://` URL scheme, so links like
`fetchster://add?url=<encoded-url>` add a download directly (useful for
bookmarklets or other launchers). The default User-Agent (settable in
Settings) is a modern Chrome-on-macOS string, and is used whenever the browser
doesn't supply one.

## How it works

- `HTTPDownloadManager` — `URLSessionDownloadTask`-based downloads with resume
  data, speed sampling, and per-host connection limits.
- `TorrentEngine` — launches the bundled `aria2c` with its JSON-RPC server
  enabled on `127.0.0.1:6800`, and polls active/waiting/stopped downloads once
  per second to feed the same UI. The engine starts at app launch so the
  Settings status is always truthful.
- `DownloadStore` — single source of truth; persists the list to
  `~/Library/Application Support/Fetchster/downloads.json` and resume data to
  `…/resume/`.
- `LocalControlServer` — the loopback JSON API used by the browser extension
  (`/api/ping`, `/api/status`, `/api/download`).
- The app is ad-hoc code-signed so it runs locally without a developer account.

## Development: headless smoke test

`Tools/TestHarness/main.swift` exercises the real download engines (URLSession
downloads, aria2 RPC, torrent/magnet handling, persistence) without the UI:

```sh
swiftc -O -o /tmp/idltest/harness \
  Sources/Fetchster/Models.swift \
  Sources/Fetchster/FileUtils.swift \
  Sources/Fetchster/HTTPDownloadManager.swift \
  Sources/Fetchster/TorrentEngine.swift \
  Sources/Fetchster/DownloadStore.swift \
  Tools/TestHarness/main.swift
```

Wrap the binary in a minimal `.app` bundle first, since `UserNotifications`
requires a bundle to be present.

## Roadmap ideas

- Speed-limit / schedule controls.
- Firefox and Safari versions of the capture extension.
- Global hotkey to show the menu.
- Per-download "open folder when done".
