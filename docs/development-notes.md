# Development notes

Traps that cost real time on this project, kept so they cost it once. These are
*engineering* notes — build, toolchain and API surprises. The rules a change has to
respect live in [CONTRIBUTING.md](../CONTRIBUTING.md); the user-facing explanations live
in the [README](../README.md). Where something is already explained in one of those, this
file points at it rather than repeating it.

## Building an `.app`

**`-parse-as-library` was required in the prototype.** Compiling a single `.swift` file
that uses `@main` fails with *"'main' attribute cannot be used in a module that contains
top-level code"* without it. No longer relevant now that the app is a Swift package with
a real `main.swift`, but it is exactly the error you will hit if you go back to a
single-file spike.

**An `.app` is a bundle, not a renamed binary.** It needs
`Contents/MacOS/<CFBundleExecutable>`, a `Contents/Info.plist` whose
`CFBundleExecutable` matches that filename *exactly*, and a code signature. Get any of
those wrong and the bundle silently refuses to launch — no error, no log, nothing.
`build.sh` now asserts the name match with `PlistBuddy` for this reason.

**Three places declare the minimum OS and they must agree:** `Package.swift`
(`platforms:`), `Info.plist` (`LSMinimumSystemVersion`), and the binary's own `minos`
(readable with `vtool -show-build`). `build.sh` compares the latter two and warns.
Claiming support for a version the binary rejects is a lie the user only discovers on an
older Mac.

**Localizations must be inside the bundle.** `NSLocalizedString` looks them up in
`Bundle.main` at runtime, so `Resources/*.lproj` has to be copied into
`Contents/Resources/`. Left in the source tree, the UI renders raw keys — and nothing
fails, which is what makes it worth a check. `Tools/check-localization.sh` covers the
key-level version of this.

**Quit the app before rebuilding.** `build.sh` begins with `rm -rf` on the bundle.

## Signing and Full Disk Access

**Ad-hoc signing means the code identity changes on every build**, so macOS treats each
rebuild as a different app and drops the Full Disk Access grant. Until there is a
Developer ID signature, testing a fresh build means re-adding it under Privacy &
Security. See the [README](../README.md#full-disk-access) for the user-facing version.

**Full Disk Access is not promptable.** `kTCCServiceSystemPolicyAllFiles` has no
allow/deny dialog; macOS just denies the read. An app that waits for a prompt waits
forever, so the only workable design is to detect the denial and offer a route to the
pane.

**Access is inherited, which makes testing misleading.** The same binary:

    <app>/Contents/MacOS/iPhoneBackup      from Terminal  -> works, inherits Terminal's FDA
    the app launched as an app             from Finder    -> backupRootUnreadable

So a fix "verified" by running the binary in a terminal is not verified at all. Test by
launching the installed bundle itself.

**Two bundles can claim the same identifier** — the build output in `build/` and the
installed copy in `~/Applications`. `open -b io.github.haiggoh.iphonebackup` may pick
either, so it is useless for acceptance testing; launch by exact path. `open` also
returns immediately, so it cannot report the real exit status, which is why the
LaunchAgent runs the executable directly rather than going through `open`.

## Archiving

**`ditto -c -k --sequesterRsrc --keepParent`, never `tar -czf`.** `tar -czf out.zip`
writes a gzip tarball with a lying file extension. Anything that then tries to treat it
as a zip fails in a confusing way.

**Stage locally, then move.** Writing straight into a cloud folder makes the sync client
start uploading a half-written multi-gigabyte file. Staging in the home folder keeps the
final step on one volume, where a move is a rename — measured at 29 ms with the inode
preserved. `BackupArchiver.moveIsRename(to:)` compares volume identity rather than
assuming, because a custom destination on an external volume genuinely is a copy.

**`FileAttributeKey.size` is an `NSNumber`.** `attrs[.size] as? Int64` is *always* `nil`,
so the progress bar silently never advanced. Use
`(attrs[.size] as? NSNumber)?.int64Value`.

**Always check `terminationStatus`.** An archiver that cannot report failure will
happily leave a truncated file and claim success — the single worst failure mode
available to this app.

## Completion detection

The measurements — and why the settle gate is 900 s rather than the observed maximum —
are documented at length in `Configuration.swift`, next to the constant they justify,
and summarised for users in the [README](../README.md#why-it-waits). Not repeated here;
read the source comment, it is the primary record.

The short version: `Status.plist` reporting `finished` does not mean the backup is done.
`Info.plist` was rewritten 235 s later on Wi-Fi and 150 s later over USB, and one run
passed through a zero-byte file on the way. Two gates are needed because they catch
different things — a quiet period catches a file being written while you watch, a
minimum settle age catches the gap between two writes.

## Logging and diagnostics

**`os_log` never persists `.debug` or `.info` to disk.** They live in a memory ring
buffer and vanish when the process exits, so an unattended run that logged its outcome
at `.info` left nothing behind and looked like it had never run. Anything readable after
the fact must be `.notice` or higher.

**Reading the unified log needs administrator rights.** For a standard user, `log show`
returns *"Could not open local log store: Operation not permitted"* and `log stream`
refuses with *"Must be admin"*. That is why every outcome is also written to
`processed-state.json` as `LastRun` — via `defer`, so no exit path can skip it.

**Never show a stored `String(describing:)` to a user.** The Automation section did
exactly that and rendered
`configurationRequired(IPhoneBackupCore.ConfigurationProblem.backupRootUnreadable(path:
"/Users/…"))` — unlocalized, and with a home path in it. `AutomaticRunResult.code` exists
so that cannot recur: it is payload-free by construction, and
`Tests/IPhoneBackupCoreTests/RunOutcomeCodeTests.swift` asserts no code can contain a
path. Keep the two channels distinct: `code` for display, `summary` for bug reports.

## Environment

**`/bin/bash` is 3.2** (no associative arrays) while a Homebrew bash 5.x is typically
first on `PATH`, so `#!/bin/bash` and `#!/usr/bin/env bash` are *different interpreters*
on the same machine. Shipped scripts stay 3.2-compatible.

**`log` is a zsh builtin** — use `/usr/bin/log` in scripts. **`timeout` does not exist on
macOS.** A bash `trap 'cleanup' TERM` with no `exit` returns to the interrupted loop,
which makes a script unkillable.

**XCTest ships with Xcode, not the Command Line Tools.** `swift test` fails with *"no
such module 'XCTest'"* when `xcode-select -p` points at the CLT even with Xcode
installed. `Tools/test.sh` finds a usable developer directory and sets `DEVELOPER_DIR`
for that one command.

## Known warning

`BackupViewModel.swift` emits *"main actor-isolated property 'archiver' cannot be
accessed from outside of the actor; this is an error in the Swift 6 language mode."* It
builds and passes today, but it is a real Swift 6 blocker and wants fixing before any
migration to that language mode.
