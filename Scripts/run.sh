#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

"$PWD/Scripts/build.sh"
open "$PWD/build/Fetchster.app"
echo "Fetchster is now running in the menu bar."
