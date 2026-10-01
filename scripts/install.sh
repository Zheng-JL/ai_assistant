#!/bin/bash
# Build, verify, then replace the installed app. The old version is only touched after the new
# one has passed every check, and it is restored automatically if the new one fails to start.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${CODEX_STATUS_INSTALL_DIR:-$HOME/Applications}"
NAME="搭子.app"
LEGACY_NAMES=("小哨.app" "Codex Status.app")   # earlier names; they share one bundle identifier
INSTALLED="$DEST/$NAME"
BACKUP_DIR="$HOME/Library/Application Support/Codex Status/previous"
EXEC="Contents/MacOS/CodexStatus"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Launch Services keys apps by bundle identifier. Stray copies (build output, backups) that stay
# registered can be picked instead of the installed one, which for example loses the notification icon.
unregister() { [[ -x "$LSREGISTER" && -d "$1" ]] && "$LSREGISTER" -u "$1" >/dev/null 2>&1 || true; }

fail() { printf 'install failed: %s\n' "$1" >&2; exit 1; }

OUT="$(mktemp -d /tmp/codex-status-package.XXXXXX)"
CODEX_STATUS_OUTPUT="$OUT" bash "$ROOT/scripts/build-app.sh" || fail "build or tests failed; installed app left untouched"
NEW="$OUT/$NAME"
[[ -d "$NEW" ]] || fail "built app is missing; installed app left untouched"
codesign --verify --deep --strict "$NEW" || fail "signature check failed; installed app left untouched"

mkdir -p "$DEST"
STAGED="$INSTALLED.new"
rm -rf "$STAGED"
ditto --norsrc --noextattr "$NEW" "$STAGED" || fail "copy failed; installed app left untouched"
codesign --verify --deep --strict "$STAGED" || { rm -rf "$STAGED"; fail "copied app failed signature check; installed app left untouched"; }

# Every previous copy: the current name first, then the earlier names.
OLD_APPS=("$INSTALLED")
for legacy in "${LEGACY_NAMES[@]}"; do OLD_APPS+=("$DEST/$legacy"); done

unregister "$BACKUP_DIR"/*.app 2>/dev/null || true
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
for old in "${OLD_APPS[@]}"; do
    # Zipped so the backup is never registered as an app.
    [[ -d "$old" ]] && { ditto -c -k --keepParent --norsrc --noextattr "$old" "$BACKUP_DIR/$(basename "$old").zip" || fail "could not back up $old; nothing replaced"; }
done

# All names share one bundle identifier, so every old copy must be stopped before launching.
for old in "${OLD_APPS[@]}"; do pkill -f "$old/$EXEC" 2>/dev/null || true; done
sleep 1
for old in "${OLD_APPS[@]}"; do
    rm -rf "$old.old"
    [[ -d "$old" ]] && mv "$old" "$old.old"
done
mv "$STAGED" "$INSTALLED"
open "$INSTALLED"
sleep 4

if pgrep -f "$INSTALLED/$EXEC" >/dev/null; then
    for old in "${OLD_APPS[@]}"; do unregister "$old.old"; rm -rf "$old.old"; done
    unregister "$NEW"
    rm -rf "$OUT"
    printf 'Installed and running: %s\nPrevious version kept at: %s\n' "$INSTALLED" "$BACKUP_DIR"
else
    pkill -f "$INSTALLED/$EXEC" 2>/dev/null || true
    rm -rf "$INSTALLED"
    reopened=""
    for old in "${OLD_APPS[@]}"; do
        if [[ -d "$old.old" ]]; then
            mv "$old.old" "$old"
            [[ -z "$reopened" ]] && { open "$old"; reopened=1; }
        fi
    done
    fail "new version did not start; the previous version was restored"
fi
