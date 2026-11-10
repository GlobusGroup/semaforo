#!/usr/bin/env bash
# Builds mac/build/Azioni.app from the SwiftPM package and signs it.
#   mac/scripts/build-app.sh              build only
#   mac/scripts/build-app.sh --install    build, then copy to /Applications/Azioni.app
#   mac/scripts/build-app.sh --universal  arm64 + x86_64 (for other people's Macs; see release.sh)
set -euo pipefail

usage() { echo "usage: $(basename "$0") [--install] [--universal]" >&2; }

install=false
arch_flags=()
for arg in "$@"; do
  case "$arg" in
    --install) install=true ;;
    --universal) arch_flags=(--arch arm64 --arch x86_64) ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

mac_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_name="Azioni"
app="$mac_dir/build/$app_name.app"

echo "==> swift build -c release ${arch_flags[*]:-}"
(cd "$mac_dir" && swift build -c release ${arch_flags[@]+"${arch_flags[@]}"})
bin_dir="$(cd "$mac_dir" && swift build -c release ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)"
binary="$bin_dir/$app_name"
[[ -x "$binary" ]] || { echo "error: no executable at $binary" >&2; exit 1; }

echo "==> assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/$app_name"
cp "$mac_dir/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$mac_dir/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
plutil -lint -s "$app/Contents/Info.plist"

# A stable identity keeps macOS treating rebuilds as the same app (login item, notification
# permission). Override with AZIONI_SIGN_IDENTITY; falls back to ad hoc if it isn't in the keychain.
identity="${AZIONI_SIGN_IDENTITY:-Apple Development: (LB46Y8ZZY5)}"
match="$(security find-identity -v -p codesigning | grep -F "${identity#Apple Development: }" | head -1 | awk '{print $2}' || true)"
if [[ -n "$match" ]]; then
  echo "==> signing with $(security find-identity -v -p codesigning | grep "$match" | sed -E 's/.*"(.*)"/\1/')"
  # Notarisation (Developer ID) needs a secure timestamp; local dev builds don't.
  timestamp=--timestamp=none
  [[ "$identity" == "Developer ID Application"* ]] && timestamp=--timestamp
  codesign --force --options runtime "$timestamp" -s "$match" "$app"
else
  echo "==> signing (ad hoc; no \"$identity\" certificate in the keychain)"
  codesign --force -s - --timestamp=none "$app"
fi
codesign -v --strict "$app"

if $install; then
  dest_dir="/Applications"
  dest="$dest_dir/$app_name.app"
  if pgrep -xq "$app_name"; then
    echo "==> $app_name is running; quitting it"
    osascript -e "quit app \"$app_name\"" >/dev/null 2>&1 || true
    for _ in {1..20}; do
      pgrep -xq "$app_name" || break
      sleep 0.25
    done
    if pgrep -xq "$app_name"; then
      echo "error: $app_name is still running. Quit it from the menu bar, then run again." >&2
      exit 1
    fi
  fi
  echo "==> installing to $dest"
  mkdir -p "$dest_dir"
  rm -rf "$dest"
  ditto "$app" "$dest"
  app="$dest"
fi

echo "$app"
