#!/bin/bash
# Build GitPulse.app + GitPulse.dmg from src/main.swift
# Requires: Xcode command line tools (swiftc), Python3 + Pillow (icon, optional).
set -euo pipefail
cd "$(dirname "$0")"

APP="GitPulse.app"
BIN="GitPulse"

echo "==> Compiling…"
swiftc -O -parse-as-library src/main.swift -o "$BIN" \
    -framework SwiftUI -framework AppKit -framework UserNotifications -framework LocalAuthentication

echo "==> Building app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GitPulse"
chmod +x "$APP/Contents/MacOS/GitPulse"
cp src/GitPulse.icns "$APP/Contents/Resources/GitPulse.icns"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> Code signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "==> Creating DMG…"
STAGE="dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f GitPulse.dmg
hdiutil create -volname "GitPulse" -srcfolder "$STAGE" -ov -format UDZO GitPulse.dmg
rm -rf "$STAGE" "$BIN"

echo "==> Done: GitPulse.dmg"
