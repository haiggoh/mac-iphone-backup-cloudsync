#!/bin/bash
# Runs the test suite, working whether or not xcode-select points at Xcode.
#
#   ./Tools/test.sh [extra swift test arguments]
#
# XCTest ships inside Xcode, not inside the Command Line Tools. On a machine where
# `xcode-select -p` still points at /Library/Developer/CommandLineTools — the
# default after installing only the CLT — `swift test` fails with
# "no such module 'XCTest'" even though Xcode is installed. That reads like a
# missing dependency when it is only a toolchain selection.
#
# Rather than require every contributor to run `sudo xcode-select -s`, this finds
# a usable developer directory and sets DEVELOPER_DIR for the one command that
# needs it. Nothing global changes.
set -euo pipefail

cd "$(dirname "$0")/.."

xctest_available_in() {
	[ -d "$1/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]
}

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"

if [ -z "$DEV_DIR" ] || ! xctest_available_in "$DEV_DIR"; then
	FOUND=""
	for candidate in /Applications/Xcode*.app/Contents/Developer; do
		if xctest_available_in "$candidate"; then
			FOUND="$candidate"
			break
		fi
	done

	if [ -z "$FOUND" ]; then
		echo "error: XCTest not found." >&2
		echo "  Selected developer dir: ${DEV_DIR:-<none>}" >&2
		echo "  XCTest ships with Xcode, not the Command Line Tools." >&2
		echo "  Install Xcode, or point at it with:" >&2
		echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
		exit 1
	fi

	echo "==> XCTest missing from $DEV_DIR; using $FOUND for this run"
	export DEVELOPER_DIR="$FOUND"
fi

exec swift test "$@"
