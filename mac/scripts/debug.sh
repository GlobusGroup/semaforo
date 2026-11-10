#!/usr/bin/env bash
# Rebuilds mac/build/Azioni.app and relaunches it in debug mode (Debug section in the menu,
# "DBG" next to the icon). Quits any running Azioni first, installed copy included.
#   mac/scripts/debug.sh
set -euo pipefail
mac_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$mac_dir/scripts/build-app.sh" >/dev/null

if pgrep -xq Azioni; then
  osascript -e 'quit app "Azioni"' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -xq Azioni || break; sleep 0.25; done
  pkill -x Azioni 2>/dev/null || true
fi

open -n "$mac_dir/build/Azioni.app" --args -debug YES
echo "Azioni is running in debug mode. Open the menu bar icon (marked DBG) and use the Debug section."
