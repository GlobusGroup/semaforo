#!/usr/bin/env bash
# Builds mac/build/Azioni.app from the SwiftPM package and ad hoc signs it.
#   mac/scripts/build-app.sh            build only
#   mac/scripts/build-app.sh --install  build, then copy to /Applications/Azioni.app
set -euo pipefail

usage() { echo "usage: $(basename "$0") [--install]" >&2; }

install=false
for arg in "$@"; do
  case "$arg" in
    --install) install=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

mac_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_name="Azioni"
app="$mac_dir/build/$app_name.app"

echo "==> swift build -c release"
(cd "$mac_dir" && swift build -c release)
bin_dir="$(cd "$mac_dir" && swift build -c release --show-bin-path)"
binary="$bin_dir/$app_name"
[[ -x "$binary" ]] || { echo "error: no executable at $binary" >&2; exit 1; }

echo "==> assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/$app_name"
cp "$mac_dir/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$mac_dir/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
plutil -lint -s "$app/Contents/Info.plist"

echo "==> signing (ad hoc)"
codesign --force -s - --timestamp=none "$app"
codesign -v "$app"

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
