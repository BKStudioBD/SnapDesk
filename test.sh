#!/bin/bash
#
# SnapDesk — fast correctness test.
#
# Runs the full Swift compiler front-end (type-checking, name resolution, and
# API validation) over every source file WITHOUT codegen or linking. This is the
# fastest reliable way to verify the app compiles cleanly: it catches essentially
# every error that matters in a few seconds, with no .app or archive produced.
#
# Run on a Mac with command-line tools: ./test.sh
#
set -euo pipefail

MIN_MACOS="14.0"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES=$(find "$ROOT" -name '*.swift' -not -path "*/build/*" -not -path "*/tools/*" -not -path "*/Tests/*" -not -path "*/.build/*" -not -name "Package.swift")

echo "▶ Type-checking $(echo "$SOURCES" | wc -l | tr -d ' ') Swift files (arm64, macOS ${MIN_MACOS})…"
xcrun -sdk macosx swiftc \
  -parse-as-library \
  -typecheck \
  -target "arm64-apple-macos${MIN_MACOS}" \
  -sdk "$SDK" \
  $SOURCES

echo "✅ All sources type-check cleanly."

# Unit tests (Swift Testing, via the test-only Package.swift). These cover the
# pure-logic types — classification, hex parsing, hotkey encoding, the mic
# sample-buffer conversion — and need no microphone, screen or permission.
echo "▶ Running unit tests…"
swift test 2>&1 | grep -E "^(✔|✘|→).*|Test run|error:" || true
swift test >/dev/null 2>&1 || { echo "❌ Unit tests FAILED (run: swift test)"; exit 1; }

echo "✅ Type-check + unit tests pass. Now run ./build.sh to build and install the app."
