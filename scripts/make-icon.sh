#!/bin/bash
# Regenerates Resources/AppIcon.icns from the artwork in Sources/CodexStatusApp/IconArt.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${CODEX_STATUS_BUILD_CACHE:-/tmp/codex-status-build}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/codex-status-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/codex-status-swift-cache}"
swift build --package-path "$ROOT" --scratch-path "$CACHE" >/dev/null
BIN="$(swift build --package-path "$ROOT" --scratch-path "$CACHE" --show-bin-path)/CodexStatus"
TMP="$(mktemp -d /tmp/codex-status-icon.XXXXXX)"
"$BIN" --make-icon "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
rm -rf "$TMP"
printf 'Wrote %s\n' "$ROOT/Resources/AppIcon.icns"
