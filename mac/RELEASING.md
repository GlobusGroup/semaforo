# Releasing Semaforo

How to ship a new version so every installed copy offers to update itself. The one-time setup
(certificates, notary credentials, the update signing key) is in the README under
**Mac app › Sharing the app**; this is the routine part.

## 1. Get `main` ready

```bash
cd mac && swift test        # all green
cd .. && git status         # nothing uncommitted (untracked files are fine)
git pull --rebase           # in case someone else pushed
```

Install the build you're about to ship and use it for a minute:

```bash
mac/scripts/build-app.sh --install
```

## 2. Pick the version

Look at the last one with `git describe --tags --abbrev=0` (or the repo's Releases page), then:

- **0.x.0** (minor) for new features or anything people will notice;
- **0.x.y** (patch) for fixes only.

The script bumps the build number by itself. Installed copies only update when the new build
number is higher than theirs, so never reuse or hand-edit it.

## 3. Release notes (optional)

By default the notes are the commit subjects since the last tag. They're shown in the update
window, so for anything user-facing write a short file instead:

```text
- Notifications now default to repositories you watch.
- Settings has a sidebar.
- Fixed times that stopped updating.
```

and pass it with `--notes-file notes.txt`.

## 4. Run the release

While there's no Developer ID certificate (today):

```bash
npm run mac:release -- 0.3.0 --skip-notarize
```

Once there is one, drop `--skip-notarize`:

```bash
npm run mac:release -- 0.3.0
```

The script:

1. checks the Sparkle signing key in your keychain matches the one the app ships with;
2. sets the version, bumps the build number, builds a universal app;
3. notarises and staples it (unless `--skip-notarize`);
4. signs the update and writes `appcast.xml`;
5. commits "mac: release 0.3.0", tags `v0.3.0`, and **pushes `main` and the tag**;
6. creates the GitHub release with `Semaforo.zip` and `appcast.xml`;
7. checks the public update feed now serves the new version.

To try everything except committing and publishing, add `--dry-run`.

## 5. Check it

- The release is at `https://github.com/GlobusGroup/semaforo/releases/latest`.
- In an installed, *released* copy (not one from `build-app.sh`, which never updates itself):
  Settings › Updates › **Check for Updates…** should offer the new version.
- Installed copies also check by themselves about once a day.

## What `--skip-notarize` means

The update is signed with the Apple Development certificate and Sparkle's own key, but not
notarised by Apple.

- **People who already have Semaforo** get the update normally.
- **A fresh download** is blocked by Gatekeeper the first time. The person opens it, then goes
  to System Settings › Privacy & Security › **Open Anyway**.

## If something goes wrong

| Message | Fix |
| --- | --- |
| `working tree not clean` | Commit or stash your changes first. |
| `tag vX already exists` / `release vX already exists` | Use the next version number. |
| `SUPublicEDKey … doesn't match` | You're not using the keychain the app was released from. Import the key: `mac/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account azioni -f <backup file>`. |
| `no Sparkle signing key in your keychain` | Same: import the backup. Never generate a new key; installed copies would stop updating. |
| `doesn't serve X publicly` | The repo must be public for Sparkle to read the feed. |
| `no "Developer ID Application" certificate` | Add `--skip-notarize`, or set up the certificate (README). |

If the script stops after pushing but before the GitHub release, rerunning with the same version
fails on the existing tag. Create the release by hand from the files in `mac/build/`:

```bash
gh release create v0.3.0 mac/build/Semaforo.zip mac/build/appcast.xml \
  --repo GlobusGroup/semaforo --title "Semaforo 0.3.0" --notes-file mac/build/notes.txt
```

Here `mac/build/Semaforo.zip` is a copy of `mac/build/Semaforo-0.3.0.zip`; keep that exact name,
because the appcast points at it.
