# Security Policy

## Supported versions

Only the latest release is supported. Older versions are not maintained.

## Reporting a vulnerability

Please do not open a public issue. Use
[GitHub's private vulnerability reporting](https://github.com/haiggoh/mac-iphone-backup-cloudsync/security/advisories/new)
instead.

Expect an acknowledgement within a few days. This is a spare-time project, so please
do not expect a same-day response.

## What this app can reach

The app is local-only. It makes no network requests of its own, contacts no server
operated by the author, and contains no telemetry, analytics or crash reporting.

- **It reads your iPhone backups.** `~/Library/Application Support/MobileSync/Backup`
  is protected by TCC, so the app needs **Full Disk Access**. An iPhone backup contains
  approximately everything on the device, so this is a broad grant — grant it
  knowingly. There is no narrower permission that would work.
- **It writes into a folder you choose**, under a subdirectory (`_iPhone-BU` by
  default) inside a OneDrive, iCloud Drive, Google Drive or Dropbox folder, or any
  custom path you name. Uploading is done by that service's own client under your own
  account; the app only puts a file on disk. Where your archives go afterwards, and
  under whose privacy policy, is entirely a property of the service you picked.
- **It stages archives** in `~/.iphone-backup-staging` before moving them.
- **It stores state and settings** in
  `~/Library/Application Support/io.github.haiggoh.iphonebackup/`. `settings.json` is
  written with `0600` permissions because it may name a cloud account folder, whose
  name can embed an account or tenant identifier.
- **It can install a LaunchAgent** at
  `~/Library/LaunchAgents/io.github.haiggoh.iphonebackup.plist`, only when you enable
  automation. It runs as your user, not as root, and the app never asks for or uses
  administrator rights.
- **It never deletes an archive.** Retention reports and warns; there is no delete
  path in the code, deliberately.

## Signing

Releases are **ad-hoc signed**, not signed with a Developer ID and not notarized. Two
consequences worth knowing:

- macOS will warn on first launch, and you will have to allow the app explicitly.
- The app's code identity changes on every rebuild or re-signing, which **invalidates
  the Full Disk Access grant**. That is macOS working as intended, not a bug in the
  app, but it does mean you must re-add the app to Full Disk Access after updating it.

If you do not trust an ad-hoc binary — a reasonable position for something you are
about to grant Full Disk Access — build it yourself from source with `./build.sh`. It
needs only the Command Line Tools.

## When reporting a problem, please do not include

- Raw backup metadata, `Manifest.db`, or anything out of a backup folder
- Full device UDIDs or backup directory names
- Cloud account or tenant names, or full paths that contain them

None of these are needed to diagnose a problem, and an issue is public. The app itself
follows the same rule: it logs a redacted `logDescription` for backup candidates rather
than identifiers, precisely so that pasting its output is safe.
