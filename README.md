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

A native menu bar version lives in `mac/` (Swift, no Node server). It polls GitHub the same way as the server above.

- **Menu bar icon.** A small pipeline, `■—■—●`, whose last stage shows the state: red cross with a count for failures since you last opened the menu, an amber in-progress ring with a count while runs are live, grey `!` on a dimmed pipeline when something is wrong (not signed in, rate limited, offline), a green check when the latest finished run passed in the last 24 hours, and a hollow ring when idle. Opening the menu clears the failure count.
- **Notifications.** A run that turns failed posts one notification ("org/repo · CI failed on main"); clicking it opens the run. More than 3 at once become a single summary. Nothing is posted for failures that happened before launch.
- **Menu.** New failures, running now and recent runs from the last 24 hours, plus Open Azioni Window and Quit.
- **Projects window.** Opens on every repo active in the last 24 hours as a card with its latest runs, most recent first. Also a flat Recent activity list and per-repo views, with search and a filter (All / Running / Failing). The gear (⌘,) opens Settings: Open at login, Refresh Now, last update and API budget.

Requirements:

- macOS 14+
- Xcode or a Swift 6 toolchain
- [GitHub CLI](https://cli.github.com/) authenticated (`gh auth login`)

```bash
npm run mac                          # builds and signs mac/build/Azioni.app
mac/scripts/build-app.sh --install   # same, then copies it to /Applications
cd mac && swift test                 # tests (fake GitHub, no network)
```

The app is signed with the Apple Development certificate for team `LB46Y8ZZY5` when it's in the keychain (set `AZIONI_SIGN_IDENTITY` to use another), otherwise ad hoc. A stable signature keeps macOS treating each rebuild as the same app, so Open at login and notification permission stick. It isn't notarised, so on another Mac you'd need to allow it in System Settings › Privacy & Security.

`--install` quits a running copy first. The app is menu-bar-only, so it has no Dock icon.

If the menu bar is full, the icon can end up hidden behind the notch. Hold ⌘ and drag it further right; the position is remembered.

### Debug mode

`npm run mac:debug` rebuilds the app and relaunches it in debug mode (`mac/scripts/debug.sh failures` starts on a scenario: `idle`, `allGood`, `running`, `failures`, `busy`, `noToken`, `rateLimited`, `offline`). The icon gets an orange **DBG** tag and the menu gains a Debug section:

- **Scenario**: live GitHub, or fixtures (idle, passed recently, 3 running, 2 new failures, a busy board of 8 repos, and each problem: gh not signed in, rate limited, offline). Fixtures cost no API requests.
- **Start a run / Finish: pass / Finish: fail**: push a fake run through running → done, on top of any scenario, live included.
- **Add 1 failure / Add 4 failures**: go through the real new-failure detection, so you get one notification, or the summary for more than 3.
- **Test notification** posts one directly; **Forget seen** moves the seen marker back an hour so the badge comes back.

To use debug mode with the installed app instead: `open /Applications/Azioni.app --args -debug YES`, or `defaults write com.azioni.mac debug -bool YES` to keep it on (`defaults delete com.azioni.mac debug` to turn it off).

The Mac app also watches for pushes. Every 20 seconds it reads one page of your repo list, newest push first; when it hasn't changed that's a free `304`. A repo whose `pushed_at` moved is checked straight away, and any repo pushed to or with a run started in the last hour is polled every 20 seconds, like repos with a run in progress. New runs usually show up within about 20 seconds, plus up to a minute of GitHub's own API caching.

The web app and the Mac app use the same `gh` token, so they share its 5,000 requests an hour. Run one at a time.

## Notes

- First load checks every repo once (one request each), so it takes a moment.
- Repos without Actions (404) are shown as having no runs. Other per-repo errors are counted in the status notice.
