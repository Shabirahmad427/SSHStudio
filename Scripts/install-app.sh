#!/usr/bin/env bash
set -euo pipefail

SOURCE_APP=""
DEST_DIR="/Users/shabir/Applications"
BUNDLE_ID="com.sshstudio.app"

usage() {
  cat <<USAGE
Usage: Scripts/install-app.sh --app ".artifacts/SSH Studio.app" [--dest /Users/shabir/Applications]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) SOURCE_APP="$2"; shift 2 ;;
    --dest) DEST_DIR="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -d "$SOURCE_APP" ]] || { echo "--app must point to an application bundle" >&2; exit 2; }
codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"

ACTUAL_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")"
[[ "$ACTUAL_ID" == "$BUNDLE_ID" ]] || {
  echo "Bundle identifier mismatch: $ACTUAL_ID" >&2
  exit 1
}

DEST_APP="$DEST_DIR/SSH Studio.app"
if pgrep -f "$DEST_APP/Contents/MacOS/SSHStudio" >/dev/null 2>&1; then
  echo "Refusing to overwrite a running SSH Studio installation." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
BACKUP=""
if [[ -e "$DEST_APP" ]]; then
  BACKUP="$DEST_DIR/SSH Studio.app.backup.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -R "$DEST_APP" "$BACKUP"
fi

TEMP_DEST="$DEST_DIR/.SSH Studio.app.installing.$$"
rm -rf "$TEMP_DEST"
cp -R "$SOURCE_APP" "$TEMP_DEST"
codesign --verify --deep --strict --verbose=2 "$TEMP_DEST"

if [[ -e "$DEST_APP" ]]; then
  rm -rf "$DEST_APP"
fi
mv "$TEMP_DEST" "$DEST_APP"

echo "Installed: $DEST_APP"
if [[ -n "$BACKUP" ]]; then
  echo "Backup: $BACKUP"
  echo "Rollback: rm -rf '$DEST_APP' && mv '$BACKUP' '$DEST_APP'"
fi
