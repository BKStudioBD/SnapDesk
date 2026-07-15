#!/bin/bash
#
# SnapDesk — fast correctness test.
#
# Runs the full Swift compiler front-end (type-checking, name resolution, and
# API validation) over every source file WITHOUT codegen or linking. This is the
# fastest reliable way to verify the app compiles cleanly: it catches essentially
# every error that matters in a few seconds, with no .app or .dmg produced.
#
# Run on a Mac with command-line tools: ./test.sh
#
set -euo pipefail

MIN_MACOS="14.0"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES=$(find "$ROOT" -name '*.swift' -not -path "*/build/*" -not -path "*/tools/*")

echo "▶ Type-checking $(echo "$SOURCES" | wc -l | tr -d ' ') Swift files (arm64, macOS ${MIN_MACOS})…"
xcrun -sdk macosx swiftc \
  -parse-as-library \
  -typecheck \
  -target "arm64-apple-macos${MIN_MACOS}" \
  -sdk "$SDK" \
  $SOURCES

echo "✅ All sources type-check cleanly. Now run ./build.sh to produce the .dmg."
