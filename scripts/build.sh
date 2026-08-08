#!/bin/bash
# Build the RazerBatteryMenuBar executable.
#
# Prefers SwiftPM (`swift build -c release`). Falls back to compiling the
# sources directly with `swiftc` when SwiftPM's ManifestAPI is unavailable
# (e.g. a half-updated Command Line Tools install). Either way the binary lands
# at .build/release/RazerBatteryMenuBar.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="RazerBatteryMenuBar"
OUT_DIR="$ROOT/.build/release"
BIN="$OUT_DIR/$NAME"
SRC=("$ROOT"/Sources/$NAME/*.swift)

mkdir -p "$OUT_DIR"

if swift build -c release >/dev/null 2>&1 && [ -x "$BIN" ]; then
    echo "Built with SwiftPM -> $BIN"
    exit 0
fi

echo "SwiftPM build unavailable; compiling directly with swiftc…"
swiftc -O \
    -target arm64-apple-macos13.0 \
    -o "$BIN" \
    "${SRC[@]}" \
    -framework AppKit \
    -framework IOKit \
    -framework CoreAudio \
    -framework ServiceManagement

echo "Built with swiftc -> $BIN"
