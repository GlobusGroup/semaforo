# Azioni

Local status board for GitHub Actions. Scans repos you can access via the GitHub CLI, lists recent workflow runs, and sorts them by `run_started_at`.

## Requirements

- Node.js 20+
- [GitHub CLI](https://cli.github.com/) authenticated (`gh auth login`)

## Setup

```bash
npm install
npm run dev
```

Open [https://azioni.test](https://azioni.test) (port 3106, reserved in Beacon). Data is served by a Vite middleware (dev and `npm run preview`). It borrows the token from `gh auth token` and calls the GitHub REST API from the server, so no token reaches the browser.

## Scripts

| Command        | Purpose              |
| -------------- | -------------------- |
| `npm run dev`  | Local app + API      |
| `npm run build`| Typecheck + production build |
| `npm run preview` | Preview production build (API included) |
| `npm run mac`  | Build the Mac app (see below) |
| `npm run mac:debug` | Rebuild and relaunch the Mac app in debug mode |
| `npm run mac:release -- <version>` | Notarised universal build, published as an update (see Sharing the app) |

## How it stays within the rate limit

GitHub allows 5,000 API requests an hour. Scanning every repo on every refresh would use that up in minutes, so the server (`server/runStore.ts`) works like this:

- **One shared cache.** All tabs read the same snapshot. Requests less than 10s apart reuse the last scan, and concurrent requests join the scan already running.
- **Tiered polling.** Each repo is re-checked only when its interval is up:
  - live run (queued / in progress): every 20s
  - pushed or ran in the last 7 days: every 90s
  - everything else: every 15 min (catches scheduled and manual runs)
- **ETags.** Every request sends `If-None-Match`. An unchanged repo answers `304`, which doesn't count against the limit.
- **Repo list** is refreshed every 10 min.
- **Low budget.** Below 500 remaining requests, only repos with live runs are polled. If GitHub refuses requests, cached runs stay on screen with a notice until the limit resets.

The browser polls every 20s and **Refresh** forces a re-check of live and recent repos.

## Mac app

A native menu bar version, **Semaforo**, lives in `mac/` (Swift, no Node server; the Swift package is still named Azioni). It polls GitHub the same way as the server above.

- **Menu bar icon.** A small pipeline, `■—■—●`, whose last stage shows the state: red cross with a count for failures since you last opened the menu, an amber in-progress ring with a count while runs are live, grey `!` on a dimmed pipeline when something is wrong (not signed in, rate limited, offline), a green check when the latest finished run passed in the last 24 hours, and a hollow ring when idle. Opening the menu clears the failure count.
- **Notifications.** A run that turns failed posts one notification ("org/repo · CI failed on main"); clicking it opens the run. More than 3 at once become a single summary. Nothing is posted for failures that happened before launch.
- **Menu.** New failures, running now and recent runs from the last 24 hours, plus Open Semaforo Window and Quit.
- **Projects window.** Opens on every repo active in the last 24 hours as a card with its latest runs, most recent first. Also a flat Recent activity list and per-repo views, with search and a filter (All / Running / Failing). The gear (⌘,) opens Settings: Open at login, Refresh Now, last update, API budget and app updates.

Requirements:

- macOS 14+
- Xcode or a Swift 6 toolchain
- [GitHub CLI](https://cli.github.com/) authenticated (`gh auth login`)

```bash
npm run mac                          # builds and signs mac/build/Semaforo.app
mac/scripts/build-app.sh --install   # same, then copies it to /Applications
cd mac && swift test                 # tests (fake GitHub, no network)
```

The app is signed with the Apple Development certificate for team `LB46Y8ZZY5` when it's in the keychain (set `SEMAFORO_SIGN_IDENTITY` to use another), otherwise ad hoc. A stable signature keeps macOS treating each rebuild as the same app, so Open at login and notification permission stick. It isn't notarised, so on another Mac you'd need to allow it in System Settings › Privacy & Security.

`--install` quits a running copy first. The app is menu-bar-only, so it has no Dock icon.

If the menu bar is full, the icon can end up hidden behind the notch. Hold ⌘ and drag it further right; the position is remembered.

### Sharing the app

`npm run mac:release -- 0.2.0` builds a universal (Apple silicon + Intel) app, signs it with a Developer ID certificate, notarises and staples it, and publishes it as a GitHub release that installed copies update from. Add `--dry-run` to build, notarise and write the appcast without committing or publishing anything.

It sets the version in `mac/Resources/Info.plist`, bumps the build number, commits that as "mac: release 0.2.0", tags `v0.2.0` and pushes. The release carries `Semaforo.zip` and an `appcast.xml`. Release notes default to the commit subjects since the last tag; pass `--notes-file <path>` to write your own.

**Updates.** The app uses [Sparkle](https://sparkle-project.org). `SUFeedURL` in `Info.plist` points at the latest release's `appcast.xml`. About once a day, a released copy reads it and, if the build number is higher than its own, shows a window with the release notes and an Install button. Settings › Updates turns automatic checks off or checks now. Every update is signed with an EdDSA key, and copies only install updates signed with the key whose public half they carry. Local builds (`npm run mac`, `mac:debug`) have the feed stripped, so they never offer to replace themselves.

It needs these set up once:

1. A **Developer ID Application** certificate in your keychain. In Xcode › Settings › Accounts, pick the team, Manage Certificates › + › Developer ID Application. Only the account holder or an admin of a paid Apple Developer team can create one; Apple Development certificates can't be notarised.
2. Notary credentials saved in the keychain: `xcrun notarytool store-credentials semaforo-notary --apple-id <your Apple ID> --team-id <team ID>`. It asks for an app-specific password, made at account.apple.com › Sign-In and Security.
3. The update signing key. After one `swift build` in `mac/`, run `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account azioni` and put the public key it prints in `Info.plist` as `SUPublicEDKey`. (The key is labelled `azioni`, the app's old name; the label is only how the keychain finds it.) The private key stays in your login keychain; back it up with `generate_keys --account azioni -x <file>`. Losing it means installed copies can't update.
4. The GitHub repo named in `SUFeedURL` (`GlobusGroup/semaforo`), public (Sparkle can't sign in), and set as this checkout's `origin`.

Until then, `mac/scripts/build-app.sh --universal` makes an app signed but not notarised. On another Mac it opens after System Settings › Privacy & Security › Open Anyway.

Whoever runs it also needs the GitHub CLI signed in (`gh auth login`) with access to the repos.

### Debug mode

`npm run mac:debug` rebuilds the app and relaunches it in debug mode (`mac/scripts/debug.sh failures` starts on a scenario: `idle`, `allGood`, `running`, `failures`, `busy`, `noToken`, `rateLimited`, `offline`). The icon gets an orange **DBG** tag and the menu gains a Debug section:

- **Scenario**: live GitHub, or fixtures (idle, passed recently, 3 running, 2 new failures, a busy board of 8 repos, and each problem: gh not signed in, rate limited, offline). Fixtures cost no API requests.
- **Start a run / Finish: pass / Finish: fail**: push a fake run through running → done, on top of any scenario, live included.
- **Add 1 failure / Add 4 failures**: go through the real new-failure detection, so you get one notification, or the summary for more than 3.
- **Test notification** posts one directly; **Forget seen** moves the seen marker back an hour so the badge comes back.

To use debug mode with the installed app instead: `open /Applications/Semaforo.app --args -debug YES`, or `defaults write com.globusgroup.semaforo debug -bool YES` to keep it on (`defaults delete com.globusgroup.semaforo debug` to turn it off).

The Mac app also watches for pushes. Every 20 seconds it reads one page of your repo list, newest push first; when it hasn't changed that's a free `304`. A repo whose `pushed_at` moved is checked straight away, and any repo pushed to or with a run started in the last hour is polled every 20 seconds, like repos with a run in progress. New runs usually show up within about 20 seconds, plus up to a minute of GitHub's own API caching.

The web app and the Mac app use the same `gh` token, so they share its 5,000 requests an hour. Run one at a time.

## Notes

- First load checks every repo once (one request each), so it takes a moment.
- Repos without Actions (404) are shown as having no runs. Other per-repo errors are counted in the status notice.
