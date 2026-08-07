# Fetchster Safari (Web Extension)

The web-extension half of the Safari integration. It must be bundled inside a
macOS app (the containing app) — Safari doesn't allow standalone extensions.

## What it does

- Intercepts clicks on file download links (download attribute or common file
  extensions) and sends them to the Fetchster app.
- Right-click **Download with Fetchster** for any link or page.
- Optional video-page button (off by default) that sends a video ID to the
  Fetchster app.
- Magnet and `.torrent` links are intentionally not intercepted — the app
  handles those at the OS level.

## How it talks to the app

The extension uses Safari native messaging
(`browser.runtime.sendNativeMessage("com.fetchster.app", …)`). Messages are
received by `SafariWebExtensionHandler` in the containing app's Safari Web
Extension target (see `Safari/SafariWebExtensionHandler.swift`), which
forwards them to the Fetchster app's loopback server on `127.0.0.1:8765`.

## Files

- `manifest.json` — Safari-compatible manifest (background page, not service worker).
- `background.js` — context menus, native messaging, popup ping.
- `content.js` — file link interception + optional video button.
- `popup.html` / `popup.js` — capture toggle, video toggle, connection status.
- `icons/` — 16/32/48/128 icons.

See `Safari/README.md` for the Xcode project setup and signing steps.
