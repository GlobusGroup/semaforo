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

## Notes

- First load checks every repo once (one request each), so it takes a moment.
- Repos without Actions (404) are shown as having no runs. Other per-repo errors are counted in the status notice.
