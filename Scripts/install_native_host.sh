#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

EXTENSION_ID="${1:-}"
if [ -z "$EXTENSION_ID" ]; then
  echo "Usage: $0 <extension-id>"
  echo "Load the extension at chrome://extensions and copy its ID."
  exit 1
fi

HOST_NAME="com.fetchster.app"
SUPPORT_DIR="$HOME/Library/Application Support/Fetchster/NativeHost"
BIN_PATH="$SUPPORT_DIR/FetchsterNativeHost"
MANIFEST_PATH="$SUPPORT_DIR/manifest.json"

echo "==> Building native messaging host..."
swift build -c release --arch arm64 --product FetchsterNativeHost
HOST_BIN="$(swift build -c release --arch arm64 --show-bin-path)/FetchsterNativeHost"

echo "==> Installing host binary..."
mkdir -p "$SUPPORT_DIR"
cp "$HOST_BIN" "$BIN_PATH"
chmod +x "$BIN_PATH"

cat > "$MANIFEST_PATH" <<JSON
{
  "name": "$HOST_NAME",
  "description": "Fetchster native messaging host",
  "path": "$BIN_PATH",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON

install_manifest() {
  local dir="$1"
  if [ -d "$(dirname "$dir")" ]; then
    mkdir -p "$dir"
    cp "$MANIFEST_PATH" "$dir/$HOST_NAME.json"
    echo "Registered: $dir/$HOST_NAME.json"
  fi
}

install_manifest "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
install_manifest "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
install_manifest "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"

echo ""
echo "Native messaging host installed for extension: $EXTENSION_ID"
echo "Reload the extension, then open its popup to check the connection."
