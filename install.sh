#!/bin/bash
#
# SnapDesk one-command installer.
#
#   curl -fsSL https://raw.githubusercontent.com/BKStudioBD/SnapDesk/main/install.sh | bash
#
# Downloads the latest release ZIP, installs SnapDesk into /Applications, and
# removes the quarantine flag so macOS opens it with NO Gatekeeper warning and
# NO right-click-Open dance. (Stripping quarantine on your OWN machine for an
# app you chose to install is exactly what right-click -> Open does; this just
# scripts it. It does not disable Gatekeeper system-wide.)
#
set -euo pipefail

REPO="BKStudioBD/SnapDesk"
APP="SnapDesk"
ZIP_URL="https://github.com/${REPO}/releases/latest/download/${APP}.zip"
DEST="/Applications/${APP}.app"

# Declared up front so the EXIT trap can reference it safely under `set -u`.
TMP=""
cleanup() {
  [ -n "${TMP}" ] && rm -rf "${TMP}"
}
trap cleanup EXIT

echo "==> Downloading ${APP}..."
TMP="$(mktemp -d)"
ZIP="${TMP}/${APP}.zip"
curl -fsSL "${ZIP_URL}" -o "${ZIP}"

echo "==> Unpacking..."
# ditto preserves the code signature and resource forks exactly (unzip can
# subtly break signed .app bundles).
ditto -x -k "${ZIP}" "${TMP}/unpacked"
if [ ! -d "${TMP}/unpacked/${APP}.app" ]; then
  echo "Error: could not unpack the download." >&2
  exit 1
fi

# Quit a running copy so it can be replaced.
osascript -e "tell application \"${APP}\" to quit" >/dev/null 2>&1 || true
pkill -x "${APP}" 2>/dev/null || true
sleep 1

# Verify the signature BEFORE trusting the download. Stripping the Gatekeeper
# quarantine flag disables the OS's own check, so this script must do that check
# itself — otherwise a tampered or man-in-the-middled ZIP installs silently with
# every warning suppressed.
echo "==> Verifying the code signature..."
if ! codesign --verify --deep --strict "${TMP}/unpacked/${APP}.app" 2>/dev/null; then
  echo "REFUSING TO INSTALL: ${APP}.app has no valid code signature." >&2
  echo "The download may be corrupt or tampered with. Delete it and fetch again." >&2
  exit 1
fi
codesign -dv "${TMP}/unpacked/${APP}.app" 2>&1 | sed -n 's/^Authority=/    signed by: /p' | head -1

echo "==> Installing to /Applications..."
rm -rf "${DEST}"
cp -R "${TMP}/unpacked/${APP}.app" "${DEST}"

# Only now — with the signature verified above — remove the quarantine flag.
echo "==> Clearing the Gatekeeper quarantine flag..."
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true

echo "==> Opening ${APP}..."
open "${DEST}"

echo "Done. ${APP} is installed with no Gatekeeper warning and lives in your menu bar."
