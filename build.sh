#!/bin/bash
#
# SnapDesk — build an Apple Silicon (arm64, M-series) .app, sign it, package a
# .dmg, and (optionally) notarize it so it installs with NO Gatekeeper warning.
#
# Run on a Mac with Xcode command-line tools installed (`xcode-select --install`).
# No Xcode project required — this compiles the sources directly with swiftc.
#
# USAGE
#   ./build.sh                      # ad-hoc signed (for local use; see notes)
#   DEV_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="snapdesk-notary" ./build.sh    # signed + notarized, zero warnings
#
# To create the notary profile once:
#   xcrun notarytool store-credentials "snapdesk-notary" \
#       --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"
#
set -euo pipefail

APP_NAME="SnapDesk"
BUNDLE_ID="com.snapdesk.app"
MIN_MACOS="14.0"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
DMG="$BUILD/$APP_NAME.dmg"

DEV_ID="${DEV_ID:-}"                 # Developer ID Application identity, or empty for ad-hoc
NOTARY_PROFILE="${NOTARY_PROFILE:-}" # notarytool keychain profile name, or empty to skip

echo "▶ Cleaning…"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES=$(find "$ROOT" -name '*.swift' -not -path "$BUILD/*" -not -path "$ROOT/tools/*")

# --- Compile an Apple Silicon (arm64) binary ---------------------------------
echo "▶ Compiling for Apple Silicon (arm64)…"
xcrun -sdk macosx swiftc \
  -O -whole-module-optimization \
  -parse-as-library \
  -target "arm64-apple-macos${MIN_MACOS}" \
  -sdk "$SDK" \
  $SOURCES \
  -o "$APP/Contents/MacOS/$APP_NAME"

# Sanity-check that we really produced an arm64-only binary.
echo "▶ Binary architectures: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

# --- Assemble the bundle -----------------------------------------------------
echo "▶ Assembling app bundle…"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Bundle custom UI sounds (Resources/Sounds/*.wav → Contents/Resources/Sounds).
if [ -d "$ROOT/Resources/Sounds" ]; then
  mkdir -p "$APP/Contents/Resources/Sounds"
  cp "$ROOT/Resources/Sounds/"*.wav "$APP/Contents/Resources/Sounds/" 2>/dev/null || true
fi

# Optional icon: drop an AppIcon.icns into Resources/ and it will be embedded.
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

# --- Code signing ------------------------------------------------------------
# Signing strategy (TCC permissions like Screen Recording are tied to the code
# signature; an *unstable* signature breaks the grant on every rebuild):
#   1. DEV_ID set            → Developer ID + hardened runtime (distribution).
#   2. "SnapDesk Dev" cert   → stable self-signed local identity. Same cert every
#      exists in keychain       build ⇒ stable designated requirement ⇒ Screen
#                               Recording / Accessibility grants PERSIST across
#                               rebuilds. Create once with ./make-signing-cert.sh.
#   3. otherwise             → ad-hoc (grant must be re-approved after each build).
# --mas builds the Mac App Store variant: App Sandbox ON via the MAS
# entitlements file. Same sources — only the entitlements differ.
ENTITLEMENTS="$ROOT/$APP_NAME.entitlements"
if [[ " $* " == *" --mas "* ]]; then
  ENTITLEMENTS="$ROOT/$APP_NAME-MAS.entitlements"
  echo "▶ MAS variant: App Sandbox ON ($ENTITLEMENTS)"
fi
LOCAL_ID="${LOCAL_ID:-SnapDesk Dev}"
if [ -n "$DEV_ID" ]; then
  echo "▶ Signing with Developer ID + hardened runtime…"
  codesign --force --deep --timestamp \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEV_ID" "$APP"
elif security find-certificate -c "$LOCAL_ID" >/dev/null 2>&1; then
  echo "▶ Signing with stable local identity '$LOCAL_ID' (permissions persist across rebuilds)…"
  codesign --force --deep \
    --entitlements "$ENTITLEMENTS" \
    --sign "$LOCAL_ID" "$APP"
else
  echo "▶ Ad-hoc signing (no stable identity; Screen-Recording grant resets each build)…"
  echo "   Tip: run ./make-signing-cert.sh once so permissions stick."
  codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

# --- Build the DMG (optional: ./build.sh --dmg) ------------------------------
# Day-to-day testing does NOT need a DMG — it just clutters build/ with extra
# copies. Only build one when explicitly asked (for distribution).
if [[ " $* " == *" --dmg "* ]]; then
  echo "▶ Building DMG…"
  DMG_ROOT="$BUILD/dmgroot"
  mkdir -p "$DMG_ROOT"
  cp -R "$APP" "$DMG_ROOT/"
  ln -s /Applications "$DMG_ROOT/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"
  rm -rf "$DMG_ROOT"   # don't leave a second app copy lying around in build/

  if [ -n "$DEV_ID" ] && [ -n "$NOTARY_PROFILE" ]; then
    echo "▶ Notarizing (this can take a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "▶ Stapling ticket…"
    xcrun stapler staple "$DMG"
    xcrun stapler staple "$APP"
    echo "✅ Notarized DMG ready — installs with no warning."
  else
    echo "ℹ️  DMG built without Apple notarization (fine for your own Mac)."
  fi
fi

# --- Update THE one installed app (default; skip with --no-install) ----------
# There is exactly one canonical app you test: /Applications/SnapDesk.app.
# Every build quits it, replaces it in place, and relaunches — no second copy,
# no duplicate menu-bar icon. Stable signature ⇒ permissions persist.
if [[ " $* " != *" --no-install "* ]]; then
  echo "▶ Updating /Applications/$APP_NAME.app (the app you test)…"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" 2>/dev/null || true
  echo "✅ Updated. Launching…"
  open "/Applications/$APP_NAME.app"
fi

echo ""
echo "✅ Done. Tested app: /Applications/$APP_NAME.app"
[[ " $* " == *" --dmg "* ]] && echo "   DMG: $DMG"
echo "   (build/ holds only the freshly compiled .app; ./build.sh updates the installed copy in place.)"
