#!/bin/bash
#
# Headless render test for the annotation tools. Compiles AnnotationRenderer
# together with tools/selftest.swift and draws every tool onto a synthetic
# screenshot, writing one PNG per tool to the output dir. Verifies the drawing
# pipeline without launching the GUI.
#
#   ./test-tools.sh            # writes to /tmp/snapdesk-tools
#   ./test-tools.sh <outdir>
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-/tmp/snapdesk-tools}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
BIN="$(mktemp -d)/selftest"

echo "▶ Compiling render self-test…"
xcrun -sdk macosx swiftc -O \
  -target "arm64-apple-macos14.0" -sdk "$SDK" \
  "$ROOT/Features/Screenshot/AnnotationRenderer.swift" \
  "$ROOT/tools/main.swift" \
  -o "$BIN"

echo "▶ Rendering each tool…"
"$BIN" "$OUT"
echo ""
echo "PNGs:"
ls -1 "$OUT"
