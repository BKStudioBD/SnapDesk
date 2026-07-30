#!/bin/bash
#
# SnapDesk — regenerate the app icon.
#
# Compiles tools/icon/main.swift together with App/MenuBarIcon.swift, so the app
# icon and the menu-bar mark are drawn from ONE set of geometry, then renders
# Resources/AppIcon.png and Resources/AppIcon.icns.
#
# Run after changing the mark:  ./make-icon.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$WORK"' EXIT

echo "▶ Compiling the icon generator…"
xcrun -sdk macosx swiftc \
  -O \
  -target "arm64-apple-macos14.0" \
  -sdk "$SDK" \
  -o "$WORK/icon" \
  "$ROOT/App/MenuBarIcon.swift" \
  "$ROOT/tools/icon/main.swift"

echo "▶ Rendering…"
"$WORK/icon" "$ROOT/Resources" "$ICONSET"

echo "▶ Packing AppIcon.icns…"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"

echo "✅ Resources/AppIcon.png + Resources/AppIcon.icns updated."
echo "   Run ./build.sh to put the new icon on the installed app."
