#!/bin/bash
#
# SnapDesk one-command installer.
#
#   curl -fsSL https://raw.githubusercontent.com/BKStudioBD/SnapDesk/main/install.sh | bash
#
# Downloads the latest release DMG, installs SnapDesk into /Applications, and
# removes the quarantine flag so macOS opens it with NO Gatekeeper warning and
# NO right-click-Open dance. (Stripping quarantine on your OWN machine for an
# app you chose to install is exactly what right-click -> Open does; this just
# scripts it. It does not disable Gatekeeper system-wide.)
#
set -euo pipefail

REPO="BKStudioBD/SnapDesk"
APP="SnapDesk"
DMG_URL="https://github.com/${REPO}/releases/latest/download/${APP}.dmg"
DEST="/Applications/${APP}.app"

# Declared up front so the EXIT trap can reference them safely under `set -u`.
TMP=""
MOUNT=""
cleanup() {
  [ -n "${MOUNT}" ] && hdiutil detach "${MOUNT}" -quiet 2>/dev/null || true
  [ -n "${TMP}" ] && rm -rf "${TMP}"
}
trap cleanup EXIT

echo "==> Downloading ${APP}..."
TMP="$(mktemp -d)"
DMG="${TMP}/${APP}.dmg"
curl -fsSL "${DMG_URL}" -o "${DMG}"

echo "==> Mounting..."
MOUNT="$(hdiutil attach "${DMG}" -nobrowse -noverify -quiet | grep -o '/Volumes/.*' | head -1)"
if [ -z "${MOUNT}" ] || [ ! -d "${MOUNT}/${APP}.app" ]; then
  echo "Error: could not mount the disk image." >&2
  exit 1
fi

# Quit a running copy so it can be replaced.
osascript -e "tell application \"${APP}\" to quit" >/dev/null 2>&1 || true
pkill -x "${APP}" 2>/dev/null || true
sleep 1

echo "==> Installing to /Applications..."
rm -rf "${DEST}"
cp -R "${MOUNT}/${APP}.app" "${DEST}"

echo "==> Clearing the Gatekeeper quarantine flag..."
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true

echo "==> Opening ${APP}..."
open "${DEST}"

echo "Done. ${APP} is installed with no Gatekeeper warning and lives in your menu bar."
