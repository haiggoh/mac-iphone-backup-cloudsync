# Roadmap

Where this is going, and — just as usefully — what has been considered and ruled out.
Nothing here is a promise. Items are marked so a reader can tell a plan from an idea from
a closed question.

## Next

### Say plainly that this archives an existing backup

The action reads „Sicherung starten" / "Start backup", but the app cannot make an iPhone
produce a backup — it archives whatever backup Finder last wrote into MobileSync and moves
that to the cloud. A user who reads the button as "back up my phone now" can finish a run
believing their current data is safe when what actually reached OneDrive is weeks old.
That is the one failure mode a backup tool must not have: nothing is lost, but safety is
misreported, and the user has no reason to look closer.

Triggering the device backup itself is **ruled out** rather than pending — see below — so
the whole fix is in what the app says:

- **Rename the action** so it cannot be read as "back up my phone now". The exact wording
  is **open**. Note that German „letzte" can be heard as *final* rather than *most recent*,
  so „neueste" is the safer word if the label names the backup at all — and naming the
  destination instead („… in OneDrive archivieren") sidesteps the question altogether.
  Whatever is chosen applies in both languages and in the same vocabulary everywhere:
  window, button, status line, run history.
- **Show the age of the source backup beside the action**, so what would be archived is
  visible before the click rather than inferred after it. This shares its implementation
  with the human-readable date in the next item.
- **Advise when the newest backup is stale.** Past some threshold, say so and point at
  Finder: connect the iPhone, back up there, then archive. A hint, not a block.
- **Carry that warning into unattended runs.** Automation archiving stale data succeeds
  forever and looks healthy. Staleness belongs in `LastRun` so the app can surface it —
  warning only, never failing, for the same reason retention warns and never deletes.

### Present "an archive already exists" as a choice, not a failure

`archiveAlreadyExistsWithoutState` renders through `error.archiveExists` with
`isError: true`, which paints it red — the same colour as a genuine failure. An archive
that already exists is the *desired* state, and the message should reassure rather than
alarm. Three things are wrong with it, and the strings that fix all three are already
written in both languages:

> „Für das iPhone-Backup vom %@ liegt schon ein Archiv im Zielordner (%@). Möchtest du es
> ersetzen?"

That dormant `duplicate.message` gives a **date** rather than a filename, a **folder**
rather than a full path, and a **question with a Replace action** rather than red error
text. So this item absorbs what used to sit under *Considered* as "a duplicate-replace
prompt in manual mode", and finishing it stops `Tools/check-localization.sh` reporting the
`duplicate.*` keys as defined-but-unreferenced. See
[known gaps](../CONTRIBUTING.md#known-gaps).

Notes for whoever picks it up:

- **`isError: Bool` cannot express this.** It has two states where the UI needs three:
  success, benign no-op, failure. That wants a severity carried on the message rather than
  a colour special-cased in the view, with red reserved strictly for failure.
- **Prefer neutral over green or orange.** Green reads as "archived it just now", which is
  the opposite of what happened; orange implies something needs attention, and nothing
  does. Secondary label colour also adapts to light and dark for free.
- **Name the destination, not the path.** "OneDrive" is what the user chose; the full
  `/Users/…/CloudStorage/OneDrive-…/_iPhone-BU/…` is noise. Keep it reachable — a tooltip,
  or Reveal in Finder — so debugging does not get harder. It also keeps an
  employer-specific path out of screenshots.
- **The date is the source backup's completion date**, not the archive's mtime: that is
  what identifies the contents. `BackupCandidate.completionDate` already exists and
  already feeds the window headline. Include the clock time only when two backups share a
  calendar day, and format it in the user's locale.

### A Settings window, starting with the destination

Settings today reveals the documented JSON file, on the reasoning that a window would just
duplicate the Automation section already in the main window. That reasoning holds for
automation and does not hold for the destination: the cloud provider and root are surfaced
prominently exactly once, during first run, and afterwards there is no way to change them
in the app at all. Hand-editing JSON is not an answer for the one choice every user makes.

- **Decided:** reuse the first-run provider-and-root picker as-is in Settings. Same
  control, same discovery, so it is already familiar the second time it is seen.
- **Open:** whether automation moves there too. It must not become easy to overlook, which
  is a real argument for leaving it in the main window where it is visible. Better decided
  once the destination pane exists and the window has a shape, rather than up front.
- **The rest of the file** belongs behind a collapsed "Advanced — treat with caution"
  section rather than on the front page. `minimumSettleAge` is deliberately exposed, but it
  is the measured 900 s and should look like it costs something to change. Keep "Reveal
  settings file" regardless: deleting that file is the documented way to reset the app.
- **Whatever moves, `automation.mismatch` must stay visible.** It reports a LaunchAgent
  that disagrees with the saved setting, and burying that in a window nobody opens turns a
  loud problem into a silent one.

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

### Triggering the iPhone backup itself

There is no public API to make a connected device produce a backup — Finder owns that.
Doing it anyway would mean `libimobiledevice`'s `idevicebackup2`, which brings its own
pairing and trust model plus a third-party dependency into a project that tracks none on
purpose; see
[code style and dependencies](../CONTRIBUTING.md#code-style-and-dependencies). The scope
stays "archive what Finder produced", which makes it the **user interface's** job to say so
rather than a capability to add — see
[say plainly what this does](#say-plainly-that-this-archives-an-existing-backup).

## Done

Kept briefly, so a reader of an older note does not chase something already finished.

- Scheduling via a per-user LaunchAgent — shipped, with install and removal from the UI
  and the command line.
- Multi-provider destinations (OneDrive, iCloud Drive, Google Drive, Dropbox, custom).
- A real zip via `ditto` instead of a mislabelled gzip tarball.
- Conservative completion detection with a measured settle gate.
- Legible run outcomes instead of raw enum descriptions.
