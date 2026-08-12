#!/bin/bash
#
# Headless stress test for the window teardown that produced three of this
# app's crash reports. Compiles the app's own sources together with
# tools/stress/main.swift, so the code under test is the shipping code.
#
#   ./tools/stress/run.sh 50          # current code
#   ./tools/stress/run.sh 50 --old    # the path that was replaced
#
# A crash is the finding. Reaching the end is the pass.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CYCLES="${1:-50}"
MODE="${2:-}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Everything except the @main entry point, which would fight ours.
SOURCES=$(find "$ROOT/App" "$ROOT/Capture" "$ROOT/Features" "$ROOT/Hotkeys" \
               "$ROOT/Settings" "$ROOT/Support" -name '*.swift' \
               -not -name 'SnapDeskApp.swift')

echo "▶ Compiling the harness…"
xcrun -sdk macosx swiftc \
  -O \
  -target "arm64-apple-macos14.0" \
  $SOURCES "$ROOT/tools/stress/main.swift" \
  -o "$OUT/stress" 2>&1 | grep -E "error:" && exit 1

echo "▶ Running…"
"$OUT/stress" "$CYCLES" $MODE
status=$?
if [ $status -eq 0 ]; then
  echo "✅ no crash in $CYCLES cycles"
else
  echo "❌ died with status $status after fewer than $CYCLES cycles"
fi
exit $status
