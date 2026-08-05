# Fetchster Capture — Firefox

Firefox port of the Fetchster browser extension (Manifest V3, Gecko 121+).

## Try it locally

1. Open `about:debugging#/runtime/this-firefox` in Firefox.
2. Click **Load Temporary Add-on** and select `manifest.json` from this folder.
3. The Fetchster macOS app must be running (it listens on 127.0.0.1:8765).

## Package for addons.mozilla.org (AMO)

Zip the contents of this folder with `manifest.json` at the archive root:

```sh
cd Extensions/firefox
zip -r ../../dist/fetchster-extension-firefox.zip . -x ".*"
```

Upload the zip at https://addons.mozilla.org/developers/. AMO signs the
extension (no developer key needed). Version bumps must match `manifest.json`.

## Notes

- The code is shared with the Chrome extension; only `manifest.json` differs
  (Gecko background event page + `browser_specific_settings`).
- YouTube/video grab uses the same yt-dlp path and works with Firefox's
  session via `--cookies-from-browser firefox`.
