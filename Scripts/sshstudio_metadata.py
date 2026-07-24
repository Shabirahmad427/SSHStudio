#!/usr/bin/env python3
import json
import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
METADATA_PATH = ROOT / "Config" / "ReleaseMetadata.json"
INFO_PLIST_PATH = ROOT / "Sources" / "SSHStudio" / "Resources" / "Info.plist"


def load_metadata(path=METADATA_PATH):
    with open(path, "r", encoding="utf-8") as handle:
        metadata = json.load(handle)
    validate_metadata(metadata)
    return metadata


def validate_metadata(metadata):
    required = [
        "bundleIdentifier",
        "bundleName",
        "bundleDisplayName",
        "executableName",
        "shortVersion",
        "buildNumber",
        "minimumMacOSVersion",
        "iconFile",
        "copyright",
    ]
    missing = [key for key in required if not str(metadata.get(key, "")).strip()]
    if missing:
        raise ValueError(f"Missing release metadata: {', '.join(missing)}")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", metadata["bundleIdentifier"]):
        raise ValueError("Invalid bundle identifier")
    if not re.fullmatch(r"\d+\.\d+\.\d+", metadata["shortVersion"]):
        raise ValueError("shortVersion must be semantic version MAJOR.MINOR.PATCH")
    if not re.fullmatch(r"[1-9][0-9]*", metadata["buildNumber"]):
        raise ValueError("buildNumber must be a positive integer string")
    if not re.fullmatch(r"\d+\.\d+", metadata["minimumMacOSVersion"]):
        raise ValueError("minimumMacOSVersion must use MAJOR.MINOR")


def generated_info_plist(metadata):
    return {
        "CFBundleIdentifier": metadata["bundleIdentifier"],
        "CFBundleName": metadata["bundleName"],
        "CFBundleExecutable": metadata["executableName"],
        "CFBundleDisplayName": metadata["bundleDisplayName"],
        "CFBundleVersion": metadata["buildNumber"],
        "CFBundleShortVersionString": metadata["shortVersion"],
        "CFBundlePackageType": "APPL",
        "CFBundleIconFile": metadata["iconFile"],
        "LSMinimumSystemVersion": metadata["minimumMacOSVersion"],
        "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": True,
        "NSHumanReadableCopyright": metadata["copyright"],
        "SSHStudioUpdateManifestURL": "",
        "SSHStudioUpdatePublicKey": "",
    }


def validate_source_info_plist(metadata, path=INFO_PLIST_PATH):
    with open(path, "rb") as handle:
        plist = plistlib.load(handle)
    expected = generated_info_plist(metadata)
    checked_keys = [
        "CFBundleIdentifier",
        "CFBundleName",
        "CFBundleExecutable",
        "CFBundleDisplayName",
        "CFBundleVersion",
        "CFBundleShortVersionString",
        "CFBundlePackageType",
        "CFBundleIconFile",
        "NSPrincipalClass",
        "NSHighResolutionCapable",
    ]
    mismatches = [
        key for key in checked_keys
        if plist.get(key) != expected.get(key)
    ]
    if mismatches:
        raise ValueError(f"Info.plist metadata mismatch: {', '.join(mismatches)}")


def write_info_plist(path, metadata):
    with open(path, "wb") as handle:
        plistlib.dump(generated_info_plist(metadata), handle, sort_keys=False)


if __name__ == "__main__":
    metadata = load_metadata()
    validate_source_info_plist(metadata)
    print(json.dumps(metadata, sort_keys=True))
