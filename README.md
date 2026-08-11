# iPhone Backup → Cloud

A small macOS app that finds your newest local iPhone backup, packs it into a real
`.zip`, and moves it into a cloud-synced folder — optionally on its own, every few
minutes, without a window ever appearing.

Local iPhone backups live in `~/Library/Application Support/MobileSync/Backup` as a
sprawling tree of thousands of files. That is fine for restoring, and terrible for
syncing: no cloud client should be asked to track 50 GB of churning individual files.
One archive per backup is something a sync client can actually handle.

Two things this app takes seriously, because the alternative loses data:

- **It waits until the backup is genuinely finished.** A backup that reports itself
  `finished` is still being written to for minutes afterwards. This was measured, not
  assumed — see [Why it waits](#why-it-waits).
- **It never deletes an archive.** Retention warns you when there are more than three;
  there is no delete path in the code at all.

## Requirements

- macOS 13.0 or later is *declared*, but the app has only ever been built and run on
  **macOS 26.6**. Nothing older has been tested. It should work; nobody has checked.
- The Command Line Tools to build it (`xcode-select --install`). Full Xcode is only
  needed to run the tests.
- **Full Disk Access**, which you must grant by hand. See below.

## Install

```sh
git clone https://github.com/haiggoh/mac-iphone-backup-cloudsync.git
cd mac-iphone-backup-cloudsync
./build.sh --install        # -> ~/Applications/iPhone Backup.app
```

`./build.sh` on its own builds into `./build/` without installing.

The app is **ad-hoc signed**, not signed with a Developer ID and not notarized. If you
would rather not grant Full Disk Access to an unnotarized binary — a fair position —
building it yourself from source is exactly what the command above does.

**Quit the app before rebuilding.** `build.sh` starts by `rm -rf`-ing the bundle, and
pulling that out from under a running archive job is asking for trouble.

## Full Disk Access

Reading `~/Library/Application Support/MobileSync/Backup` is protected by TCC, so the
app needs Full Disk Access. Two things about this are worth knowing up front, because
both are surprising:

**There is no prompt.** `kTCCServiceSystemPolicyAllFiles` has no allow/deny dialog —
macOS simply denies the read, and an app cannot ask. So the app detects the denial,
says so plainly, and offers a button that opens the right settings pane. You then add
it under **System Settings → Privacy & Security → Full Disk Access**.

**Every rebuild invalidates the grant.** Ad-hoc signing means the app's code identity
changes each time it is built or re-signed, so macOS treats the new copy as a different
app. After `./build.sh --install` you may have to remove the entry and add it again.
Only a Developer ID signature would fix this properly.

A symptom worth recognising: the same binary behaves differently depending on how it is
launched, because a process can inherit its parent's access.

    run from Terminal        -> works       (inherits Terminal's Full Disk Access)
    launched as an app       -> unreadable  (the app has no grant of its own)

That is not a bug in the app. It means the app itself is not in the list yet.

## First run

The app asks once where archives should go:

| Provider | Notes |
|---|---|
| OneDrive | |
| iCloud Drive | May evict local copies; the free tier is 5 GB, far below one backup |
| Google Drive | |
| Dropbox | |
| Custom folder | Any path — an external volume, a self-hosted sync folder, or no sync at all |

Accounts and tenants are found by prefix, so both the modern
`~/Library/CloudStorage/…` layout and older home-folder layouts are picked up, and no
account name appears anywhere in this repository's source. If several genuinely
different roots exist, the app asks rather than guessing which account a 50 GB archive
belongs in. Archives are written to a `_iPhone-BU` subfolder by default.

Every provider in that table may replace a local file with a placeholder to save disk
space. That is normal, and it means an archive you can see is not necessarily an
archive that is still on this Mac.

Setting up automation is offered at the same time and is entirely optional — declining
is a real answer, not a postponement.

## Automation

Automatic mode is a LaunchAgent that runs the app with `--automatic` every five
minutes. There is no window and no focus stealing; the process does its work, records
the outcome, and exits.

Turn it on in the app's **Automation** section, or from the command line:

```sh
APP="$HOME/Applications/iPhone Backup.app/Contents/MacOS/iPhoneBackup"

"$APP" --install-automation     # generates + loads the LaunchAgent
"$APP" --remove-automation      # boots it out and deletes the plist
"$APP" --check-only             # what would an unattended run do right now?
```

The plist is generated from live values, linted with `plutil -lint`, and loaded with
`launchctl bootstrap gui/<uid>`. Installing again boots the old job out first, so
upgrading cannot leave two definitions loaded. The path to the executable is resolved
at install time from the running bundle — nothing about your machine is committed to
this repository.

**Turning automation on records your existing backups as already processed**, so
flipping the switch cannot kick off a surprise 50 GB upload of something old. Only
backups made from then on are archived.

A run on battery is deferred when the estimated job, padded 1.5x, would outlast the
remaining charge. It does not flatly demand mains power.

## Seeing what happened

The Automation section shows the last run and its outcome. The durable record behind
that lives in the state file:

```sh
cat ~/Library/Application\ Support/io.github.haiggoh.iphonebackup/processed-state.json
```

`lastRun` holds the time, the outcome, whether it succeeded, and whether the run was
automatic. It is written on **every** exit path.

**The unified log is not a useful channel here.** For a standard (non-administrator)
user, `log show` fails outright:

    log: Could not open local log store: Operation not permitted

and `log stream` refuses with *"Must be admin"*. The app does log at `.notice` and
above, so the entries exist and an administrator can read them — but the state file is
the record you are meant to use, and it is why it exists.

## Settings

`~/Library/Application Support/io.github.haiggoh.iphonebackup/settings.json`, plain
JSON, `0600`, meant to be readable and editable by hand:

| Key | Meaning |
|---|---|
| `cloudProvider` | Chosen provider; `null` until you have been asked |
| `cloudRootPath` | Explicit destination root; `null` means "discover it" |
| `destinationSubdirectory` | Subfolder inside the root — `_iPhone-BU` by default |
| `archivesToKeep` | How many before it starts warning. It never deletes |
| `minimumSettleAge` | Seconds of stillness required before archiving; 900 by default |
| `automationEnabled` | Whether automation should be running |
| `automationIntervalSeconds` | LaunchAgent poll interval; 300 by default |

Values are clamped on load, so a hand-edited `0` cannot switch off a safety check —
`minimumSettleAge` has a 60-second floor. A malformed file falls back to defaults and
is **not** overwritten, so a mistyped brace costs you nothing. Delete the file to reset
the app.

## Why it waits

`Status.plist` saying `finished` does not mean the backup is done. The real sequence
observed on hardware is `uploading → moving → removing → finished`, and then, *after*
`finished`:

| Transport | Backup took | `finished` → `Info.plist` rewritten |
|---|---|---|
| Wi-Fi | ~20 min | **235 s** (and it passed through 0 bytes on the way) |
| USB / TB4 | ~5 min | **150 s** |

The lag barely shrank when the transfer was four times faster, so it is largely fixed
post-processing rather than a fraction of the transfer. Corroborated from outside the
filesystem: the Finder progress bar kept animating past 100% and stopped exactly when
`Info.plist` was rewritten.

So there are two gates, covering different failure modes:

- a **quiet period** (60 s, sampled twice) catches a file being written *while we
  watch*, and
- a **minimum settle age** (900 s) catches the gap *between* two writes, which
  sampling alone cannot see — both samples can land in the same lull.

900 s is roughly 3.8x the worst case measured, deliberately. Waiting costs nothing:
the agent polls every five minutes anyway, so a backup is archived fifteen or twenty
minutes after it finishes instead of six or ten. Being wrong costs a corrupt 50 GB
archive. Two observations are two observations — neither sampled a loaded SSD, a much
bigger backup, or a slower link.

## How the archive is made

`ditto -c -k --sequesterRsrc --keepParent`, which writes a genuine zip64 archive.
(`tar -czf out.zip` writes a gzip tarball with a lying file extension.) The exit status
is checked, and an implausibly small result is an error rather than a success.

The archive is built in `~/.iphone-backup-staging` and only then moved. Staging shares
a volume with the destination where possible, which makes the final step an instant
rename — measured at 29 ms, with the inode preserved — so you need about 50 GB free,
not 100. A custom destination on an external volume *is* a real cross-device copy, and
the app compares volume identity rather than assuming. Writing straight into a synced
folder would make the client start uploading a half-written file, which is the whole
reason for staging.

An advisory `flock` (`run.lock`) prevents overlapping runs. The kernel releases it, so
a crash cannot leave it stuck.

## Privacy

The app is local-only: no network requests of its own, no server operated by the
author, no telemetry, no analytics, no crash reporting. Uploading is done entirely by
your cloud client, under your own account.

It never logs backup contents, device names or full UDIDs — backup candidates expose a
redacted description precisely so that pasting the app's output into a public issue is
safe. `settings.json` is `0600` because it may name a cloud folder whose name embeds an
account or tenant.

See [SECURITY.md](SECURITY.md) for the full threat model and how to report a
vulnerability.

## Troubleshooting

**"No backups found" but you know there are some.** The app distinguishes a missing
folder from an unreadable one from an empty one, and says which. Unreadable means Full
Disk Access — and if you rebuilt the app recently, the grant is gone even though the
entry may still be listed. Remove it and add it again.

**Automation is on but nothing is archived.** Check `lastRun` in the state file, or the
Automation section. A backup that is not ready yet is reported as such and is not an
error; the next poll will pick it up. Then confirm the job is actually loaded:

```sh
launchctl print "gui/$(id -u)/io.github.haiggoh.iphonebackup" | head
```

**A manual run stops with `archiveAlreadyExistsWithoutState`.** An archive for that
backup is already in the destination and the app will not overwrite it. Move or rename
the existing file. (See [known gaps](CONTRIBUTING.md#known-gaps) — asking whether to
replace it is a real missing feature, not an intentional refusal to offer the choice.)

**A run is skipped on battery.** Expected, if the estimated job would outlast the
charge. Plug in.

## Uninstall

```sh
APP="$HOME/Applications/iPhone Backup.app/Contents/MacOS/iPhoneBackup"

"$APP" --remove-automation                   # do this first, while the app still exists
rm -rf "$HOME/Applications/iPhone Backup.app"
rm -rf "$HOME/Library/Application Support/io.github.haiggoh.iphonebackup"
rm -rf "$HOME/.iphone-backup-staging"
```

Then remove the app from **System Settings → Privacy & Security → Full Disk Access**.

If you deleted the app before removing automation, boot the job out by hand:

```sh
launchctl bootout "gui/$(id -u)/io.github.haiggoh.iphonebackup"
rm -f "$HOME/Library/LaunchAgents/io.github.haiggoh.iphonebackup.plist"
```

**Your archives are not touched by any of this.** They are ordinary files in your
cloud folder; delete them yourself if you want them gone.

## Development

```sh
./Tools/test.sh                 # tests (needs Xcode — see CONTRIBUTING.md)
./Tools/check-localization.sh    # missing keys, language drift, placeholder mismatches
./Tools/make-icon.sh             # only after editing Tools/render-icon.swift
./Tools/observe-backup.sh        # the diagnostic that produced the timings above
```

`IPhoneBackupCore` decides *whether* and *what* to archive and never imports SwiftUI,
so the parts that can lose data are testable against temporary fixtures.
`iPhoneBackupApp` is a thin AppKit/SwiftUI shell, localized in English and German; the
core returns values and the UI turns them into words.

| Path | What |
|---|---|
| `Sources/IPhoneBackupCore/ApplicationMode.swift` | Modes, run results, reason enums |
| `Sources/IPhoneBackupCore/BackupCompletionValidator.swift` | The completion gates |
| `Sources/IPhoneBackupCore/BackupDiscovery.swift` | Enumerate, validate, sort, classify |
| `Sources/IPhoneBackupCore/CloudRootLocator.swift` | Prefix search, symlink dedupe |
| `Sources/IPhoneBackupCore/BackupArchiver.swift` | The `ditto` pipeline |
| `Sources/IPhoneBackupCore/BackupStateStore.swift` | Atomic JSON state, `lastRun` |
| `Sources/IPhoneBackupCore/AutomaticRunController.swift` | The orchestrated sequence |
| `Sources/IPhoneBackupCore/LaunchAgentManager.swift` | Generate, lint, bootstrap, bootout |
| `Sources/IPhoneBackupCore/Configuration.swift` | Every path and tunable, injectable |
| `Info.plist` | `CFBundleExecutable` **must** stay `iPhoneBackup` |
| `build.sh` | Compiles, assembles the bundle, ad-hoc signs, checks consistency |
| `reference/` | The original prototype, kept for comparison |

Further reading:

- [CONTRIBUTING.md](CONTRIBUTING.md) — how to build and test, and what a change to the
  archiving, state or retention paths is expected to include.
- [docs/development-notes.md](docs/development-notes.md) — the build, signing, API and
  environment traps that cost time on this project, written down so they cost it once.
- [docs/roadmap.md](docs/roadmap.md) — what is planned, what was considered, and what has
  been ruled out (and why).

## License

[MIT](LICENSE).
