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

- **Menu bar icon.** Red `⚠ 2` for failures since you last opened the menu, `⟳ 3` while runs are live, a dimmed cloud when something is wrong (not signed in, rate limited, offline), and a quiet checkmark when all is well. Opening the menu clears the failure count.
- **Notifications.** A run that turns failed posts one notification ("org/repo · CI failed on main"); clicking it opens the run. More than 3 at once become a single summary. Nothing is posted for failures that happened before launch.
- **Menu.** New failures, running now and recent runs, plus the API budget left, Refresh, Open at login and Quit.
- **Projects window.** Recent activity across all repos, then every repo with its latest status. Search, filter (All / Running / Failing), and each repo's recent runs.

Requirements:

- macOS 14+
- Xcode or a Swift 6 toolchain
- [GitHub CLI](https://cli.github.com/) authenticated (`gh auth login`)

```bash
npm run mac                          # builds and ad hoc signs mac/build/Azioni.app
mac/scripts/build-app.sh --install   # same, then copies it to ~/Applications
cd mac && swift test                 # tests (fake GitHub, no network)
```

`--install` quits a running copy first. The app is menu-bar-only, so it has no Dock icon.

The web app and the Mac app use the same `gh` token, so they share its 5,000 requests an hour. Run one at a time.

## Notes

- First load checks every repo once (one request each), so it takes a moment.
- Repos without Actions (404) are shown as having no runs. Other per-repo errors are counted in the status notice.
