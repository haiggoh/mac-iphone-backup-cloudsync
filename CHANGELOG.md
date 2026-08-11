# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims at
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [1.0.0] — unreleased

First public version. The project began as a single-file prototype that packed the
newest local iPhone backup into a `.zip` and moved it into OneDrive; almost every
part of that has since been rewritten, so the entries below describe the app as it
now stands rather than each step of the way there.

### Added

- **Testable core.** `IPhoneBackupCore` holds discovery, completion validation,
  archiving, state, retention, power and LaunchAgent logic with no SwiftUI in it, so
  the parts that can lose data are covered by tests against temporary fixtures
  instead of only by running the real thing against a real 50 GB backup.
- **Completion validation that does not trust `Status.plist`.** A backup is only
  archived once `SnapshotState` reads `finished`, no watched file is zero-length, and
  metadata has demonstrably stopped changing — a 60-second quiet period sampled twice
  plus a minimum settle age. Two backups were observed end to end on real hardware:
  `Info.plist` was rewritten 235 s (Wi-Fi) and 150 s (USB) *after* the backup reported
  itself finished, so a quiet period alone would have archived mid-write in both runs.
- **Automatic mode** (`--automatic`), a run lifecycle designed for launchd: no
  window, no focus stealing, a real exit status, and every outcome written durably.
- **LaunchAgent install and removal**, from the Automation section of the UI or via
  `--install-automation` / `--remove-automation`. The plist is generated from live
  values, written atomically, linted with `plutil -lint`, and bootstrapped through
  `launchctl bootstrap gui/<uid>`. Installing again boots the old job out first, so an
  upgrade cannot leave two definitions loaded. The path to the executable is resolved
  at install time from the running bundle, never hardcoded in the repository.
- **`--check-only`**, which reports what an unattended run would do right now,
  changes nothing, and does not wait out the quiet period.
- **Universal cloud-root discovery** for OneDrive, iCloud Drive, Google Drive and
  Dropbox, plus a custom path for an external volume or no sync at all. Accounts and
  tenants are matched by prefix so no account name appears anywhere in the source, both
  the modern `~/Library/CloudStorage` layout and legacy home-folder layouts are
  searched, and a symlink and its target are treated as one folder rather than two
  candidate destinations.
- **First-run setup**: pick a provider, confirm the destination, and optionally turn
  automation on. Declining automation is a first-class answer and does not leave the
  app believing setup is unfinished.
- **Durable run records.** `processed-state.json` (schema v2) carries the archives
  already dealt with, the last error worth notifying about, and `lastRun` — time,
  outcome, success, and whether the run was automatic — written on *every* exit path.
  This exists because the unified log turned out not to be a usable channel: reading it
  requires administrator rights, and `os_log` never persists `.debug` or `.info` to
  disk at all.
- **Advisory lock** (`run.lock`, `flock`) so two runs cannot overlap. The kernel
  releases it, so a crash cannot leave it stuck.
- **Dynamic power guard.** A run on battery is deferred only when the estimated job,
  padded 1.5x, would outlast the remaining charge — rather than flatly demanding AC.
- **Retention reporting.** Warns once more than three archives are present. It has no
  delete function by design: each archive is tens of gigabytes of possibly
  irreplaceable data, and an unattended deleter is the most dangerous thing this app
  could contain.
- **A settings file** at `~/Library/Application Support/io.github.haiggoh.iphonebackup/settings.json`,
  written `0600`, documented, and hand-editable. Values are clamped on load, so a
  settle age of `0` cannot switch off the check that prevents archiving a half-written
  backup.
- **Localized UI**, English and German, following the system language;
  `Tools/check-localization.sh` gates missing keys, language drift and placeholder
  mismatches. The core is never localized — it returns values, and the UI turns them
  into words.
- **A menu bar**, so the app behaves like a Mac app rather than a bare window.
- **Programmatic app icon** drawn with CoreGraphics (`Tools/render-icon.swift`), so
  the icon is versioned as code rather than as an opaque binary asset.
- **`Tools/observe-backup.sh`**, the diagnostic that produced the completion
  measurements above.

### Changed

- Rebuilt as a real `.app` bundle with `Contents/MacOS` and an `Info.plist`, replacing
  the single-file prototype.
- Archives are created with `ditto -c -k --sequesterRsrc --keepParent`, producing a
  genuine zip64 archive. The prototype used `tar -czf out.zip`, which writes a gzip
  tarball with a lying file extension.
- The archive is staged in `~/.iphone-backup-staging` and only then moved into the
  destination. Staging shares a volume with the destination where possible, so the
  final step is an instant rename rather than a second 50 GB copy; writing directly
  into a synced folder makes the client upload a half-written file.
- The minimum settle age was raised to 900 s — roughly 3.8x the worst case measured,
  because waiting costs nothing and being wrong costs a corrupt archive. It is a
  setting, not a constant.
- Enabling automation for the first time records existing backups as already processed,
  so flipping the switch cannot start a surprise multi-gigabyte upload.
- Redesigned icon: asymmetric cloud with a knocked-out glyph, flat colors, no gradient.

### Fixed

- Failures are reported instead of discarded. The prototype ignored launch errors and
  exit statuses, so a truncated archive could be left behind and reported as success;
  `terminationStatus` is now checked and an implausibly small archive is an error.
- The progress bar advances correctly. `attrs[.size] as? Int64` is always `nil` for a
  `FileAttributeKey.size`, which is an `NSNumber`.
- An unreadable backup folder is distinguished from a missing and from an empty one,
  classified from the actual error rather than guessed, so a Full Disk Access problem
  no longer looks like "no backups found".
- Outcomes are logged at `.notice` rather than `.info`. At `.info` nothing was
  persisted, so an unattended run left no trace and appeared never to have happened.
- The Automation section shows a legible, localized sentence for the last run instead of
  a raw Swift enum description. It previously rendered
  `configurationRequired(IPhoneBackupCore.ConfigurationProblem.backupRootUnreadable(path:
  "/Users/…"))` — unlocalized, and containing the user's home path. Outcomes now carry a
  stable payload-free `code` (persisted as `LastRun.code`, state schema v3) that the UI
  localizes, and one that needs the user's attention is visually distinguished from a
  routine "nothing to do" rather than every outcome looking equally alarming.
- `--check-only` now names the state file before the `log show` command and says that the
  latter needs administrator rights, rather than offering only a command most users
  cannot run.

[Unreleased]: https://github.com/haiggoh/mac-iphone-backup-cloudsync/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/haiggoh/mac-iphone-backup-cloudsync/releases/tag/v1.0.0
