# iPhone Backup

Small macOS app: finds the newest local iPhone backup, packs it into a real `.zip`,
and moves it into the OneDrive folder `_iPhone-BU`.

## Layout

| Path | What |
|---|---|
| `Sources/iPhoneBackupApp.swift` | the whole app (SwiftUI + AppKit, single file) |
| `Info.plist` | bundle metadata — `CFBundleExecutable` **must** stay `iPhoneBackup` |
| `build.sh` | compiles, assembles the `.app`, ad-hoc signs it |
| `Tools/render-icon.swift` | draws the icon with CoreGraphics |
| `Tools/make-icon.sh` | renders + resizes + packs `Resources/AppIcon.icns` |
| `Resources/` | `AppIcon.icns` and the 1024 px master PNG |
| `build/` | build output (throwaway, safe to delete) |

## Build

```sh
./build.sh              # -> build/iPhone Backup.app
./build.sh --install    # also copies to ~/Applications
```

Needs only the Command Line Tools (`xcode-select -p`), no full Xcode.

**Quit the app before rebuilding** — `build.sh` starts with `rm -rf` on the bundle,
and pulling that out from under a running archive job is asking for trouble.

## Icon

```sh
./Tools/make-icon.sh    # only after editing Tools/render-icon.swift
```

`build.sh` consumes the committed `Resources/AppIcon.icns`, so a normal build does
not re-render. If Finder still shows the old icon after a rebuild, refresh the cache:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/"iPhone Backup.app"
```

## Things that will bite you again

- **`-parse-as-library` is required.** Compiling a single `.swift` file that uses `@main`
  fails with *"'main' attribute cannot be used in a module that contains top-level code"*
  without it. Already in `build.sh`.
- **An `.app` is a bundle, not a renamed binary.** It needs
  `Contents/MacOS/iPhoneBackup` + `Contents/Info.plist` with a matching
  `CFBundleExecutable` + a signature. Missing any of those and it silently won't launch.
- **Full Disk Access.** Reading `~/Library/Application Support/MobileSync/Backup` is
  TCC-protected. Grant it under *Systemeinstellungen › Datenschutz & Sicherheit ›
  Festplattenvollzugriff*. The app is **ad-hoc signed**, so its identity changes on every
  rebuild — after `./build.sh --install` you may have to remove and re-add the entry.
- **`ditto -c -k`, not `tar -czf`.** `tar -czf out.zip` writes a gzip tarball with a
  lying file extension. `ditto -c -k --sequesterRsrc --keepParent` writes a genuine
  zip64 archive.
- **Stage locally, then move.** The archive is built in `~/.iphone-backup-staging` and
  only then moved into OneDrive — same volume, so it is an instant rename. Writing
  directly into OneDrive makes it upload a half-written 50 GB file.
- **`FileAttributeKey.size` is an `NSNumber`.** `attrs[.size] as? Int64` is always `nil`;
  use `(attrs[.size] as? NSNumber)?.int64Value`.
- **Check `terminationStatus`.** An archiver that cannot report failure will happily
  leave a truncated file behind and claim success.

## Ideas if you pick this up again

- Store-only mode (`zip -0`) for speed — iPhone backups barely compress (~2%).
- Retention: keep the N newest archives, delete older ones.
- Schedule it with a **launchd** LaunchAgent (not cron — a sleeping laptop misses cron).
- Verify the finished archive (`ditto -V -x -k` into `/dev/null`, or `unzip -t`).
- Proper Developer ID signing so the Full Disk Access grant survives rebuilds.
