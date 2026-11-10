#!/usr/bin/env bash
# Rebuilds mac/build/Azioni.app and relaunches it in debug mode (Debug section in the menu,
# "DBG" next to the icon). Quits any running Azioni first, installed copy included.
#   mac/scripts/debug.sh             start on live GitHub
#   mac/scripts/debug.sh failures    start on a scenario: idle allGood running failures busy noToken rateLimited offline
set -euo pipefail
mac_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$mac_dir/scripts/build-app.sh" >/dev/null

if pgrep -xq Azioni; then
  osascript -e 'quit app "Azioni"' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -xq Azioni || break; sleep 0.25; done
  pkill -x Azioni 2>/dev/null || true
fi

args=(-debug YES)
[[ $# -gt 0 ]] && args+=(-debugScenario "$1")
open -n "$mac_dir/build/Azioni.app" --args "${args[@]}"
echo "Azioni is running in debug mode. Open the menu bar icon (marked DBG) and use the Debug section."
