#!/bin/bash
# Builds "iPhone Backup.app" from Sources/iPhoneBackupApp.swift.
#
#   ./build.sh              -> builds into ./build/
#   ./build.sh --install    -> also copies the result to ~/Applications
#
# Requires only the Command Line Tools (no full Xcode).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="iPhone Backup"
BIN_NAME="iPhoneBackup"          # must match CFBundleExecutable in Info.plist
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling ($ARCH, SDK: $(basename "$SDK"))"
xcrun swiftc \
	-sdk "$SDK" \
	-target "$ARCH-apple-macos13.0" \
	-O \
	-parse-as-library \
	-framework SwiftUI -framework AppKit -framework UserNotifications \
	-o "$APP/Contents/MacOS/$BIN_NAME" \
	Sources/iPhoneBackupApp.swift

echo "==> Assembling bundle"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Icon: regenerate with ./Tools/make-icon.sh after editing Tools/render-icon.swift.
if [[ -f Resources/AppIcon.icns ]]; then
	cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
	echo "    (warning: Resources/AppIcon.icns missing — building without an icon)"
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
fi
