#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="com.sshstudio.app"
APP_NAME="SSH Studio.app"
ACTION="install"
DRY_RUN="true"
ALLOW_INVALID_EXISTING_SIGNATURE="false"
CANDIDATE=""
DESTINATION_APP="/Users/shabir/Applications/$APP_NAME"
ROLLBACK_DIR=""
BACKUP_DIR_OVERRIDE=""
EXPECTED_DESTINATION_APP="/Users/shabir/Applications/$APP_NAME"
VALIDATED_ROLLBACK_SOURCE="/Users/shabir/Applications/SSH Studio Backups/20260724T010540Z/SSH Studio.app"

usage() {
  cat <<USAGE
Usage:
  Scripts/install-app.sh --dry-run --candidate ".artifacts/SSH Studio.app" --destination "/Users/shabir/Applications/SSH Studio.app"
  Scripts/install-app.sh --dry-run --allow-invalid-existing-signature --candidate ".artifacts/SSH Studio.app" --destination "/Users/shabir/Applications/SSH Studio.app"
  Scripts/install-app.sh --install --candidate ".artifacts/SSH Studio.app" --destination "/Users/shabir/Applications/SSH Studio.app" [--allow-invalid-existing-signature] [--backup-dir "/Users/shabir/Applications/SSH Studio Backups/<timestamp>"]
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
    --allow-invalid-existing-signature)
      ALLOW_INVALID_EXISTING_SIGNATURE="true"; shift ;;
    --validated-rollback-source)
      VALIDATED_ROLLBACK_SOURCE="$2"; shift 2 ;;
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

signature_failure_for_app() {
  local app="$1"
  codesign --verify --deep --strict --verbose=4 "$app" >/dev/null 2>&1 && return 0
  codesign --verify --deep --strict --verbose=4 "$app" 2>&1 >/dev/null || true
}

file_hashes_for_bundle() {
  local app="$1"
  local output="$2"
  (
    cd "$app"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
  ) > "$output"
}

verify_bundle_hashes_match() {
  local first="$1"
  local second="$2"
  local first_hashes second_hashes
  first_hashes="$(mktemp)"
  second_hashes="$(mktemp)"
  file_hashes_for_bundle "$first" "$first_hashes"
  file_hashes_for_bundle "$second" "$second_hashes"
  cmp -s "$first_hashes" "$second_hashes" || {
    echo "Backup bundle hashes do not match original." >&2
    exit 1
  }
  rm -f "$first_hashes" "$second_hashes"
}

verify_validated_rollback_source() {
  local source="$1"
  [[ -d "$source" ]] || { echo "Validated rollback source missing: $source" >&2; exit 1; }
  verify_existing_app "$source"
  [[ "$(plist_value "$source" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || {
    echo "Validated rollback source bundle identifier mismatch." >&2
    exit 1
  }
}

verify_preserved_invalid_backup() {
  local app="$1"
  local backup_dir="$2"
  local failure_file="$backup_dir/installed-signature-failure.txt"
  local hashes_file="$backup_dir/installed-bundle-sha256.txt"
  [[ -f "$failure_file" ]] || return 1
  [[ -f "$hashes_file" ]] || return 1
  [[ -s "$failure_file" ]] || { echo "Invalid backup signature failure record is empty." >&2; exit 1; }
  local current_hashes
  current_hashes="$(mktemp)"
  file_hashes_for_bundle "$app" "$current_hashes"
  cmp -s "$hashes_file" "$current_hashes" || {
    echo "Preserved invalid backup hashes do not match manifest." >&2
    exit 1
  }
  rm -f "$current_hashes"
  [[ "$(plist_value "$app" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || {
    echo "Preserved invalid backup bundle identifier mismatch." >&2
    exit 1
  }
  [[ -x "$app/Contents/MacOS/SSHStudio" ]] || { echo "Preserved invalid backup executable missing." >&2; exit 1; }
}

verify_rollback_backup_app() {
  local app="$1"
  local backup_dir="$2"
  if verify_existing_app "$app"; then
    return 0
  fi
  verify_preserved_invalid_backup "$app" "$backup_dir" || {
    echo "Rollback backup app is invalid and lacks verified preservation metadata." >&2
    exit 1
  }
}

validate_invalid_existing_override() {
  local destination="$1"
  local failure="$2"
  [[ "$ALLOW_INVALID_EXISTING_SIGNATURE" == "true" ]] || {
    echo "Existing installed app has an invalid signature. Re-run with --allow-invalid-existing-signature only after reviewing the integrity failure." >&2
    echo "$failure" >&2
    exit 1
  }
  [[ "$destination" == "$(canonical_path "$EXPECTED_DESTINATION_APP")" ]] || {
    echo "--allow-invalid-existing-signature is limited to the exact SSH Studio destination path." >&2
    exit 1
  }
  [[ ! -L "$destination" ]] || { echo "Refusing override because destination is a symlink." >&2; exit 1; }
  [[ -x "$destination/Contents/MacOS/SSHStudio" ]] || { echo "Installed executable missing." >&2; exit 1; }
  [[ "$(plist_value "$destination" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || {
    echo "Refusing override because installed bundle identifier is not $BUNDLE_ID." >&2
    exit 1
  }
  file "$destination/Contents/MacOS/SSHStudio" | grep -q "arm64" || {
    echo "Refusing override because installed executable is not arm64." >&2
    exit 1
  }
  refuse_running_destination "$destination"
  verify_validated_rollback_source "$(canonical_path "$VALIDATED_ROLLBACK_SOURCE")"
  echo "WARNING: proceeding with invalid existing SSH Studio signature override." >&2
  echo "installed_signature_failure=$failure" >&2
  echo "validated_rollback_source=$(canonical_path "$VALIDATED_ROLLBACK_SOURCE")"
  echo "invalid_existing_signature_override=true"
}

verify_existing_app_or_allowed_invalid() {
  local app="$1"
  [[ -d "$app" ]] || return 0
  local failure
  if failure="$(signature_failure_for_app "$app")"; [[ -z "$failure" ]]; then
    verify_existing_app "$app"
    return 0
  fi
  validate_invalid_existing_override "$app" "$failure"
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
package_inputs = (
    "Package.swift",
    "Package.resolved",
    "Config/",
    "Sources/",
    "Scripts/build-app.sh",
    "Scripts/sshstudio_metadata.py",
)
try:
    dirty = subprocess.check_output(["git", "status", "--short", "--", *package_inputs], text=True).strip()
except Exception:
    dirty = ""
if dirty:
    sys.exit("Repository has uncommitted package-input changes; refusing to install a potentially stale candidate.")
stamp_time = stamp.stat().st_mtime
newer = [
    f for f in files
    if f.startswith(package_inputs) and Path(f).exists() and Path(f).stat().st_mtime > stamp_time
]
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
  echo "candidate_executable_sha256=$(sha256 "$candidate/Contents/MacOS/SSHStudio")"
  if [[ -d "$backup_dir/$APP_NAME" ]]; then
    echo "installed_identifier=$(plist_value "$backup_dir/$APP_NAME" CFBundleIdentifier)"
    echo "installed_version=$(plist_value "$backup_dir/$APP_NAME" CFBundleShortVersionString)"
    echo "installed_build=$(plist_value "$backup_dir/$APP_NAME" CFBundleVersion)"
    echo "backup_executable_sha256=$(sha256 "$backup_dir/$APP_NAME/Contents/MacOS/SSHStudio")"
    if [[ -f "$backup_dir/installed-signature-failure.txt" ]]; then
      echo "installed_signature_failure_file=installed-signature-failure.txt"
    fi
    if [[ -f "$backup_dir/installed-bundle-sha256.txt" ]]; then
      echo "installed_bundle_hashes_file=installed-bundle-sha256.txt"
    fi
  fi
  echo "created_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "rollback_source=$VALIDATED_ROLLBACK_SOURCE"
  echo "rollback_instruction=Scripts/install-app.sh --rollback '$backup_dir' --destination '$destination' --dry-run"
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
  echo "allow_invalid_existing_signature=$ALLOW_INVALID_EXISTING_SIGNATURE"
  echo "validated_rollback_source=$(canonical_path "$VALIDATED_ROLLBACK_SOURCE")"
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
  verify_rollback_backup_app "$current_backup" "$backup_dir"
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
verify_existing_app_or_allowed_invalid "$DESTINATION_APP"
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
  EXISTING_SIGNATURE_FAILURE="$(signature_failure_for_app "$DESTINATION_APP")"
  if [[ -n "$EXISTING_SIGNATURE_FAILURE" ]]; then
    validate_invalid_existing_override "$DESTINATION_APP" "$EXISTING_SIGNATURE_FAILURE"
  fi
  ditto "$DESTINATION_APP" "$BACKUP_DIR/$APP_NAME"
  file_hashes_for_bundle "$BACKUP_DIR/$APP_NAME" "$BACKUP_DIR/installed-bundle-sha256.txt"
  if [[ -n "$EXISTING_SIGNATURE_FAILURE" ]]; then
    printf '%s\n' "$EXISTING_SIGNATURE_FAILURE" > "$BACKUP_DIR/installed-signature-failure.txt"
    verify_bundle_hashes_match "$DESTINATION_APP" "$BACKUP_DIR/$APP_NAME"
  else
    verify_existing_app "$BACKUP_DIR/$APP_NAME"
  fi
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
  if [[ -f "$BACKUP_DIR/installed-signature-failure.txt" ]]; then
    verify_bundle_hashes_match "$BACKUP_DIR/$APP_NAME" "$BACKUP_DIR/installed-before-replacement.app"
  else
    verify_existing_app "$BACKUP_DIR/installed-before-replacement.app"
  fi
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
