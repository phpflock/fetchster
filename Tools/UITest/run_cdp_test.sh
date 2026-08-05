#!/bin/bash
# One-shot live test of the Chrome capture extension (CDP-driven).
# Verifies: plain links -> app + erased from Chrome history; download-attr,
# magnet, and torrent links -> intercepted before Chrome ever downloads.
set -uo pipefail
FOCUS="${FOCUS:-}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXT="$ROOT/Extensions/chrome"
UI=/tmp/uitest
SITE_DIR="$UI/downloads"
PORT=8898
CDP_PORT=9222
PROFILE="/tmp/chromium-test-$(date +%s)"
PROFILE_TAG="chromium-test-"

if [ -x "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" ]; then
  CHROME_BIN="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
elif [ -x "/Applications/Chromium.app/Contents/MacOS/Chromium" ]; then
  CHROME_BIN="/Applications/Chromium.app/Contents/MacOS/Chromium"
else
  CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
fi
echo "using: $CHROME_BIN"

mkdir -p "$SITE_DIR"
[ -f "$SITE_DIR/payload.bin" ] || python3 -c "open('$SITE_DIR/payload.bin','wb').write(b'x'*204800)"
printf 'not a real torrent %.0s' {1..300} > "$SITE_DIR/sintel.torrent"

cleanup() {
  pkill -f "$PROFILE_TAG" 2>/dev/null
  pkill -f servesite.py 2>/dev/null
  true
}
trap cleanup EXIT

pkill -f "$PROFILE_TAG" 2>/dev/null
pkill -f servesite.py 2>/dev/null
true

python3 "$UI/servesite.py" > "$UI/site.log" 2>&1 &
sleep 1

"$CHROME_BIN" \
  --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check \
  --disable-crash-reporter --disable-background-networking \
  --disable-extensions-except="$EXT" --load-extension="$EXT" \
  --remote-debugging-port=$CDP_PORT --remote-allow-origins=* \
  "http://127.0.0.1:$PORT/testpage.html" > "$UI/chrome.log" 2>&1 &

sleep 10

FOCUS="$FOCUS" /tmp/cdpvenv/bin/python "$ROOT/Tools/UITest/cdp_drive.py"

cleanup
sleep 2

echo ""
echo "=== isolated Chrome download history (expect zero rows) ==="
sqlite3 "$PROFILE/Default/History" "SELECT id, target_path, state, interrupt_reason FROM downloads;" 2>&1
echo "--- url chains ---"
sqlite3 "$PROFILE/Default/History" "SELECT * FROM downloads_url_chains;" 2>&1
