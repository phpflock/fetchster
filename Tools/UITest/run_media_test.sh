#!/bin/bash
# End-to-end HLS + DASH grab test: a page fetches an HLS playlist and a DASH
# manifest, the extension reports them, and the app downloads both into
# playable files (ffmpeg-based assembly).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXT="$ROOT/Extensions/chrome"
UI=/tmp/uitest
MEDIA_DIR="$UI/downloads/media"
PORT=8898
CDP_PORT=9228
PROFILE="/tmp/media-test-$(date +%s)"
PROFILE_TAG="media-test-"
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

# 1. Media fixtures: DASH + HLS streams from the same test source.
mkdir -p "$MEDIA_DIR"
if [ ! -f "$MEDIA_DIR/test.mpd" ]; then
  /opt/homebrew/bin/ffmpeg -y -v error -f lavfi -i "testsrc=size=320x240:rate=24" \
    -f lavfi -i "sine=frequency=440" -t 8 -c:v libx264 -pix_fmt yuv420p -c:a aac \
    -f dash "$MEDIA_DIR/test.mpd"
fi
if [ ! -f "$MEDIA_DIR/test.m3u8" ]; then
  /opt/homebrew/bin/ffmpeg -y -v error -f lavfi -i "testsrc=size=320x240:rate=24" \
    -f lavfi -i "sine=frequency=440" -t 8 -c:v libx264 -pix_fmt yuv420p -c:a aac \
    -f hls "$MEDIA_DIR/test.m3u8"
fi

cat > "$UI/downloads/mediapage.html" <<'HTML'
<!doctype html>
<html><head><title>Media Test Page</title></head>
<body>
<h1>Media test</h1>
<script>
fetch('media/test.mpd').then(r => r.text()).then(() => {});
fetch('media/test.m3u8').then(r => r.text()).then(() => {});
</script>
</body></html>
HTML

# 2. Restart the app from a clean state (SIGKILL so stale in-memory media
#    items aren't re-saved; clear any previous media items from disk).
pkill -9 -f "Fetchster.app/Contents/MacOS/Fetchster" 2>/dev/null
sleep 1
python3 - "$STATE" <<'EOF'
import json, os, sys
p = sys.argv[1]
if os.path.exists(p):
    items = json.load(open(p))
    items = [i for i in items if i.get('kind') != 'media']
    json.dump(items, open(p, 'w'), indent=2)
EOF
rm -f "$HOME"/Downloads/test*.mp4 "$HOME"/Downloads/test*.mkv 2>/dev/null
open "$HOME/Documents/Fetchster/build/Fetchster.app"
sleep 4
APP_PID=$(pgrep -f "Fetchster.app/Contents/MacOS/Fetchster" | head -1)
echo "app pid: $APP_PID"

python3 "$UI/servesite.py" > "$UI/media-site.log" 2>&1 &
sleep 1

"$CHROME_BIN" \
  --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check \
  --disable-crash-reporter --disable-background-networking \
  --disable-extensions-except="$EXT" --load-extension="$EXT" \
  --remote-debugging-port=$CDP_PORT "--remote-allow-origins=*" \
  "http://127.0.0.1:$PORT/mediapage.html" > "$UI/media-chrome.log" 2>&1 &

sleep 12

# 3. Both manifests should be reported with correct kinds.
curl -s "http://127.0.0.1:8765/api/media" > "$UI/media-detected.json"
cat "$UI/media-detected.json"; echo
python3 - "$UI/media-detected.json" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
streams = [s for m in data.get("media", []) for s in m.get("streams", [])]
kinds = sorted(s.get("kind", "") for s in streams)
urls = " ".join(s.get("url", "") for s in streams)
assert "dash" in kinds, f"no dash stream: {kinds}"
assert "hls" in kinds, f"no hls stream: {kinds}"
assert "test.mpd" in urls and "test.m3u8" in urls
print("PASS: extension reported HLS + DASH streams")
EOF

# 4. Popover lists them; download both.
/tmp/uitest/click 976 16
sleep 1.5
echo "--- media rows ---"
/tmp/axwalk "$APP_PID" 2>/dev/null | rg "Video detected|HLS|DASH" | head -6
/tmp/axwalk "$APP_PID" 2>/dev/null | rg "Video detected" | head -1 || { echo "FAIL: no Video detected section"; exit 1; }

for KIND in DASH HLS; do
  BTN=$(/tmp/axwalk "$APP_PID" 2>/dev/null | rg "Arrow Down Circle" | head -1)
  [ -n "$BTN" ] || { echo "FAIL: no download button for $KIND"; exit 1; }
  CO=$(echo "$BTN" | sed -E 's/.*@([0-9]+),([0-9]+) ([0-9]+)x([0-9]+).*/\1 \2 \3 \4/')
  read -r BX BY BW BH <<< "$CO"
  echo "downloading $KIND at $((BX + BW / 2)), $((BY + BH / 2))"
  /tmp/uitest/click $((BX + BW / 2)) $((BY + BH / 2))
  sleep 1
done

# 5. Both media downloads should complete.
for _ in $(seq 1 60); do
  DONE=$(python3 -c "
import json, os
items = json.load(open('$STATE'))
media = [i for i in items if i.get('kind') == 'media']
done = [i for i in media if i.get('status') in ('completed', 'failed')]
print(len(done), len(media))
")
  read -r DONE_CNT TOTAL_CNT <<< "$DONE"
  [ "$DONE_CNT" = "2" ] && [ "$TOTAL_CNT" = "2" ] && break
  sleep 1
done
echo "media items done: $DONE_CNT / $TOTAL_CNT"
[ "$DONE_CNT" = "2" ] || { echo "FAIL: media downloads did not complete"; exit 1; }

python3 - "$STATE" <<'EOF'
import json, os, sys
items = json.load(open(sys.argv[1]))
for i in items:
    if i.get('kind') == 'media':
        print(' ', i.get('status'), i.get('title'), '|', i.get('errorMessage') or '')
        assert i.get('status') == 'completed', f"media item failed: {i.get('errorMessage')}"
EOF

# 6. The assembled files must be real playable media.
for f in "$HOME"/Downloads/*.mp4; do
  case "$f" in *media*|*Media*|*test*) continue;; esac
done
python3 - <<'EOF'
import glob, os, subprocess
outs = [p for p in glob.glob(os.path.expanduser('~/Downloads/test*.mp4'))
        + glob.glob(os.path.expanduser('~/Downloads/test*.mkv')) if 'media' not in p]
assert outs, 'no assembled media outputs'
for p in outs:
    r = subprocess.run(['/opt/homebrew/bin/ffprobe','-v','error','-show_entries','stream=codec_type',
                        '-show_entries','format=duration', p], capture_output=True, text=True)
    assert 'codec_type=video' in r.stdout, f'{p} not a video: {r.stdout} {r.stderr}'
    print('PASS: playable output', os.path.basename(p), '->', ' '.join(r.stdout.split()))
EOF

# 7. Cleanup.
python3 - "$STATE" <<'EOF'
import json, os, sys
p = sys.argv[1]
items = json.load(open(p))
items = [i for i in items if i.get('kind') != 'media']
json.dump(items, open(p, 'w'), indent=2)
EOF
rm -f "$HOME"/Downloads/test*.mp4 "$HOME"/Downloads/test*.mkv 2>/dev/null
/tmp/uitest/click 976 16
echo "PASS: HLS and DASH grab work end to end"
