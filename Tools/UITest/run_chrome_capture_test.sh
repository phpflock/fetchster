#!/bin/bash
# One-shot live test of the Chrome capture extension against the running app.
# Launches an isolated Chrome with the extension and a local test page, clicks
# the download links, and verifies what lands in the app vs. Chrome.
#
# Requirements: Fetchster running (control server on 127.0.0.1:8765),
# /tmp/uitest/click, /tmp/uitest/keys, /tmp/uitest/type, /tmp/axdump built.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXT="$ROOT/Extensions/chrome"
UI=/tmp/uitest
SITE_DIR="$UI/downloads"
PORT=8898
PROFILE=/tmp/chrome-test5
APP_STATE="$HOME/Library/Application Support/Fetchster/downloads.json"

mkdir -p "$SITE_DIR"
[ -f "$SITE_DIR/payload.bin" ] || python3 -c "open('$SITE_DIR/payload.bin','wb').write(b'x'*204800)"
printf 'not a real torrent %.0s' {1..300} > "$SITE_DIR/sintel.torrent"

cleanup() {
  pkill -f "chrome-test5" 2>/dev/null
  pkill -f servesite.py 2>/dev/null
  true
}
trap cleanup EXIT

pkill -f "chrome-test5" 2>/dev/null
pkill -f servesite.py 2>/dev/null
true

python3 "$UI/servesite.py" > "$UI/site.log" 2>&1 &
sleep 1

"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check \
  --disable-crash-reporter --disable-background-networking \
  --disable-extensions-except="$EXT" --load-extension="$EXT" \
  "http://127.0.0.1:$PORT/testpage.html" > "$UI/chrome.log" 2>&1 &
sleep 9

main_pid() {
  pgrep -f "chrome-test5" | while read -r p; do
    case "$(ps -o command= -p "$p")" in *--type=*) ;; *) echo "$p"; break ;; esac
  done
}
MAIN="$(main_pid)"
echo "chrome main pid: $MAIN"

state_titles() {
  python3 -c "
import json, os
p = '$APP_STATE'
d = json.load(open(p)) if os.path.exists(p) else []
for i in d: print(' ', i['kind'], '|', i['title'], '|', i['status'])
"
}

click_text() {
  local query="$1"
  local tries="${2:-8}"
  for _ in $(seq 1 "$tries"); do
    local out
    out="$(/tmp/axdump "$MAIN" --click "$query" 2>&1)"
    if [[ "$out" == clicked* ]]; then
      echo "  clicked: $query ($out)"
      return 0
    fi
    sleep 1
  done
  echo "  FAILED to click: $query"
  return 1
}

go_to() {
  click_text "Address and search bar" || return 1
  sleep 0.4
  /tmp/uitest/type "$1"
  /tmp/uitest/keys 36
  sleep 2.5
}

echo "=== links visible on the page ==="
/tmp/axdump "$MAIN" | grep -i -E "AXLink|Plain link|download attribute|Magnet|Torrent" | head -8

echo ""
echo "=== TEST 1: plain file link (no download attr) ==="
click_text "Plain link"
sleep 5
echo "app state after plain click:"; state_titles
go_to "chrome://downloads"
echo "chrome://downloads content:"; /tmp/axdump "$MAIN" | grep -i -E "cancelled|failed|payload|No downloads|downloads list" | head -6
go_to "http://127.0.0.1:$PORT/testpage.html"

echo ""
echo "=== TEST 2: link with download attribute ==="
click_text "download attribute"
sleep 5
echo "app state after attr click:"; state_titles
go_to "chrome://downloads"
echo "chrome://downloads content:"; /tmp/axdump "$MAIN" | grep -i -E "cancelled|failed|attr-file|payload|No downloads|downloads list" | head -6
go_to "http://127.0.0.1:$PORT/testpage.html"

echo ""
echo "=== TEST 3: magnet link ==="
click_text "Magnet link"
sleep 4
echo "app state after magnet click:"; state_titles
echo "chrome windows (expect 1, no external-protocol dialog): $(/tmp/axdump "$MAIN" | grep -c 'AXWindow')"
go_to "http://127.0.0.1:$PORT/testpage.html"

echo ""
echo "=== TEST 4: torrent link ==="
click_text "Torrent link"
sleep 5
echo "app state after torrent click:"; state_titles
go_to "chrome://downloads"
echo "final chrome://downloads content:"; /tmp/axdump "$MAIN" | grep -i -E "cancelled|failed|attr-file|payload|sintel|No downloads|downloads list" | head -6

echo ""
echo "=== DONE ==="
