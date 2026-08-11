# Roadmap

Where this is going, and — just as usefully — what has been considered and ruled out.
Nothing here is a promise. Items are marked so a reader can tell a plan from an idea from
a closed question.

## Next

### Event-driven detection, layered on top of polling

Automation currently polls every five minutes with launchd's `StartInterval`. That was a
deliberate choice for the first version, **not** a placeholder, and the reasoning is on
the record in the original plan:

> Poll initially every five minutes using `StartInterval`. Do not depend exclusively on
> `WatchPaths`: an iPhone backup generates many filesystem events, nested changes may not
> map cleanly to a top-level trigger, and `launchd` does not expose a semantic "backup
> completed" event.
>
> A future FSEvents enhancement may be documented but is outside the first
> implementation.

So detection is **deferred, not abandoned** — and the important design constraint is that
it would *add* to polling rather than replace it:

- Polling stays as the reliable floor. A missed or coalesced event must never mean a
  backup is skipped, and a laptop that was asleep must still catch up on wake.
- The settle gate still decides readiness. An event only says "something changed", which
  is precisely what this app already knows better than to trust — see
  [why it waits](../README.md#why-it-waits).
- The gain is latency, not correctness: archiving a few minutes after the backup settles
  instead of up to a poll interval later.

An honest assessment of the value: modest. The current worst case is one extra poll, and
backups are taken at most daily. Worth doing for elegance and for battery, not because
anything is broken.

### Verify the finished archive

Read the archive back after writing it (`ditto -V -x -k` to `/dev/null`, or `unzip -t`)
before recording it as processed. Currently the exit status is checked and an
implausibly small result is rejected, which catches the common failures but not silent
corruption. The cost is reading tens of gigabytes back, so it likely wants to be
optional.

### Developer ID signing

The single change with the largest effect on day-to-day use: it would stop every rebuild
invalidating the Full Disk Access grant, and remove the unsigned-app warning on first
launch. Blocked on having a paid developer account, not on anything technical.

## Considered

### Store-only compression (`zip -0`)

iPhone backups are already-compressed media and barely compress further — roughly 2% was
observed. Skipping compression would cut archive time substantially for almost no size
penalty. Not done only because `ditto -c -k` does not expose a store-only level, so this
means changing archive tool, which is the one part of the pipeline it is least appealing
to churn.

### A duplicate-replace prompt in manual mode

`ConflictPolicy.replace` exists and the archiver honours it; the `duplicate.*` strings are
written in both languages. What is missing is any UI that offers the choice, so a manual
run against an existing archive stops with `archiveAlreadyExistsWithoutState`. Safe, but
less useful than the original app, which asked. See
[known gaps](../CONTRIBUTING.md#known-gaps).

### Notifications from automatic runs

Deliberately absent. Posting a user notification needs a running `NSApplication` and an
authorization prompt that no background process can answer. Unattended runs report
through `LastRun` in the state file, and the manual UI surfaces the last outcome. Would
need a different mechanism entirely, not just a call to `UNUserNotificationCenter`.

## Ruled out

### Automatic deletion of old archives

**Will not happen.** `ArchiveRetention` reports and warns; it has no delete function and
must not gain one. Each archive is tens of gigabytes of possibly irreplaceable personal
data, and an unattended process that deletes it is the most dangerous thing this app
could contain. An early idea list had "keep the N newest, delete older ones" — that is
what was rejected, and the rejection is load-bearing rather than an oversight.

If disk space is the problem, the app tells you which archives exist and you delete the
ones you choose.

### cron

Not on macOS. A laptop asleep at the scheduled minute simply misses the run; launchd
catches up on wake, and a LaunchAgent additionally has the logged-in user's paths,
privacy grants and preferences, which a LaunchDaemon would not.

## Done

Kept briefly, so a reader of an older note does not chase something already finished.

- Scheduling via a per-user LaunchAgent — shipped, with install and removal from the UI
  and the command line.
- Multi-provider destinations (OneDrive, iCloud Drive, Google Drive, Dropbox, custom).
- A real zip via `ditto` instead of a mislabelled gzip tarball.
- Conservative completion detection with a measured settle gate.
- Legible run outcomes instead of raw enum descriptions.
