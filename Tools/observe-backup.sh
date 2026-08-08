#!/bin/bash
# Observes local iPhone backup metadata and reports every CHANGE it sees.
#
#   ./Tools/observe-backup.sh [seconds-between-samples]
#
# Why this exists: the archiver decides a backup is finished by reading
# Status.plist. That is an observation about how Apple behaves, not a documented
# contract, so it has to be verified on a real device rather than assumed. Run
# this, take a backup, and it records what actually happens — which fields move,
# in what order, and how long after "finished" the files stop growing.
#
# Prints only on change, so a quiet stretch means genuinely nothing moved. Full
# sample history goes to the log file; stdout carries just the transitions.
#
# Needs Full Disk Access for the terminal running it, same as the app.
#
# Portability note: macOS ships bash 3.2, which has no associative arrays, and a
# backup UDID like 00000000-… is parsed as an arithmetic index if used as a
# subscript. Previous state therefore lives in one small file per directory.
set -uo pipefail

INTERVAL="${1:-3}"
BACKUP_ROOT="$HOME/Library/Application Support/MobileSync/Backup"
LOG="$HOME/.claude/logs/iphone-backup-observation-$(date +%Y%m%d-%H%M%S).log"
STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/backup-observe.XXXXXX")

mkdir -p "$(dirname "$LOG")"

# The signal traps MUST exit. A bash trap handler that only cleans up returns to
# wherever it interrupted, so `trap 'rm -rf "$STATE_DIR"' TERM` made this script
# unkillable by SIGTERM *and* deleted its own state directory while the loop kept
# running — which is what produced 874 spurious APPEARED lines in one log. Cleanup
# on EXIT, cleanup-and-exit on a signal.
trap 'rm -rf "$STATE_DIR"' EXIT
trap 'rm -rf "$STATE_DIR"; exit 130' INT
trap 'rm -rf "$STATE_DIR"; exit 143' TERM

if [ ! -d "$BACKUP_ROOT" ]; then
	echo "FATAL: no backup root at $BACKUP_ROOT"
	exit 1
fi

# Device UDIDs are personal data. Show only a short prefix on stdout so the
# output stays shareable, while remaining distinguishable across devices.
short_id() { printf '%.8s…' "$1"; }

# One flat, greppable line describing the whole state of one backup directory.
sample_dir() {
	local dir="$1" out="" f size mtime
	for f in Status.plist Manifest.db Info.plist Manifest.plist; do
		if [ -e "$dir/$f" ]; then
			size=$(stat -f%z "$dir/$f" 2>/dev/null || echo "?")
			mtime=$(stat -f%m "$dir/$f" 2>/dev/null || echo "?")
			out="$out$f=${size}@${mtime} "
		else
			out="$out$f=absent "
		fi
	done
	if [ -e "$dir/Status.plist" ]; then
		local snap state date
		snap=$(plutil -extract SnapshotState raw -o - "$dir/Status.plist" 2>/dev/null || echo "?")
		state=$(plutil -extract BackupState raw -o - "$dir/Status.plist" 2>/dev/null || echo "?")
		date=$(plutil -extract Date raw -o - "$dir/Status.plist" 2>/dev/null || echo "?")
		out="${out}SnapshotState=$snap BackupState=$state Date=$date"
	fi
	printf '%s' "$out"
}

# Names of the fields that differ, so output stays readable — a raw before/after
# pair is unusable once four files with sizes and mtimes are in play.
changed_fields() {
	local prev="$1" cur="$2" field name out=""
	for field in $cur; do
		name="${field%%=*}"
		case " $prev " in
			*" $field "*) ;;
			*) out="$out$name " ;;
		esac
	done
	printf '%s' "${out% }"
}

echo "observing $BACKUP_ROOT every ${INTERVAL}s"
echo "log: $LOG"
echo "start a backup now — transitions appear below (Ctrl-C to stop)"

while true; do
	now=$(date +%H:%M:%S)

	# If the state directory vanished, every directory looks new again and the
	# output degenerates into APPEARED on every pass. That really happens: when the
	# parent shell is killed, the EXIT trap can remove STATE_DIR while this loop is
	# still running — observed producing 874 spurious APPEARED lines in one log.
	# Stopping is the honest response; a silently useless observer is worse than none.
	if [ ! -d "$STATE_DIR" ]; then
		echo "[$now] FATAL: state directory disappeared, stopping rather than reporting noise"
		exit 1
	fi

	# Reglobbed every pass so a directory appearing mid-run is picked up.
	for dir in "$BACKUP_ROOT"/*/; do
		[ -d "$dir" ] || continue
		id=$(basename "$dir")
		cur=$(sample_dir "$dir")
		state_file="$STATE_DIR/$id"

		if [ ! -f "$state_file" ]; then
			echo "[$now] APPEARED $(short_id "$id") :: $cur"
			echo "[$now] APPEARED $id :: $cur" >>"$LOG"
			printf '%s' "$cur" >"$state_file"
			continue
		fi

		prev=$(cat "$state_file")
		if [ "$prev" != "$cur" ]; then
			fields=$(changed_fields "$prev" "$cur")
			echo "[$now] CHANGED $(short_id "$id") [$fields] :: $cur"
			echo "[$now] CHANGED $id [$fields] :: $cur" >>"$LOG"
			printf '%s' "$cur" >"$state_file"
		else
			echo "[$now] stable $id :: $cur" >>"$LOG"
		fi
	done

	sleep "$INTERVAL"
done
