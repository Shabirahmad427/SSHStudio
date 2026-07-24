#!/usr/bin/env bash
set -euo pipefail

APP=""
PROFILE="${NOTARYTOOL_PROFILE:-SSHStudio}"
DRY_RUN=0

usage() {
  cat <<USAGE
Usage: Scripts/notarize-app.sh --app "path/to/SSH Studio.app" [--profile SSHStudio] [--dry-run]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -d "$APP" ]] || { echo "--app must point to an application bundle" >&2; exit 2; }
codesign --verify --deep --strict --verbose=2 "$APP"

if ! xcrun notarytool history --keychain-profile "$PROFILE" --output-format json >/dev/null 2>&1; then
  echo "Notary credentials are unavailable for keychain profile '$PROFILE'." >&2
  echo "Create them with: xcrun notarytool store-credentials $PROFILE" >&2
  [[ "$DRY_RUN" == "1" ]] && exit 0
  exit 1
fi

ARCHIVE="$(dirname "$APP")/$(basename "$APP" .app)-notarize.zip"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run complete: $ARCHIVE"
  exit 0
fi

xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "$ARCHIVE"
