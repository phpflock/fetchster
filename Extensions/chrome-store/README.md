# Fetchster Capture (Chrome Web Store)

This is the Web Store version of the Fetchster browser extension. It hands
browser downloads over to the Fetchster macOS menu bar app using Chrome
**native messaging** — no host permissions and no open network port.

## What it does

- **Captures downloads automatically** (toggle in the popup). It adapts to the
  browser's save behavior:
  - *"Ask where to save" OFF*: the download is handed to the app immediately —
    no dialog, straight into the app's Downloads folder.
  - *"Ask where to save" ON*: the native save panel appears and the extension
    waits. When you pick a folder and click **Save**, the app downloads to
    that exact location. Clicking **Cancel** downloads nothing.
  The browser's own copy is cancelled and erased from the shelf/history. If
  the app is not running, the browser downloads normally.
- **Magnet and torrent handling**: the Fetchster app registers itself as the
  system handler for `magnet:` links and `.torrent` files, so those downloads
  are handled by the app even without any page scripts.
- **Right-click any link** → *Download with Fetchster* — works for regular
  files, `.torrent` URLs, and `magnet:` links.

## What it does not do

- It does not inject scripts into web pages or read page content, network
  requests, or response bodies.
- It does not request access to cookies, history, or browsing activity.
- It only sends the download URL (and the browser's User-Agent) to the Fetchster
  app running on your own machine over the loopback interface.

## Permissions

- `nativeMessaging` — to talk to the Fetchster app on your own Mac.
- `downloads` — to hand off and cancel browser downloads.
- `contextMenus` — for the "Download with Fetchster" right-click menu.
- `storage` — to remember the capture toggle.
- `notifications` — to confirm a download was added.

## Setting up the native messaging host (for local testing)

1. Build and launch the app (`./Scripts/run.sh`).
2. Load this folder at `chrome://extensions` (Developer mode → Load unpacked).
3. Copy the extension ID shown on the extension card.
4. Register the native messaging host:

   `./Scripts/install_native_host.sh <extension-id>`

5. Reload the extension and open its popup — it should show
   **Server: connected ✓** when the Fetchster app is running.

The install script registers the host for Chrome, Edge, and Brave if they are
installed. The manifest and helper binary live in
`~/Library/Application Support/Fetchster/NativeHost`.
