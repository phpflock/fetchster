# Safari extension — Xcode setup

The code is split into two pieces:

- `Extensions/safari/` — the web extension (manifest, scripts, popup, icons).
- `Safari/SafariWebExtensionHandler.swift` — the native bridge that receives
  extension messages and forwards them to the Fetchster app on `127.0.0.1:8765`.

## Create the Xcode project (one time)

1. Xcode → File → New → Project → macOS → **App** (AppKit or SwiftUI), name it
   `Fetchster Safari`.
2. File → New → Target → macOS → **Safari Web Extension**, name it
   `FetchsterSafariExtension`. Xcode creates the app target plus an extension
   target with `SafariWebExtensionHandler.swift` and a `Resources/` folder.
3. Replace the generated `Resources/` contents with everything in
   `Extensions/safari/` (manifest.json, background.js, content.js, popup.*,
   icons/).
4. Replace the generated `SafariWebExtensionHandler.swift` with
   `Safari/SafariWebExtensionHandler.swift`.
5. Select the extension target → **Signing & Capabilities** → choose your Team.
   A free personal team works for local testing; distribution needs a paid
   Apple Developer account ($99/year).
6. Add this to the **extension target's** Info.plist so its URLSession can talk
   to the app over plain localhost HTTP:

   ```xml
   <key>NSAppTransportSecurity</key>
   <dict>
     <key>NSAllowsLocalNetworking</key>
     <true/>
   </dict>
   ```

   If you enable App Sandbox for App Store distribution, also add the
   `com.apple.security.network.client` entitlement to the extension target.

## Run and enable locally

1. Build and run the app (⌘R). The template includes an
   “Open Safari Extensions Preferences” button.
2. Safari → Settings → Advanced → enable **Show features for web developers**.
3. Safari → Develop → **Allow Unsigned Extensions** (needed until you have a
   proper paid-team signature).
4. In Safari Extensions settings, enable **FetchsterSafariExtension**.
5. Make sure the Fetchster app is running, then use the extension — the popup
   should show **Fetchster: connected ✓**.

## How messages flow

```
Safari page → content.js → background.js
  → browser.runtime.sendNativeMessage("com.fetchster.app", …)
  → SafariWebExtensionHandler (app extension process)
  → http://127.0.0.1:8765/api/… → Fetchster app
```

## Distribution later (paid account)

- **Mac App Store**: sandboxed build, App Store review. The file-download
  extension should pass; the video-page button may be rejected, so keep it
  disabled in the App Store build.
- **Direct download**: Developer ID signing + notarization (macOS 15.4+ /
  Safari 18.4+). This path can include the video feature.
