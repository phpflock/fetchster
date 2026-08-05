#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

"$PWD/Scripts/build.sh"

DEST="/Applications/Fetchster.app"
echo "==> Installing to $DEST"
rm -rf "$DEST"
cp -R "$PWD/build/Fetchster.app" "$DEST"
echo "Installed. Launch from /Applications/Fetchster.app"
