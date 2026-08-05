#!/bin/bash
# End-to-end video-grab test: plays a local MP4 in an isolated Brave with the
# extension, verifies the stream is reported to the app (icon pop + popover
# listing), then downloads it through the app and checks the bytes.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXT="$ROOT/Extensions/chrome"
UI=/tmp/uitest
SITE_DIR="$UI/downloads"
PORT=8898
CDP_PORT=9227
PROFILE="/tmp/video-test-$(date +%s)"
PROFILE_TAG="video-test-"
STATE="$HOME/Library/Application Support/Fetchster/downloads.json"

if [ -x "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" ]; then
  CHROME_BIN="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
elif [ -x "/Applications/Chromium.app/Contents/MacOS/Chromium" ]; then
  CHROME_BIN="/Applications/Chromium.app/Contents/MacOS/Chromium"
else
  CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
fi

cleanup() {
  pkill -f "$PROFILE_TAG" 2>/dev/null
  pkill -f servesite.py 2>/dev/null
  true
}
trap cleanup EXIT

cleanup
sleep 1

# 1. A real, small, playable MP4 plus a page that plays it.
ffmpeg -y -f lavfi -i "testsrc=size=320x240:rate=24" -t 3 -pix_fmt yuv420p \
  "$SITE_DIR/movie.mp4" > "$UI/video-ffmpeg.log" 2>&1
cat > "$SITE_DIR/videopage.html" <<'HTML'
<!doctype html>
<html><head><title>Video Test Page</title></head>
<body>
  <h1>Video test</h1>
  <video controls autoplay muted src="movie.mp4"></video>
</body></html>
HTML
echo "movie.mp4: $(stat -f%z "$SITE_DIR/movie.mp4") bytes"

# 2. Make sure the app is running (it must have the /api/media endpoint).
if ! pgrep -f "Fetchster.app/Contents/MacOS/Fetchster" > /dev/null; then
  open "$HOME/Documents/Fetchster/build/Fetchster.app"
  sleep 4
fi
APP_PID=$(pgrep -f "Fetchster.app/Contents/MacOS/Fetchster" | head -1)
echo "app pid: $APP_PID"

python3 "$UI/servesite.py" > "$UI/video-site.log" 2>&1 &
sleep 1

# 3. Launch isolated Brave with the extension on the video page.
"$CHROME_BIN" \
  --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check \
  --disable-crash-reporter --disable-background-networking \
  --disable-extensions-except="$EXT" --load-extension="$EXT" \
  --remote-debugging-port=$CDP_PORT --remote-allow-origins=* \
  "http://127.0.0.1:$PORT/videopage.html" > "$UI/video-chrome.log" 2>&1 &

sleep 12

# 4. The extension should have reported the stream to the app.
curl -s "http://127.0.0.1:8765/api/media" > "$UI/video-media.json"
cat "$UI/video-media.json"; echo
python3 - "$UI/video-media.json" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
media = data.get("media", [])
streams = [s for m in media for s in m.get("streams", [])]
print("streams:", len(streams))
assert any("movie.mp4" in s.get("url", "") for s in streams), "movie.mp4 not detected"
hit = next(s for s in streams if "movie.mp4" in s.get("url", ""))
if hit.get("mime"):
    assert hit.get("mime", "").startswith("video/"), "wrong mime: " + hit.get("mime", "")
print("PASS: video stream detected (mime:", hit.get("mime") or "n/a", "size:", hit.get("size") or "n/a", ")")
EOF

# 5. The popover should list it under "Video detected" with a download button.
/tmp/uitest/click 976 16
sleep 1.5
MEDIA_ROW=$(/tmp/axwalk "$APP_PID" 2>/dev/null | rg "Video detected|MP4|movie" | head -3)
echo "media rows: $MEDIA_ROW"
echo "$MEDIA_ROW" | rg -q "Video detected" || { echo "FAIL: popover missing Video detected"; exit 1; }
DL_BTN=$(/tmp/axwalk "$APP_PID" 2>/dev/null | rg "Arrow Down Circle" | head -1)
echo "download button: ${DL_BTN:-NOT FOUND}"
echo "$DL_BTN" | rg -q "Arrow Down Circle" || { echo "FAIL: no per-stream download button"; exit 1; }
CO=$(echo "$DL_BTN" | sed -E 's/.*@([0-9]+),([0-9]+) ([0-9]+)x([0-9]+).*/\1 \2 \3 \4/')
read -r BX BY BW BH <<< "$CO"
/tmp/uitest/click $((BX + BW / 2)) $((BY + BH / 2))
sleep 1

# 6. The download should land in the app's folder.
DONE=0
for _ in $(seq 1 30); do
  if python3 -c "
import json, os
p = '$STATE'
items = json.load(open(p))
hit = [i for i in items if 'movie.mp4' in i.get('title','')]
if hit and hit[0].get('status') in ('completed','downloading','failed'):
    print('item:', hit[0]['status'], hit[0].get('downloadedBytes'))
    raise SystemExit(0)
raise SystemExit(1)
"; then
    DONE=1
    break
  fi
  sleep 1
done
[ "$DONE" = "1" ] || { echo "FAIL: video download never started"; exit 1; }

sleep 4
python3 - <<'EOF'
import glob, hashlib, os
src = open('/tmp/uitest/downloads/movie.mp4','rb').read()
matches = glob.glob(os.path.expanduser('~/Downloads/movie.mp4*'))
assert matches, 'no downloaded movie file'
dst = open(matches[0], 'rb').read()
print('downloaded:', matches[0], len(dst), 'bytes')
assert src == dst, 'content mismatch'
print('PASS: video grabbed and downloaded byte-identical')
EOF

# 7. Clean up this test's item + file.
python3 - "$STATE" <<'EOF'
import json, os, sys
p = sys.argv[1]
items = json.load(open(p))
items = [i for i in items if 'movie.mp4' not in i.get('title','')]
json.dump(items, open(p, 'w'), indent=2)
EOF
rm -f "$HOME"/Downloads/movie.mp4* 2>/dev/null
/tmp/uitest/click 976 16
echo "PASS: video grab works end to end"
