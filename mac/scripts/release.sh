#!/usr/bin/env bash
# Builds a notarised, universal Azioni.app you can hand to someone else, zipped at
# mac/build/Azioni-<version>.zip.
#
# One-time setup (see README › Mac app › Sharing the app):
#   1. A "Developer ID Application" certificate in the keychain (Xcode › Settings › Accounts ›
#      Manage Certificates › + › Developer ID Application; needs a paid Apple Developer team).
#   2. Notary credentials saved under a keychain profile:
#        xcrun notarytool store-credentials azioni-notary --apple-id <you@…> --team-id <TEAMID>
#      (it asks for an app-specific password from account.apple.com).
#
# Env: AZIONI_RELEASE_IDENTITY (default: the first Developer ID Application certificate),
#      AZIONI_NOTARY_PROFILE (default: azioni-notary).
set -euo pipefail
mac_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${AZIONI_NOTARY_PROFILE:-azioni-notary}"

identity="${AZIONI_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]*)".*/\1/p' | head -1)}"
if [[ -z "$identity" ]]; then
  cat >&2 <<MSG
error: no "Developer ID Application" certificate in the keychain.
Apple Development certificates can't be notarised. Create a Developer ID one in
Xcode › Settings › Accounts › (your team) › Manage Certificates › + › Developer ID Application,
then run this again. Only the account holder or an admin of a paid Apple Developer team can.
MSG
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
  cat >&2 <<MSG
error: no notary credentials saved as "$profile". Save them once with:
  xcrun notarytool store-credentials $profile --apple-id <your Apple ID> --team-id <team ID>
(it asks for an app-specific password: account.apple.com › Sign-In and Security).
MSG
  exit 1
fi

AZIONI_SIGN_IDENTITY="$identity" "$mac_dir/scripts/build-app.sh" --universal
app="$mac_dir/build/Azioni.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
zip="$mac_dir/build/Azioni-$version.zip"

echo "==> notarising (this usually takes a few minutes)"
ditto -c -k --keepParent "$app" "$mac_dir/build/Azioni-upload.zip"
xcrun notarytool submit "$mac_dir/build/Azioni-upload.zip" --keychain-profile "$profile" --wait
rm -f "$mac_dir/build/Azioni-upload.zip"

echo "==> stapling"
xcrun stapler staple "$app"
spctl --assess --type execute --verbose "$app"

rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "$zip"
