# Fetchster Capture (Chrome / Edge / Brave)

Hands downloads over to the Fetchster menu bar app with the browser's full
request context — User-Agent, cookies, Referer, and all headers — so servers
see an ordinary browser request.

## Install

1. Build and launch the app (`./Scripts/run.sh`) — it listens on
   `127.0.0.1:8765`.
2. Open `chrome://extensions` (or `edge://extensions`), enable **Developer
   mode**, click **Load unpacked**, and choose this folder
   (`Extensions/chrome`).
3. Use the toolbar popup to confirm the server shows **connected**.

After updating the extension files (e.g. pulling new code), click the
**reload** button on the extension card in `chrome://extensions` so Chrome
loads the new files.

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
- **Never reaches the browser downloader**: `magnet:` links, `.torrent` links,
  and links with a `download` attribute are intercepted at the click level, so
  no browser download item is created at all.
- **Right-click any link** → *Download with Fetchster* — works for regular
  files, `.torrent` URLs, and `magnet:` links.
- **Video grab** — when a page plays a video, the extension reports it to the
  app: the menu bar icon pops, and the app's dropdown shows the detected
  streams — direct files (MP4/WebM/MKV/MOV/…) with format + size, HLS
  playlists, and DASH manifests expanded into per-quality rows (including
  YouTube). Click one to download with the page's exact headers (Referer,
  cookies, UA). Detection watches media network responses (`webRequest`),
  `<video>` elements, and the page's resource list (so cold-start fetches are
  caught too). Blob/DRM streams aren't grab-able.

## Notes

- The extension talks only to `http://127.0.0.1:8765` (loopback). Any local
  process could talk to that port; it only accepts the documented JSON schema,
  and it never exposes the app to other machines.
- Blob/data URLs can't be re-downloaded by the app and are left to the browser.
- Chrome's Manifest V3 doesn't allow blocking `webRequest`, so an arbitrary
  file link is registered by the browser before any extension hook fires. The
  item is handed off, cancelled, and erased immediately — it may flash briefly.
  (Firefox still allows blocking web requests, so a Firefox version could
  prevent arbitrary downloads entirely.)
