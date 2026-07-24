#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="com.sshstudio.app"
APP_NAME="SSH Studio.app"
ACTION="install"
DRY_RUN="true"
CANDIDATE=""
DESTINATION_APP="/Users/shabir/Applications/$APP_NAME"
ROLLBACK_DIR=""
BACKUP_DIR_OVERRIDE=""

usage() {
  cat <<USAGE
Usage:
  Scripts/install-app.sh --dry-run --candidate ".artifacts/SSH Studio.app" --destination "/Users/shabir/Applications/SSH Studio.app"
  Scripts/install-app.sh --install --candidate ".artifacts/SSH Studio.app" --destination "/Users/shabir/Applications/SSH Studio.app" [--backup-dir "/Users/shabir/Applications/SSH Studio Backups/<timestamp>"]
  Scripts/install-app.sh --rollback "/Users/shabir/Applications/SSH Studio Backups/<timestamp>" [--dry-run]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app|--candidate)
      CANDIDATE="$2"; shift 2 ;;
    --dest)
      DESTINATION_APP="$2/$APP_NAME"; shift 2 ;;
    --destination)
      DESTINATION_APP="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN="true"; shift ;;
    --install)
      ACTION="install"; DRY_RUN="false"; shift ;;
    --rollback)
      ACTION="rollback"; ROLLBACK_DIR="$2"; shift 2 ;;
    --backup-dir)
      BACKUP_DIR_OVERRIDE="$2"; shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

canonical_path() {
  python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=False))' "$1"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_matching_sha256() {
  local first="$1"
  local second="$2"
  local first_hash second_hash
  first_hash="$(sha256 "$first")"
  second_hash="$(sha256 "$second")"
  [[ "$first_hash" == "$second_hash" ]] || {
    echo "Checksum mismatch: $first and $second" >&2
    exit 1
  }
}

verify_app() {
  local app="$1"
  [[ -d "$app" ]] || { echo "Missing application bundle: $app" >&2; exit 1; }
  [[ -x "$app/Contents/MacOS/SSHStudio" ]] || { echo "Missing SSHStudio executable" >&2; exit 1; }
  [[ -f "$app/Contents/Resources/SSHStudio.icns" ]] || { echo "Missing application icon" >&2; exit 1; }
  [[ -f "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle/Shaders.metal" ]] || { echo "Missing SwiftTerm Shaders.metal" >&2; exit 1; }
  [[ -x "$app/Contents/Helpers/SSHStudioAskPass" ]] || { echo "Missing AskPass helper" >&2; exit 1; }
  local actual_id
  actual_id="$(plist_value "$app" CFBundleIdentifier)"
  [[ "$actual_id" == "$BUNDLE_ID" ]] || { echo "Bundle identifier mismatch: $actual_id" >&2; exit 1; }
  codesign --verify --deep --strict --verbose=2 "$app" >/dev/null
}

verify_existing_app() {
  local app="$1"
  [[ -d "$app" ]] || return 0
  [[ -x "$app/Contents/MacOS/SSHStudio" ]] || { echo "Installed app is missing executable" >&2; exit 1; }
  [[ -f "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle/Shaders.metal" ]] || { echo "Installed app is missing SwiftTerm shaders" >&2; exit 1; }
  local actual_id
  actual_id="$(plist_value "$app" CFBundleIdentifier)"
  [[ "$actual_id" == "$BUNDLE_ID" ]] || { echo "Installed bundle identifier mismatch: $actual_id" >&2; exit 1; }
  codesign --verify --deep --strict --verbose=2 "$app" >/dev/null
}

refuse_running_destination() {
  local app="$1"
  if pgrep -f "$app/Contents/MacOS/SSHStudio" >/dev/null 2>&1; then
    echo "Refusing to install over a running SSH Studio instance: $app" >&2
    exit 1
  fi
}

refuse_stale_candidate() {
  local candidate="$1"
  if [[ -d .git ]] && [[ -n "$(git status --short)" ]]; then
    echo "Repository has uncommitted changes; refusing to install a potentially stale candidate." >&2
    exit 1
  fi
  python3 - "$candidate" <<'PY'
from pathlib import Path
import subprocess
import sys
candidate = Path(sys.argv[1])
stamp = candidate / "Contents" / "Info.plist"
if not stamp.exists():
    sys.exit("Candidate Info.plist missing.")
try:
    files = subprocess.check_output(["git", "ls-files"], text=True).splitlines()
except Exception:
    sys.exit(0)
stamp_time = stamp.stat().st_mtime
newer = [f for f in files if Path(f).exists() and Path(f).stat().st_mtime > stamp_time]
if newer:
    sys.exit("Candidate is older than tracked source files; rebuild before installing.")
PY
}

backup_root_for() {
  local destination="$1"
  dirname "$destination"
}

timestamp() {
  date -u +%Y%m%dT%H%M%SZ
}

write_manifest() {
  local backup_dir="$1"
  local candidate="$2"
  local destination="$3"
  local manifest="$backup_dir/migration-manifest.txt"
  {
    echo "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "candidate=$candidate"
    echo "destination=$destination"
    echo "candidate_identifier=$(plist_value "$candidate" CFBundleIdentifier)"
    echo "candidate_version=$(plist_value "$candidate" CFBundleShortVersionString)"
    echo "candidate_build=$(plist_value "$candidate" CFBundleVersion)"
    if [[ -d "$backup_dir/$APP_NAME" ]]; then
      echo "backup_executable_sha256=$(sha256 "$backup_dir/$APP_NAME/Contents/MacOS/SSHStudio")"
    fi
    echo "candidate_executable_sha256=$(sha256 "$candidate/Contents/MacOS/SSHStudio")"
    echo "keychain_secret_values_exported=false"
  } > "$manifest"
  chmod 600 "$manifest"
}

write_rollback_script() {
  local backup_dir="$1"
  local destination="$2"
  local script="$backup_dir/rollback.sh"
  cat > "$script" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
"$(canonical_path "$0")" --rollback "$backup_dir" --destination "$destination"
SCRIPT
  chmod 700 "$script"
}

print_plan() {
  local candidate="$1"
  local destination="$2"
  local backup_dir="$3"
  echo "action=$ACTION"
  echo "dry_run=$DRY_RUN"
  echo "candidate=$candidate"
  echo "destination=$destination"
  echo "candidate_identifier=$(plist_value "$candidate" CFBundleIdentifier)"
  echo "candidate_version=$(plist_value "$candidate" CFBundleShortVersionString)"
  echo "candidate_build=$(plist_value "$candidate" CFBundleVersion)"
  if [[ -d "$destination" ]]; then
    echo "installed_identifier=$(plist_value "$destination" CFBundleIdentifier)"
    echo "installed_version=$(plist_value "$destination" CFBundleShortVersionString)"
    echo "installed_build=$(plist_value "$destination" CFBundleVersion)"
  else
    echo "installed_present=false"
  fi
  echo "backup_destination=$backup_dir"
  echo "rollback_command=Scripts/install-app.sh --rollback '$backup_dir' --destination '$destination' --dry-run"
  echo "planned_operations=validate,candidate_stage,backup_existing,rename_staged,verify_installed"
  echo "gatekeeper_note=ad-hoc builds are local validation builds and are not publicly distributable."
}

rollback() {
  local backup_dir destination current_backup
  backup_dir="$(canonical_path "$ROLLBACK_DIR")"
  destination="$(canonical_path "$DESTINATION_APP")"
  current_backup="$backup_dir/$APP_NAME"
  [[ -d "$current_backup" ]] || { echo "Rollback backup app missing: $current_backup" >&2; exit 1; }
  verify_existing_app "$current_backup"
  refuse_running_destination "$destination"
  echo "rollback_backup=$backup_dir"
  echo "rollback_destination=$destination"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "rollback_dry_run=true"
    return 0
  fi
  local displaced="$backup_dir/displaced-current-$(timestamp).app"
  if [[ -e "$destination" ]]; then
    mv "$destination" "$displaced"
  fi
  ditto "$current_backup" "$destination"
  verify_existing_app "$destination"
  echo "rollback_complete=true"
}

if [[ "$ACTION" == "rollback" ]]; then
  rollback
  exit 0
fi

[[ -n "$CANDIDATE" ]] || { echo "--candidate is required" >&2; usage >&2; exit 2; }
CANDIDATE="$(canonical_path "$CANDIDATE")"
DESTINATION_APP="$(canonical_path "$DESTINATION_APP")"
BACKUP_ROOT="$(backup_root_for "$DESTINATION_APP")/SSH Studio Backups"
if [[ -n "$BACKUP_DIR_OVERRIDE" ]]; then
  BACKUP_DIR="$(canonical_path "$BACKUP_DIR_OVERRIDE")"
else
  BACKUP_DIR="$BACKUP_ROOT/$(timestamp)"
fi
STAGING_APP="$(dirname "$DESTINATION_APP")/.SSH Studio.app.installing.$(timestamp).$$"

verify_app "$CANDIDATE"
verify_existing_app "$DESTINATION_APP"
refuse_running_destination "$DESTINATION_APP"
refuse_stale_candidate "$CANDIDATE"
print_plan "$CANDIDATE" "$DESTINATION_APP" "$BACKUP_DIR"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "dry_run=true"
  exit 0
fi

umask 077
if [[ -e "$BACKUP_DIR" ]]; then
  echo "Backup directory already exists; refusing to overwrite: $BACKUP_DIR" >&2
  exit 1
fi
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if [[ -d "$DESTINATION_APP" ]]; then
  ditto "$DESTINATION_APP" "$BACKUP_DIR/$APP_NAME"
  verify_existing_app "$BACKUP_DIR/$APP_NAME"
  verify_matching_sha256 "$DESTINATION_APP/Contents/MacOS/SSHStudio" "$BACKUP_DIR/$APP_NAME/Contents/MacOS/SSHStudio"
fi

PREFS="/Users/shabir/Library/Preferences/com.sshstudio.app.plist"
SUPPORT="/Users/shabir/Library/Application Support/SSH Studio"
if [[ -f "$PREFS" ]]; then
  ditto "$PREFS" "$BACKUP_DIR/com.sshstudio.app.plist"
  chmod 600 "$BACKUP_DIR/com.sshstudio.app.plist"
fi
if [[ -d "$SUPPORT" ]]; then
  ditto "$SUPPORT" "$BACKUP_DIR/Application Support"
fi
write_manifest "$BACKUP_DIR" "$CANDIDATE" "$DESTINATION_APP"
write_rollback_script "$BACKUP_DIR" "$DESTINATION_APP"

ditto "$CANDIDATE" "$STAGING_APP"
verify_app "$STAGING_APP"

if [[ -d "$DESTINATION_APP" ]]; then
  mv "$DESTINATION_APP" "$BACKUP_DIR/installed-before-replacement.app"
  verify_existing_app "$BACKUP_DIR/installed-before-replacement.app"
  verify_matching_sha256 "$BACKUP_DIR/$APP_NAME/Contents/MacOS/SSHStudio" "$BACKUP_DIR/installed-before-replacement.app/Contents/MacOS/SSHStudio"
fi

if ! mv "$STAGING_APP" "$DESTINATION_APP"; then
  if [[ -d "$BACKUP_DIR/installed-before-replacement.app" ]]; then
    mv "$BACKUP_DIR/installed-before-replacement.app" "$DESTINATION_APP"
  fi
  exit 1
fi

if ! verify_app "$DESTINATION_APP"; then
  if [[ -d "$DESTINATION_APP" ]]; then
    mv "$DESTINATION_APP" "$BACKUP_DIR/failed-install.app"
  fi
  if [[ -d "$BACKUP_DIR/installed-before-replacement.app" ]]; then
    mv "$BACKUP_DIR/installed-before-replacement.app" "$DESTINATION_APP"
  fi
  exit 1
fi

echo "installed=$DESTINATION_APP"
echo "backup=$BACKUP_DIR"
