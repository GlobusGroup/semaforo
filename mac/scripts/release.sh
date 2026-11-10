#!/usr/bin/env bash
# Releases Semaforo: a notarised, universal Semaforo.app, zipped, signed for Sparkle, and published as a
# GitHub release that installed copies update from.
#
#   mac/scripts/release.sh 0.2.0              full release: bump, build, notarise, commit, tag,
#                                             push, GitHub release
#   mac/scripts/release.sh 0.2.0 --dry-run    build, notarise and write the appcast only; nothing
#                                             committed or published, Info.plist left as it was
#   mac/scripts/release.sh 0.2.0 --notes-file notes.txt
#                                             release notes (default: commit subjects since the
#                                             last tag)
#   mac/scripts/release.sh 0.2.0 --skip-notarize
#                                             signed with the Apple Development certificate and not
#                                             notarised. Updates still install on Macs that already
#                                             run the app (Sparkle checks its own signature), but a
#                                             fresh download is blocked by Gatekeeper. For testing
#                                             until there's a Developer ID certificate.
#
# How updates work: SUFeedURL in Resources/Info.plist points at
# https://github.com/<repo>/releases/latest/download/appcast.xml. Each release attaches Semaforo.zip
# and an appcast.xml naming it, its build number and its EdDSA signature. Sparkle in installed
# copies reads that feed about once a day (or on Settings › Check for Updates…), and offers any
# build number higher than its own. The repo must be public: Sparkle can't sign in to GitHub.
#
# One-time setup (see README › Mac app › Sharing the app):
#   1. A "Developer ID Application" certificate in the keychain (Xcode › Settings › Accounts ›
#      Manage Certificates › + › Developer ID Application; needs a paid Apple Developer team).
#   2. Notary credentials saved under a keychain profile:
#        xcrun notarytool store-credentials semaforo-notary --apple-id <you@…> --team-id <TEAMID>
#      (it asks for an app-specific password from account.apple.com).
#   3. The update signing key, kept in the login keychain under the account "azioni". After one
#      `swift build`, from mac/:
#        .build/artifacts/sparkle/Sparkle/bin/generate_keys --account azioni
#      and put the public key it prints in Resources/Info.plist as SUPublicEDKey. Another releaser
#      imports it with `generate_keys --account azioni -f <file>` after the first exports it with
#      `-x <file>`. Losing it means installed copies can't update; keep a backup.
#   4. The repo in SUFeedURL exists, is public, and is this checkout's `origin`.
#
# Env: SEMAFORO_RELEASE_IDENTITY (default: the first Developer ID Application certificate),
#      SEMAFORO_NOTARY_PROFILE (default: semaforo-notary).
set -euo pipefail
mac_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${SEMAFORO_NOTARY_PROFILE:-semaforo-notary}"
info_plist="$mac_dir/Resources/Info.plist"
sparkle_bin="$mac_dir/.build/artifacts/sparkle/Sparkle/bin"
sparkle_account="azioni"
build_dir="$mac_dir/build"

usage() { echo "usage: $(basename "$0") <version> [--dry-run] [--skip-notarize] [--notes-file <path>]" >&2; }
version="${1:-}"
[[ -n "$version" && "$version" != -* ]] || { usage; exit 2; }
shift
dry_run=false
notarize=true
notes_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=true ;;
    --skip-notarize) notarize=false ;;
    --notes-file) notes_file="${2:?--notes-file needs a path}"; shift ;;
    *) usage; exit 2 ;;
  esac
  shift
done
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || {
  echo "error: version must look like 1.2 or 1.2.0 (got: $version)" >&2; exit 2; }
tag="v$version"

plist() { /usr/libexec/PlistBuddy -c "$1" "$info_plist"; }
feed_url="$(plist 'Print :SUFeedURL')"
repo="$(sed -nE 's#^https://github.com/([^/]+/[^/]+)/releases/latest/download/appcast.xml$#\1#p' <<<"$feed_url")"
[[ -n "$repo" ]] || {
  echo "error: SUFeedURL ($feed_url) isn't a github.com/<owner>/<repo>/releases/latest/download/appcast.xml URL" >&2
  exit 1; }

echo "==> preflight"
if ! $notarize; then
  # build-app.sh's default: the Apple Development certificate, ad hoc without it.
  identity="${SEMAFORO_RELEASE_IDENTITY:-}"
  echo "    not notarising: fresh downloads will be blocked by Gatekeeper"
else
identity="${SEMAFORO_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]*)".*/\1/p' | head -1)}"
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
fi

# Installed copies only accept an update signed by the key whose public half they carry, so a
# mismatch here would strand everyone on this version.
(cd "$mac_dir" && swift package resolve >/dev/null && swift build -c release >/dev/null)
plist_key="$(plist 'Print :SUPublicEDKey' 2>/dev/null || true)"
keychain_key="$("$sparkle_bin/generate_keys" --account "$sparkle_account" -p 2>/dev/null)" || {
  echo "error: no Sparkle signing key in your keychain. See step 3 at the top of this script." >&2
  exit 1; }
[[ "$plist_key" == "$keychain_key" ]] || {
  echo "error: SUPublicEDKey in Resources/Info.plist doesn't match the Sparkle key in your keychain." >&2
  echo "  plist:    ${plist_key:-(empty)}" >&2
  echo "  keychain: $keychain_key" >&2
  exit 1; }

if ! $dry_run; then
  [[ -z "$(git -C "$mac_dir" status --porcelain --untracked-files=no)" ]] || {
    echo "error: working tree not clean; commit first." >&2; exit 1; }
  ! git -C "$mac_dir" rev-parse -q --verify "refs/tags/$tag" >/dev/null || {
    echo "error: tag $tag already exists." >&2; exit 1; }
  git -C "$mac_dir" remote get-url origin >/dev/null 2>&1 || {
    echo "error: no 'origin' remote. Add the repo from SUFeedURL: git remote add origin git@github.com:$repo.git" >&2
    exit 1; }
  # gh keychain tokens are often unreadable in scripted shells; export explicitly.
  GH_TOKEN="$(gh auth token)"; export GH_TOKEN
  export GH_PAGER=cat
  ! gh release view --repo "$repo" "$tag" >/dev/null 2>&1 || {
    echo "error: release $tag already exists on $repo." >&2; exit 1; }
fi

echo "==> version $version"
old_build="$(plist 'Print :CFBundleVersion')"
build_num=$((old_build + 1))
if $dry_run; then
  # Leave Info.plist as it was once the build has it.
  backup="$(mktemp)"; cp "$info_plist" "$backup"
  trap 'cp "$backup" "$info_plist"; rm -f "$backup"' EXIT
fi
plist "Set :CFBundleShortVersionString $version"
plist "Set :CFBundleVersion $build_num"
echo "    build $build_num"

SEMAFORO_UPDATES=1 SEMAFORO_SIGN_IDENTITY="$identity" "$mac_dir/scripts/build-app.sh" --universal
app="$build_dir/Semaforo.app"
zip="$build_dir/Semaforo-$version.zip"

if $notarize; then
  echo "==> notarising (this usually takes a few minutes)"
  ditto -c -k --keepParent "$app" "$build_dir/Semaforo-upload.zip"
  xcrun notarytool submit "$build_dir/Semaforo-upload.zip" --keychain-profile "$profile" --wait
  rm -f "$build_dir/Semaforo-upload.zip"

  echo "==> stapling"
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose "$app"
fi

rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

echo "==> signing the update and writing the appcast"
if [[ -z "$notes_file" ]]; then
  notes_file="$build_dir/notes.txt"
  last_tag="$(git -C "$mac_dir" describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
  if [[ -n "$last_tag" ]]; then
    git -C "$mac_dir" log --pretty='- %s' "$last_tag..HEAD" -- . > "$notes_file"
  else
    echo "First release with automatic updates." > "$notes_file"
  fi
fi
# Signs the stapled zip: the exact bytes installed copies download.
signature="$("$sparkle_bin/sign_update" --account "$sparkle_account" "$zip")"
min_macos="$(plist 'Print :LSMinimumSystemVersion')"
# Only the newest release: Sparkle needs nothing else. The zip URL names the tag, so it keeps
# working after later releases.
cat > "$build_dir/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Semaforo</title>
    <item>
      <title>Semaforo $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build_num</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min_macos</sparkle:minimumSystemVersion>
      <description sparkle:format="plain-text"><![CDATA[$(sed 's/]]>/]]]]><![CDATA[>/g' "$notes_file")]]></description>
      <enclosure url="https://github.com/$repo/releases/download/$tag/Semaforo.zip" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$build_dir/appcast.xml"

if $dry_run; then
  echo "==> dry run: not committing or publishing"
  echo "$zip"
  echo "$build_dir/appcast.xml"
  exit 0
fi

echo "==> commit, tag, push"
git -C "$mac_dir" add "$info_plist"
git -C "$mac_dir" commit -m "mac: release $version"
git -C "$mac_dir" tag "$tag"
git -C "$mac_dir" push origin HEAD "$tag"

echo "==> GitHub release"
# A stable filename, so releases/latest/download/Semaforo.zip always gets the newest app.
cp "$zip" "$build_dir/Semaforo.zip"
gh release create "$tag" "$build_dir/Semaforo.zip" "$build_dir/appcast.xml" \
  --repo "$repo" --title "Semaforo $version" --notes-file "$notes_file"

echo "==> checking the update feed"
# What installed copies read. Fails while the repo is private.
feed="$(curl -fsSL "$feed_url" || true)"
grep -q "<sparkle:shortVersionString>$version<" <<<"$feed" || {
  echo "error: the release is up, but $feed_url doesn't serve $version publicly." >&2
  exit 1; }
gh release view "$tag" --repo "$repo" --json url -q .url
