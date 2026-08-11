# Contributing

This is a small, focused utility that moves large, irreplaceable files around. That
one fact drives most of what follows: correctness and honest failure reporting matter
more here than features.

## Building and testing

You need the Command Line Tools to build, and Xcode to run the tests (see below).

```sh
git clone https://github.com/haiggoh/mac-iphone-backup-cloudsync.git
cd mac-iphone-backup-cloudsync

./build.sh                  # -> build/iPhone Backup.app
./build.sh --install        # also copies to ~/Applications

./Tools/test.sh             # the test suite
./Tools/check-localization.sh
```

**Use `./Tools/test.sh`, not `swift test`.** XCTest ships inside Xcode, not inside the
Command Line Tools. On a machine whose `xcode-select -p` still points at
`/Library/Developer/CommandLineTools` — the default after installing only the CLT —
`swift test` fails with *"no such module 'XCTest'"* even though Xcode is installed.
The script finds a usable developer directory and sets `DEVELOPER_DIR` for that one
command; nothing global changes. It forwards any extra arguments to `swift test`.

`Tools/check-localization.sh` gates missing keys, drift between English and German,
and placeholder mismatches. Run it after touching any UI string. Note that it also
reports keys that are *defined but unreferenced*, which is a real signal — see
[known gaps](#known-gaps).

**Quit the app before rebuilding.** `build.sh` starts by `rm -rf`-ing the bundle, and
pulling that out from under a running archive job is asking for trouble.

## Code style and dependencies

- **Match the surrounding code.** There is no linter; consistency with what is
  already there is the expectation.
- **Zero third-party dependencies, deliberately.** `Package.resolved` is not even
  tracked because there is nothing to pin. Please open an issue before adding one.
- **The core does not localize.** `IPhoneBackupCore` returns values — enums like
  `AutomaticRunResult` and `IncompleteReason` — and the UI layer turns them into
  words. This keeps those values stable across wording and language changes, and
  lets tests assert on them. Adding a user-facing string to the core is the wrong
  layer.
- **Use `Process` with argument arrays**, never an interpolated shell string.

## Things a pull request must respect

These are not style preferences; each one is there because the alternative loses data.

- **`ArchiveRetention` must not gain a delete function.** Each archive is tens of
  gigabytes of possibly irreplaceable data. It reports and warns; it does not delete.
- **Never widen the completion checks.** The quiet period and the minimum settle age
  cover different failure modes and both are needed: one catches a file being written
  while we watch, the other catches the gap *between* two writes. A backup that
  reports itself `finished` is still being written to for minutes afterwards — this
  was measured, not assumed, and the numbers are in `Configuration.swift`.
- **Record state only after the archive is safely in place.** Losing a record costs
  one redundant archive; writing one too early loses a backup silently. That
  asymmetry decides the ordering throughout `BackupStateStore`.
- **Anything a human may need to read after the fact must be logged at `.notice` or
  higher.** `os_log` does not persist `.debug` or `.info` to disk, so an outcome
  logged at `.info` is gone the moment the process exits. This actually happened.
- **Never log backup contents, device names, or full UDIDs.** Candidates expose
  `logDescription` for exactly this reason: someone pasting output into a public
  issue must not be pasting their device identifiers.
- **Changes to archiving, state or retention need tests.** Anything that could
  overwrite, truncate or forget an archive is the part of this project that matters.
- **Shipped shell scripts stay bash 3.2-compatible** (no associative arrays).
  `/bin/bash` on macOS is 3.2, while a Homebrew bash 5.x may be first on `PATH`, so
  `#!/bin/bash` and `#!/usr/bin/env bash` are not the same interpreter. Also: `log` is
  a zsh builtin (use `/usr/bin/log`), and `timeout` does not exist on macOS.
- **Never show a stored `String(describing:)` to a user.** Outcomes carry a payload-free
  `code` for display; `summary` is for bug reports only. This is enforced by tests.

Before changing the build, the signing, the archive pipeline or the completion gates,
read [docs/development-notes.md](docs/development-notes.md) — it records the specific
traps each of those has already sprung, including why testing a fix from Terminal can
appear to work when the app itself is still denied access.

## Known gaps

Manual mode has no duplicate-replace confirmation. `ConflictPolicy.replace` exists and
the archiver honours it, and the `duplicate.*` strings are already written in both
languages, but no UI offers the choice — so a manual run against an existing archive
returns `archiveAlreadyExistsWithoutState` and stops. That is safe (it never
overwrites) but less useful than asking. `Tools/check-localization.sh` reports those
keys as defined-but-unreferenced, which is how you will notice.

## Reporting bugs

Please include:

1. **macOS version.** Note that the app has only ever been built and run on macOS
   26.6. `LSMinimumSystemVersion` declares 13.0 and the binary's `minos` matches, but
   no other version has been tested — a report from 13, 14 or 15 is genuinely new
   information rather than a regression.
2. **Whether the app has Full Disk Access**, and whether it was rebuilt or re-signed
   since that was granted. Ad-hoc signing changes the app's identity, which
   invalidates the grant.
3. **The last run's outcome**, which is recorded durably in the state file:

   ```sh
   cat ~/Library/Application\ Support/io.github.haiggoh.iphonebackup/processed-state.json
   ```

   Look at `lastRun`. The Automation section of the UI shows the same thing.

4. **The output of `--check-only`**, which reports what an unattended run would do
   right now without changing anything:

   ```sh
   "/Applications/iPhone Backup.app/Contents/MacOS/iPhoneBackup" --check-only
   ```

Unified-log output is welcome but usually unavailable: `log show` needs administrator
rights and otherwise fails with *"Could not open local log store: Operation not
permitted"*. Do not spend time on it — the state file is the intended record.

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
