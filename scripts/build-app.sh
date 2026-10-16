#!/bin/bash
set -euo pipefail

ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
swift build --package-path "$ROOT" -c release
BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
APP="$ROOT/dist/Kiln.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Kiln" "$APP/Contents/MacOS/Kiln"
cp -R "$BIN/Kiln_Kiln.bundle" "$APP/Contents/Resources/"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
swift "$ROOT/scripts/make-icon.swift" "$APP/Contents/Resources/Kiln.icns"
codesign --force --sign - "$APP"
printf '\nBuilt %s\nOpen it with: open "%s"\n' "$APP" "$APP"
