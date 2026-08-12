#!/bin/bash
#
# SnapDesk: build an Apple Silicon (arm64, M-series) .app, sign it, package a
# release ZIP, and (optionally) notarize it so it installs with NO warning.
#
# Run on a Mac with Xcode command-line tools installed (`xcode-select --install`).
# No Xcode project required: this compiles the sources directly with swiftc.
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
ZIP="$BUILD/$APP_NAME.zip"

DEV_ID="${DEV_ID:-}"                 # Developer ID Application identity, or empty for ad-hoc
NOTARY_PROFILE="${NOTARY_PROFILE:-}" # notarytool keychain profile name, or empty to skip

# Which entitlements the build signs with. Decided here because Xcode signs
# during the build, before the re-signing step below gets a say.
ENTITLEMENTS_FOR_XCODE="$ROOT/$APP_NAME.entitlements"
if [[ " $* " == *" --mas "* ]]; then
  ENTITLEMENTS_FOR_XCODE="$ROOT/$APP_NAME-MAS.entitlements"
fi

echo "▶ Cleaning…"
rm -rf "$BUILD"
# Only the output directory. The bundle itself is Xcode's to create: pre-making
# the .app made `cp -R` nest a second copy inside it.
mkdir -p "$BUILD"

# --- Build the bundle with Xcode ---------------------------------------------
# Xcode owns the bundle now. It used to be assembled here by hand: a directory
# tree, a copied Info.plist, two swiftc invocations and a lipo. That worked
# until the plist was missing a key Apple's own tooling would always have
# written, and the app aborted days later inside ViewBridge with nothing of ours
# in the stack. Six of nine recorded crashes were that one omission.
#
# The project file is checked in. Regenerate it after adding or moving sources:
#   ./tools/make-xcodeproj.py
#
# `generic/platform=macOS` is what makes it universal: without it xcodebuild
# builds for this machine's architecture alone, and an arm64-only build does not
# launch on an Intel Mac.
DERIVED="$BUILD/xcode"
echo "▶ Building with Xcode (universal: arm64 + x86_64)…"
xcodebuild \
  -project "$ROOT/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS_FOR_XCODE" \
  build > "$BUILD/xcodebuild.log" 2>&1 || {
    echo "❌ Build failed. Last lines of $BUILD/xcodebuild.log:" >&2
    tail -30 "$BUILD/xcodebuild.log" >&2
    exit 1
  }

cp -R "$DERIVED/Build/Products/Release/$APP_NAME.app" "$APP"
BIN="$APP/Contents/MacOS/$APP_NAME"
echo "▶ Binary architectures: $(lipo -archs "$BIN")"

# The bundle Xcode produced, checked rather than trusted. These are the keys a
# hand-written plist forgot; Apple's tooling writes them, and this says so out
# loud rather than assuming.
for key in CFBundleIdentifier CFBundleExecutable CFBundleName CFBundleVersion \
           CFBundleShortVersionString CFBundlePackageType CFBundleDevelopmentRegion \
           CFBundleInfoDictionaryVersion LSMinimumSystemVersion; do
  if ! /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "❌ Info.plist is missing $key. Add it to Resources/Info.plist." >&2
    exit 1
  fi
done

# Bundled sounds live in Resources/Sounds, which is where `Sounds.swift` looks
# first. A flattened copy only works through its fallback.
if [ ! -f "$APP/Contents/Resources/Sounds/SnapIn.wav" ]; then
  echo "❌ Sounds/ did not make it into the bundle." >&2
  exit 1
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
# entitlements file. Same sources; only the entitlements differ.
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

# --- Build the release ZIP (optional: ./build.sh --zip) ----------------------
# Day-to-day testing does NOT need one; it just clutters build/ with extra
# copies. Only build one when explicitly asked (for distribution).
if [[ " $* " == *" --zip "* ]]; then
  echo "▶ Building release ZIP…"
  # ditto preserves the code signature exactly (zip(1) can subtly break
  # signed bundles).
  ditto -c -k --keepParent "$APP" "$ZIP"

  if [ -n "$DEV_ID" ] && [ -n "$NOTARY_PROFILE" ]; then
    echo "▶ Notarizing (this can take a few minutes)…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "▶ Stapling ticket…"
    xcrun stapler staple "$APP"
    # Re-zip so the stapled ticket ships inside the archive.
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "✅ Notarized ZIP ready. Installs with no warning."
  else
    echo "ℹ️  ZIP built without Apple notarization (fine for your own Mac)."
  fi
fi

# --- Update THE one installed app (default; skip with --no-install) ----------
# There is exactly one canonical app you test: /Applications/SnapDesk.app.
# Every build quits it, replaces it in place, and relaunches, so there is no second copy,
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
[[ " $* " == *" --zip "* ]] && echo "   ZIP: $ZIP"
echo "   (build/ holds only the freshly compiled .app; ./build.sh updates the installed copy in place.)"
