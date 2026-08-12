#!/bin/bash
# Looks for personal data that must not be in a public repository.
#
#   ./Tools/check-no-leaks.sh            # scan the working tree's tracked files
#   ./Tools/check-no-leaks.sh --clone    # scan a fresh clone of the remote instead
#
# Why this exists, specifically: the tests once shipped a real backup UUID. A fixture
# comment said its defaults "reproduce the state observed on the development machine",
# someone pasted the observed values in, redacted the device UDID's tail, and missed the
# UUID field. That reached a public repo and was only caught by an ad-hoc grep afterwards.
# Partial redaction is how leaks happen, so this is a gate rather than a habit.
#
# It cannot know what is secret. It knows the shapes of things that should never appear
# and the placeholders this project agreed to use, and it fails on anything else that
# matches. A new legitimate match belongs in the allowlist below, with a reason.
#
# Exits non-zero on any finding so it can gate a release. Scans tracked files only —
# build output and .gitignored working files are not what gets published.
set -uo pipefail

cd "$(dirname "$0")/.."

TARGET="."
CLEANUP=""
if [[ "${1:-}" == "--clone" ]]; then
	REMOTE="$(git remote get-url origin 2>/dev/null)"
	if [[ -z "$REMOTE" ]]; then
		echo "error: no 'origin' remote to clone" >&2
		exit 1
	fi
	CLEANUP="$(mktemp -d "${TMPDIR:-/tmp}/leakscan.XXXXXX")"
	echo "==> Cloning $REMOTE"
	git clone -q "$REMOTE" "$CLEANUP/repo" || { echo "error: clone failed" >&2; exit 1; }
	TARGET="$CLEANUP/repo"
	trap 'rm -rf "$CLEANUP"' EXIT
fi

cd "$TARGET"

python3 - <<'PY'
import re, subprocess, sys

files = subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.split()

# A detector necessarily contains the patterns it detects, so it would always report
# itself. Skipping it is not a hole: this file holds regexes and an allowlist, and any
# real value pasted in here would be visible in the diff of a one-purpose script.
#
# Noticed the honest way — the first run of this script happened while it was still
# untracked, so `git ls-files` did not include it and it never scanned itself. It failed
# the moment it was committed.
files = [path for path in files if path != "Tools/check-no-leaks.sh"]

# Values this project uses on purpose. Anything matching a rule below is a finding
# UNLESS the whole match is one of these. Keep each one obviously synthetic.
ALLOWED = {
    # Fabricated identifiers used by fixtures.
    "00000000-000000000000FFFF",
    "00000000-0000-0000-0000-000000000000",
    "00000000-0000-0000-0000-000000000001",
    # Placeholder home directories in tests and docs. "/Users/USERNAME" is the
    # already-redacted form in reference/original-gemini-version.swift, kept verbatim
    # because that file is preserved as the historical original.
    "/Users/someone", "/Users/somebody", "/Users/user", "/Users/<name>", "/Users/…",
    "/Users/USERNAME",
    # Apple's fixed, non-personal iCloud Drive container.
    "com~apple~CloudDocs",
    # An all-zero identifier stands in for a redacted one in comments.
    "00000000-…",
}

# Generic company/account names the project uses as stand-ins, plus the fixture names
# that describe what a test directory *is* rather than who it belongs to.
#
# This is the rule's whole design: a real tenant name gets added by accident, so it will
# not be on this list, and it will be reported. The cost is that a new placeholder has to
# be added here deliberately — which is the point, not a nuisance.
ALLOWED_ACCOUNT_WORDS = {
    # Stand-ins for an account or tenant.
    "personal", "contoso", "somecompanygmbh", "companyone", "companytwo",
    "anycompanyname", "somecompany", "company", "example", "tenantname", "tenant",
    # Fixture names describing the case under test.
    "notadirectory", "discovered", "symlinked", "duplicate",
}

RULES = [
    # An Apple device UDID: 8 hex, dash, 16 hex. The leading group encodes the model,
    # so even a "redacted" one with a real prefix is real-derived.
    ("device UDID", re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b")),
    # A UUID, e.g. the one in Status.plist. Identifies a real backup.
    ("UUID", re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}"
                        r"-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b")),
    # A truncated identifier is still derived from a real one.
    ("truncated identifier", re.compile(r"\b[0-9A-F]{8}-\s*…")),
    # An absolute home path names the account it came from.
    ("absolute home path", re.compile(r"/Users/[^\s\"'/)]+")),
    ("email address", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")),
    # A cloud folder name embeds the account or tenant it belongs to.
    ("cloud account folder", re.compile(r"OneDrive\s*-\s*([A-Za-z0-9 ._-]+)")),
    ("cloud account folder", re.compile(r"GoogleDrive\s*-\s*([A-Za-z0-9 ._-]+)")),
]

# Swift and shell attributes/decorators that look like an email to the rule above.
NOT_AN_EMAIL = re.compile(r"@(main|Published|MainActor|objc|escaping|testable|"
                          r"preconcurrency|State|ObservedObject|discardableResult|"
                          r"available|Sendable|autoclosure|inlinable)\b")

findings = []
for path in files:
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.readlines()
    except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
        continue  # binary asset, or a path that is not a readable file

    for number, line in enumerate(lines, 1):
        for label, rule in RULES:
            for match in rule.finditer(line):
                whole = match.group(0)
                if whole in ALLOWED:
                    continue
                if label == "email address" and NOT_AN_EMAIL.search(whole):
                    continue
                if label == "absolute home path":
                    # Compare the account component, so "/Users/someone/Library/x" is
                    # allowed by virtue of "/Users/someone".
                    parts = whole.split("/")
                    if len(parts) > 2 and f"/Users/{parts[2]}" in ALLOWED:
                        continue
                if label == "cloud account folder":
                    account = (match.group(1) or "").strip().replace(" ", "").lower()
                    if account in ALLOWED_ACCOUNT_WORDS:
                        continue
                findings.append((path, number, label, whole, line.strip()))

if findings:
    print(f"FAIL: {len(findings)} possible leak(s) of personal data:\n")
    for path, number, label, whole, line in findings:
        print(f"  {path}:{number}  [{label}]  {whole}")
        print(f"      {line[:120]}")
    print("\nEach of these is either real data to remove, or a new legitimate")
    print("placeholder to add to ALLOWED in this script — with a reason.")
    sys.exit(1)

print(f"OK: {len(files)} tracked file(s) scanned, no personal data found")
PY
