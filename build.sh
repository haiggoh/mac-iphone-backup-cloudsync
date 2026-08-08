#!/bin/bash
# Builds "iPhone Backup.app" from the Swift package.
#
#   ./build.sh              -> builds into ./build/
#   ./build.sh --install    -> also copies the result to ~/Applications
#
# Compiling is done by Swift Package Manager, which the Command Line Tools provide;
# full Xcode is only needed to run the tests (see Tools/test.sh). This script's job
# is the part SPM does not do: wrapping the executable in a bundle macOS will launch.
#
# An .app is not a renamed binary. It needs Contents/MacOS/<binary>, an Info.plist
# whose CFBundleExecutable matches that filename exactly, and a code signature.
# Getting any of those wrong produces a bundle that silently refuses to open.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="iPhone Backup"
BIN_NAME="iPhoneBackup"          # must match CFBundleExecutable in Info.plist
PRODUCT="iPhoneBackup"           # the executable product in Package.swift
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Building the package (release)"
swift build -c release --product "$PRODUCT"
BINARY="$(swift build -c release --product "$PRODUCT" --show-bin-path)/$PRODUCT"

if [[ ! -x "$BINARY" ]]; then
	echo "error: expected an executable at $BINARY" >&2
	exit 1
fi

echo "==> Cleaning the bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Assembling bundle"
cp "$BINARY" "$APP/Contents/MacOS/$BIN_NAME"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Localizations. NSLocalizedString looks these up in Bundle.main at runtime, so they
# have to be inside the bundle rather than left in the source tree.
shopt -s nullglob
LPROJ=(Resources/*.lproj)
if (( ${#LPROJ[@]} )); then
	for dir in "${LPROJ[@]}"; do
		cp -R "$dir" "$APP/Contents/Resources/"
	done
	echo "    localizations: ${#LPROJ[@]} ($(basename -a "${LPROJ[@]}" | tr '\n' ' '))"
else
	echo "    (warning: no Resources/*.lproj found — the UI will show raw keys)"
fi
shopt -u nullglob

# Icon: regenerate with ./Tools/make-icon.sh after editing Tools/render-icon.swift.
if [[ -f Resources/AppIcon.icns ]]; then
	cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
	echo "    (warning: Resources/AppIcon.icns missing — building without an icon)"
fi

echo "==> Verifying the bundle is internally consistent"
# Catches the mismatch that made the original prototype unlaunchable.
DECLARED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
if [[ "$DECLARED" != "$BIN_NAME" ]]; then
	echo "error: Info.plist declares CFBundleExecutable '$DECLARED' but the binary is '$BIN_NAME'" >&2
	exit 1
fi
MINOS="$(vtool -show-build "$APP/Contents/MacOS/$BIN_NAME" 2>/dev/null | awk '/minos/ {print $2}')"
DECLARED_MIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
echo "    binary minos $MINOS, Info.plist declares $DECLARED_MIN"
if [[ -n "$MINOS" && "$MINOS" != "$DECLARED_MIN" ]]; then
	# Not fatal, but claiming support for a version the binary rejects is a lie the
	# user only discovers on an older Mac.
	echo "    (warning: these disagree — update Package.swift platforms or Info.plist)"
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"

echo "==> Built: $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
	mkdir -p "$HOME/Applications"
	rm -rf "$HOME/Applications/$APP_NAME.app"
	cp -R "$APP" "$HOME/Applications/"
	echo "==> Installed: $HOME/Applications/$APP_NAME.app"
	# Ad-hoc signing means the code identity changes on every build, so macOS may
	# treat this as a different app and drop Full Disk Access.
	echo "    note: if it cannot find your backups, re-add it under"
	echo "          System Settings > Privacy & Security > Full Disk Access"
fi
