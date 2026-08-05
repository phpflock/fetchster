#!/bin/bash
# Verifies the "ask where to save" flow end-to-end: click a download link, the
# native save panel appears, and only after clicking Save does the app start
# downloading to the chosen location. Clicking Cancel must download nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXT="$ROOT/Extensions/chrome"
UI=/tmp/uitest
SITE_DIR="$UI/downloads"
PORT=8898
CDP_PORT=9226
PROFILE="/tmp/brave-prompt-$(date +%s)"
PROFILE_TAG="brave-prompt-"
CHROME="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
APP_STATE="$HOME/Library/Application Support/Fetchster/downloads.json"

mkdir -p "$SITE_DIR"
[ -f "$SITE_DIR/payload.bin" ] || python3 -c "open('$SITE_DIR/payload.bin','wb').write(b'x'*204800)"

cleanup() {
  pkill -f "$PROFILE_TAG" 2>/dev/null
  pkill -f servesite.py 2>/dev/null
  true
}
trap cleanup EXIT

cleanup
sleep 1

# Create the profile, then enable "ask where to save".
"$CHROME" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check \
  --disable-crash-reporter about:blank > "$UI/prompt-probe.log" 2>&1 &
PROBE_PID=$!
sleep 6
kill "$PROBE_PID" 2>/dev/null
for _ in $(seq 1 10); do
  pgrep -f "$PROFILE_TAG" > /dev/null || break
  sleep 1
done

python3 - <<EOF
import json
path = "$PROFILE/Default/Preferences"
with open(path) as f:
    prefs = json.load(f)
prefs.setdefault("download", {})["prompt_for_download"] = True
with open(path, "w") as f:
    json.dump(prefs, f)
print("prompt_for_download =", prefs["download"]["prompt_for_download"])
EOF

python3 "$UI/servesite.py" > "$UI/site.log" 2>&1 &
sleep 1
"$CHROME" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check \
  --disable-crash-reporter --disable-background-networking \
  --disable-extensions-except="$EXT" --load-extension="$EXT" \
  --remote-debugging-port=$CDP_PORT "--remote-allow-origins=*" \
  "http://127.0.0.1:$PORT/testpage.html" > "$UI/prompt.log" 2>&1 &

cdp_ready=0
for _ in $(seq 1 20); do
  if curl -s -m 2 "http://127.0.0.1:$CDP_PORT/json/version" > /dev/null 2>&1; then
    cdp_ready=1
    break
  fi
  sleep 1
done
echo "cdp ready: $cdp_ready"

MAIN="$(ps -axo pid=,command= | grep "$PROFILE_TAG" | grep -v "grep" | grep -v -- "--type=" | head -1 | awk '{print $1}')"
echo "brave main pid: $MAIN"

click_and_wait_for_panel() {
  CLICK_ONLY=plain CDP_PORT=$CDP_PORT /tmp/cdpvenv/bin/python "$ROOT/Tools/UITest/cdp_drive.py" 2>&1 | tail -1
  for _ in $(seq 1 10); do
    sheet_count="$(/tmp/axdump "$MAIN" 2>&1 | grep -c "AXSheet" || true)"
    if [ "$sheet_count" -ge 1 ]; then
      echo "save panel visible (AXSheet count=$sheet_count)"
      return 0
    fi
    sleep 1
  done
  echo "PANEL DID NOT APPEAR"
  return 1
}

echo "=== TEST 1: click download -> panel -> Save ==="
click_and_wait_for_panel
/tmp/axdump "$MAIN" --click-exact "Save" 2>&1 || echo "Save button not found"
sleep 7
echo "--- app state after Save ---"
python3 -c "
import json, os
d = json.load(open('$APP_STATE')) if os.path.exists('$APP_STATE') else []
for i in d[:2]:
    print(' ', i['title'], '|', i['status'], '|', i.get('destinationURL', '-'))
"

echo "=== TEST 2: click download -> panel -> Cancel ==="
before="$(python3 -c "import json,os;print(len(json.load(open('$APP_STATE'))))")"
click_and_wait_for_panel
/tmp/axdump "$MAIN" --click-exact "Cancel" 2>&1 || echo "Cancel button not found"
sleep 3
after="$(python3 -c "import json,os;print(len(json.load(open('$APP_STATE'))))")"
echo "app items before=$before after=$after (must be equal)"

cleanup
sleep 4
echo "=== browser download history ==="
sqlite3 "$PROFILE/Default/History" "SELECT id, target_path, state, interrupt_reason FROM downloads;" 2>&1
