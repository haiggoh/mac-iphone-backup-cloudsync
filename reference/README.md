# Reference: the iterations before the rewrite

Local-only archive of the earlier attempts, kept so the history is inspectable.
**Everything in this folder is gitignored except this file and
`original-gemini-version.swift`** — the rest are compiled `.app` bundles and
binaries that do not belong in git history. If you clone this repo elsewhere,
this folder will be empty.

Collected on 2026-08-06 from `~/Desktop/bu/`, `~/Apps/`, and `~/Desktop/`.

**Two lines in `original-gemini-version.swift` are redacted** (`USERNAME`,
`TENANT NAME`): the original hardcoded a real home path and a real OneDrive
tenant. Nothing else about that file was altered — and that it hardcoded them in
the first place is exactly the flaw the rewrite set out to remove, so the shape
of the mistake is still visible.

## What's here

| File | What it was |
|---|---|
| `original-gemini-version.swift` | the SwiftUI version — **tracked in git**, and the only iteration that is |
| `iPhone Backup Engine.scpt`, `… Kopie.scpt` | Script Editor AppleScript iterations |
| `iPhone Backup Pro.scpt`, `iPhone Backup Ondrive T.scpt` | later AppleScript iterations |
| `iPhone Backup Engine.app`, `… Kopie.app`, `… Kopie 2.app` | AppleScript apps exported from Script Editor |
| `iPhone Backup Pro.app`, `iPhone Backup Launcher.app` | ditto |
| `iPhone-backup-onedrive.app` | the variant whose orphaned `ditto` ran for 16 h (see below) |
| `iPhone_Backup_Pro` | a bare compiled Swift binary — no bundle, so it could not launch as an app |
| `iPhone_Backup.command` | shell-script double-click launcher |
| `run-shortcut?name=iPhoneBackupPro.inetloc` | a link that invoked the (now deleted) `iPhoneBackupPro` Shortcut |

Also removed on the same day and **not** kept: the Automator Service
`~/Library/Services/iPhone Backup zippen.workflow`, the Shortcuts entries
`iPhoneBackupPro` and `iPhoneBackupEngine`, and two stale app bundles in
`~/Applications`.

## The bug worth remembering

The Automator Service wrapped `ditto` in an AppleScript `try` block:

```applescript
try
    do shell script "ditto -c -k " & ... & targetPath
on error
    do shell script "rm -f " & quoted form of targetPath
    ...display alert "Abgebrochen"...
end try
```

`do shell script` in an Automator action is bounded by the Apple Event timeout
(~2 minutes). A 50 GB archive runs far past that, so the `on error` branch fired,
deleted the destination file, and reported "Abgebrochen" — **but `rm` does not kill
the child process.** `ditto` had already been orphaned and went on writing into the
now-unlinked inode for 16 hours, holding 17.3 GB that no file pointed at.

Two lessons the rewrite is built around:

1. **Never report an outcome you did not verify.** Both this and the Swift version
   announced success or cancellation without checking what the process actually did.
2. **Wrap long work in a mechanism that can wait for it.** If a shell call can outlive
   its host's timeout, the host must own the process lifecycle — or not start it.
