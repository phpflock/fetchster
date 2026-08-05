#!/bin/bash
# Regression test: a resumed HTTP download completing while the menu-bar
# popover is open used to crash the app (SwiftUI MenuBarExtra framework bug).
# Verifies the manual NSStatusItem + NSPopover build survives that path.
set -uo pipefail

UI=/tmp/uitest
PORT=8898
STATE="$HOME/Library/Application Support/Fetchster/downloads.json"
APP_BIN="$HOME/Documents/Fetchster/build/Fetchster.app/Contents/MacOS/Fetchster"

mkdir -p "$UI"

cleanup() {
  pkill -f resumeserver.py 2>/dev/null
  true
}
trap cleanup EXIT

# 1. Start the drop-after-N-bytes server (honors Range on resume).
cleanup
python3 "$UI/resumeserver.py" > "$UI/resume-crash-srv.log" 2>&1 &
sleep 1
if ! pgrep -f resumeserver.py > /dev/null; then
  echo "FAIL: resume server did not start"
  exit 1
fi

# 2. Make sure the app is running.
# Start from a clean slate: SIGKILL (so the terminate handler doesn't
# re-save stale in-memory items), remove previous test items/files, relaunch.
pkill -9 -f "Fetchster.app/Contents/MacOS/Fetchster" 2>/dev/null
sleep 1
python3 - "$STATE" <<'EOF'
import json, os, sys
p = sys.argv[1]
if os.path.exists(p):
    items = json.load(open(p))
    items = [i for i in items if i.get('title') != 'resume-test.bin']
    json.dump(items, open(p, 'w'), indent=2)
EOF
rm -f "$HOME/Downloads/resume-test.bin" "$HOME/Downloads/.resume-test.bin.part" 2>/dev/null
open "$HOME/Documents/Fetchster/build/Fetchster.app"
sleep 3
APP_PID=$(pgrep -f "Fetchster.app/Contents/MacOS/Fetchster" | head -1)
echo "app pid: $APP_PID"

# 3. Add the download through the control server (browser handoff path).
curl -s -X POST "http://127.0.0.1:8765/api/download" \
  -d '{"url":"http://127.0.0.1:8898/resume-test.bin","filename":"resume-test.bin"}' > "$UI/resume-crash-add.json"
cat "$UI/resume-crash-add.json"; echo

# 4. Wait for the server to drop the connection -> item fails with a partial.
FAILED=0
for _ in $(seq 1 20); do
  if python3 -c "
import json, os
p = '$STATE'
if not os.path.exists(p): raise SystemExit(1)
items = json.load(open(p))
hit = [i for i in items if i.get('title') == 'resume-test.bin']
if hit and hit[0].get('status') == 'failed': raise SystemExit(0)
raise SystemExit(1)
"; then
    FAILED=1
    break
  fi
  sleep 1
done
if [ "$FAILED" != "1" ]; then
  echo "FAIL: download never failed"
  tail -5 "$UI/resume-crash-srv.log"
  exit 1
fi
PARTIAL=$(ls -1 "$HOME"/Downloads/.resume-test.bin*.part 2>/dev/null | head -1)
echo "partial file: ${PARTIAL:-none}"
[ -n "$PARTIAL" ] || { echo "FAIL: no partial file kept"; exit 1; }
ls -l "$PARTIAL"

# 5. Open the popover and keep it open while the resume completes.
/tmp/uitest/click 976 16
sleep 1.5
/tmp/winlist | rg -q "Fetchster" || { echo "popover did not open"; exit 1; }

# 6. Find and click the Resume button via the accessibility tree.
AX=$(/tmp/axwalk "$APP_PID" 2>/dev/null | rg "Play" | head -1)
echo "resume button ax line: $AX"
COORDS=$(echo "$AX" | sed -E 's/.*@([0-9]+),([0-9]+) ([0-9]+)x([0-9]+).*/\1 \2 \3 \4/')
read -r X Y W H <<< "$COORDS"
if [ -z "${X:-}" ]; then
  echo "FAIL: resume button not found in AX tree"
  /tmp/axwalk "$APP_PID" 2>/dev/null | rg "AXButton" | head -20
  exit 1
fi
echo "clicking resume at $((X + W / 2)), $((Y + H / 2))"
/tmp/uitest/click $((X + W / 2)) $((Y + H / 2))

# 7. Wait for completion while the popover stays open.
DONE=0
for _ in $(seq 1 30); do
  if python3 -c "
import json, os
p = '$STATE'
if not os.path.exists(p): raise SystemExit(1)
items = json.load(open(p))
hit = [i for i in items if i.get('title') == 'resume-test.bin']
if hit and hit[0].get('status') == 'completed': raise SystemExit(0)
raise SystemExit(1)
"; then
    DONE=1
    break
  fi
  sleep 1
done

echo "--- server log ---"
cat "$UI/resume-crash-srv.log"

if [ "$DONE" != "1" ]; then
  echo "FAIL: resume never completed"
  exit 1
fi

# 8. Crash check: app must still be alive with the popover open.
if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "FAIL: app crashed when resumed download completed"
  exit 1
fi
echo "app alive after completion"

FINAL=$(ls -1 "$HOME"/Downloads/resume-test.bin* 2>/dev/null | head -1)
echo "final file: ${FINAL:-none}"
if [ -n "$FINAL" ] && [ "$(stat -f%z "$FINAL")" = "1048576" ]; then
  echo "PASS: resumed file is complete (1048576 bytes)"
else
  echo "FAIL: final file missing or wrong size"
  exit 1
fi

# 9. Clean up this test's state entry and files.
python3 - "$STATE" <<'EOF'
import json, os, sys
p = sys.argv[1]
items = json.load(open(p))
items = [i for i in items if i.get('title') != 'resume-test.bin']
json.dump(items, open(p, 'w'), indent=2)
EOF
rm -f "$HOME/Downloads/resume-test.bin" "$HOME/Downloads/.resume-test.bin.part"
echo "PASS: resume-completion no longer crashes the app"
