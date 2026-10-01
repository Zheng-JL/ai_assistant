#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${CODEX_STATUS_BUILD_CACHE:-/tmp/codex-status-build}"
# Keep signed bundles outside iCloud/File Provider folders, which can add FinderInfo.
OUT="${CODEX_STATUS_OUTPUT:-$(mktemp -d /tmp/codex-status-package.XXXXXX)}"
APP="$OUT/搭子.app"

if [[ -e "$APP" ]]; then
    printf 'Output already exists; select a new CODEX_STATUS_OUTPUT directory: %s\n' "$APP" >&2
    exit 1
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/codex-status-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/codex-status-swift-cache}"
swift test --package-path "$ROOT" --scratch-path "$CACHE"
swift build -c release --package-path "$ROOT" --scratch-path "$CACHE"
BIN="$(swift build -c release --package-path "$ROOT" --scratch-path "$CACHE" --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist"
cp -X "$BIN/CodexStatus" "$APP/Contents/MacOS/CodexStatus"
cp -X "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -X "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# A new build number per build: macOS caches app icons (notification banners included) by bundle
# identifier and version, so an unchanged version keeps showing an old or blank icon.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ROOT/dist/Buddy-macOS-$(uname -m).zip"
printf '\nApp: %s\n' "$APP"
