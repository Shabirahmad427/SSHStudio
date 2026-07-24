#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="release"
SIGN_MODE="unsigned"
IDENTITY=""
OUTPUT_DIR="$ROOT_DIR/.artifacts"
APP_NAME="SSH Studio.app"
METADATA_JSON="$ROOT_DIR/Config/ReleaseMetadata.json"
ENTITLEMENTS="$ROOT_DIR/Config/SSHStudio.entitlements"

usage() {
  cat <<USAGE
Usage: Scripts/build-app.sh [--configuration release|debug] [--sign unsigned|ad-hoc|developer-id] [--identity "Developer ID Application: ..."] [--output-dir PATH]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      CONFIGURATION="$2"; shift 2 ;;
    --sign)
      SIGN_MODE="$2"; shift 2 ;;
    --identity)
      IDENTITY="$2"; shift 2 ;;
    --output-dir)
      OUTPUT_DIR="$2"; shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$CONFIGURATION" in
  release|debug) ;;
  *) echo "Invalid configuration: $CONFIGURATION" >&2; exit 2 ;;
esac
case "$SIGN_MODE" in
  unsigned|ad-hoc|developer-id) ;;
  *) echo "Invalid sign mode: $SIGN_MODE" >&2; exit 2 ;;
esac

python3 "$ROOT_DIR/Scripts/sshstudio_metadata.py" >/dev/null

if [[ "$CONFIGURATION" == "release" ]]; then
  swift build -c release
  BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/release"
else
  swift build
  BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/debug"
fi

EXECUTABLE="$BUILD_DIR/SSHStudio"
ASKPASS_EXECUTABLE="$BUILD_DIR/SSHStudioAskPass"
SWIFTTERM_BUNDLE="$BUILD_DIR/SwiftTerm_SwiftTerm.bundle"
ICON="$ROOT_DIR/Sources/SSHStudio/Resources/SSHStudio.icns"

[[ -x "$EXECUTABLE" ]] || { echo "Missing executable: $EXECUTABLE" >&2; exit 1; }
[[ -x "$ASKPASS_EXECUTABLE" ]] || { echo "Missing AskPass helper: $ASKPASS_EXECUTABLE" >&2; exit 1; }
[[ -d "$SWIFTTERM_BUNDLE" ]] || { echo "Missing SwiftTerm resource bundle" >&2; exit 1; }
[[ -f "$SWIFTTERM_BUNDLE/Shaders.metal" ]] || { echo "Missing SwiftTerm Shaders.metal" >&2; exit 1; }
[[ -f "$ICON" ]] || { echo "Missing application icon" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
APP="$OUTPUT_DIR/$APP_NAME"
if [[ -e "$APP" ]]; then
  echo "Refusing to assemble over existing bundle: $APP" >&2
  exit 1
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/Helpers"
cp "$EXECUTABLE" "$APP/Contents/MacOS/SSHStudio"
cp "$ASKPASS_EXECUTABLE" "$APP/Contents/Helpers/SSHStudioAskPass"
cp "$ICON" "$APP/Contents/Resources/SSHStudio.icns"
cp -R "$SWIFTTERM_BUNDLE" "$APP/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
SSHSTUDIO_ROOT="$ROOT_DIR" python3 - "$APP/Contents/Info.plist" <<'PY'
import sys
import os
from pathlib import Path
sys.path.insert(0, str(Path(os.environ["SSHSTUDIO_ROOT"]) / "Scripts"))
import sshstudio_metadata
metadata = sshstudio_metadata.load_metadata()
sshstudio_metadata.write_info_plist(sys.argv[1], metadata)
PY
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod 755 "$APP/Contents/MacOS/SSHStudio"
chmod 755 "$APP/Contents/Helpers/SSHStudioAskPass"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")" == "SSHStudio" ]] || {
  echo "CFBundleExecutable mismatch" >&2; exit 1;
}
[[ -f "$APP/Contents/Resources/SwiftTerm_SwiftTerm.bundle/Shaders.metal" ]] || {
  echo "Packaged SwiftTerm shaders missing" >&2; exit 1;
}

sign_item() {
  local item="$1"
  case "$SIGN_MODE" in
    unsigned)
      return 0 ;;
    ad-hoc)
      codesign --force --sign - "$item" ;;
    developer-id)
      [[ -n "$IDENTITY" ]] || { echo "--identity is required for developer-id signing" >&2; exit 2; }
      codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$item" ;;
  esac
}

sign_item "$APP/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
sign_item "$APP/Contents/Helpers/SSHStudioAskPass"
sign_item "$APP/Contents/MacOS/SSHStudio"
sign_item "$APP"

if [[ "$SIGN_MODE" != "unsigned" ]]; then
  codesign --verify --strict --verbose=2 "$APP"
  codesign -d --entitlements :- "$APP" >/dev/null 2>&1 || true
  spctl --assess --type execute --verbose "$APP" || true
fi

echo "$APP"
