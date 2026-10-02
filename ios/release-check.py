"""Offline release checks. Never loads Apple credentials. Python standard library only."""
import argparse
import json
import plistlib
import re
import struct
import subprocess
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def source_checks(root):
    config = json.loads((root / "release/testflight.json").read_text(encoding="utf-8"))
    info = plistlib.loads((root / "TaipeiBus/Info.plist").read_bytes())
    privacy = plistlib.loads((root / "TaipeiBus/PrivacyInfo.xcprivacy").read_bytes())
    project = (root / "TaipeiBus.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    require(info["ITSAppUsesNonExemptEncryption"] is False, "Reassess encryption before declaring an exemption.")
    require(bool(info.get("NSLocationWhenInUseUsageDescription")), "Location purpose string is missing.")
    require(not info.get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads"), "Unexpected insecure transport exception.")
    require(privacy["NSPrivacyTracking"] is False, "Tracking declaration changed; review privacy details.")
    reasons = {entry["NSPrivacyAccessedAPIType"]: entry["NSPrivacyAccessedAPITypeReasons"]
               for entry in privacy["NSPrivacyAccessedAPITypes"]}
    require("CA92.1" in reasons.get("NSPrivacyAccessedAPICategoryUserDefaults", []), "UserDefaults reason missing.")
    require("C617.1" in reasons.get("NSPrivacyAccessedAPICategoryFileTimestamp", []), "Cache timestamp reason missing.")
    require(f'MARKETING_VERSION = {config["version"]};' in project, "Project and release-config versions differ.")
    require("TARGETED_DEVICE_FAMILY = 1;" in project, "Review the supported device family.")
    require("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" in project, "App icon is not configured.")
    icon_set = root / "TaipeiBus/Assets.xcassets/AppIcon.appiconset"
    icon_metadata = json.loads((icon_set / "Contents.json").read_text(encoding="utf-8"))
    icon = icon_set / icon_metadata["images"][0]["filename"]
    raw = icon.read_bytes()
    require(raw[:8] == b"\x89PNG\r\n\x1a\n", "App icon must be PNG.")
    require(struct.unpack(">II", raw[16:24]) == (1024, 1024), "App Store icon must be 1024 × 1024.")
    offset, chunks = 8, []
    while offset + 12 <= len(raw):
        length = struct.unpack(">I", raw[offset:offset + 4])[0]
        chunks.append(raw[offset + 4:offset + 8])
        offset += length + 12
    require(raw[25] == 2 and b"tRNS" not in chunks, "App Store icon must be RGB without transparency.")
    for field in ("description_file", "what_to_test_file"):
        require(bool((root / "release" / config[field]).read_text(encoding="utf-8").strip()), f"Missing {field}.")
    require(re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", config["bundle_id"]), "Invalid release Bundle ID.")
    require(not config["bundle_id"].startswith("com.example."), "Release config still has a placeholder Bundle ID.")
    return config


def archive_checks(archive, bundle_id, version, build_number, minimum_sdk):
    index = plistlib.loads((archive / "Info.plist").read_bytes())
    app = archive / "Products" / index["ApplicationProperties"]["ApplicationPath"]
    require(app.resolve().is_relative_to(archive.resolve()), "Unexpected archive application path.")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == bundle_id, "Archive Bundle ID mismatch.")
    require(info["CFBundleShortVersionString"] == version, "Archive marketing version mismatch.")
    require(info["CFBundleVersion"] == build_number, "Archive build number mismatch.")
    require("iPhoneOS" in info["CFBundleSupportedPlatforms"], "Cannot upload a simulator build.")
    require(int(info["DTPlatformVersion"].split(".")[0]) >= minimum_sdk, "Upload SDK is too old.")
    require((app / "PrivacyInfo.xcprivacy").is_file(), "Privacy manifest missing from the actual archive.")
    require(info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") == "AppIcon", "Compiled app icon missing.")
    executable = (app / info["CFBundleExecutable"]).read_bytes()
    require(b"--preview-capture" not in executable, "Debug preview flags leaked into the Release binary.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    require(any((archive / "dSYMs").glob("TaipeiBus.app.dSYM")), "Release debug symbols are missing.")
    print(f"Verified signed iPhone archive: {bundle_id}, {version} ({build_number}), SDK {info['DTPlatformVersion']}")
    manifests = list(app.rglob("PrivacyInfo.xcprivacy"))
    print(f"Bundled privacy manifests: {len(manifests)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--bundle-id")
    parser.add_argument("--version")
    parser.add_argument("--build-number")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    config = source_checks(root)
    print("Offline release checks passed: icon, privacy, location, version, platform and beta copy.")
    print("Apple membership, app record, signing and TestFlight availability still require account checks.")
    if args.archive:
        require(all((args.bundle_id, args.version, args.build_number)), "Archive identity arguments are required.")
        archive_checks(args.archive.resolve(), args.bundle_id, args.version, args.build_number, config["minimum_upload_sdk"])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Release check failed: {error}")
