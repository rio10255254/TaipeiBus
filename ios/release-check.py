"""Offline release checks. Never loads Apple credentials. Python standard library only."""
import argparse
import json
import plistlib
import re
import struct
import gzip
import hashlib
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
    if tuple(map(int, config["version"].split("."))) >= (1,3,0):
        provenance = json.loads((root / "release/bus-static-provenance.json").read_text(encoding="utf-8"))
        for feed in provenance["feeds"]:
            raw = (root / "TaipeiBus/BusMetadata" / (feed["name"] + ".gz")).read_bytes()
            require(hashlib.sha256(raw).hexdigest() == feed["sha256"], "Bundled bus metadata provenance mismatch")
            decoded = gzip.decompress(raw)
            require(len(decoded) <= 32 * 1024 * 1024, "Bundled metadata exceeds its size limit")
            rows = json.loads(decoded)
            rows = rows if isinstance(rows,list) else rows.get("BusInfo",[])
            require(len(rows) == feed["rows"], "Bundled static metadata row count changed")
    bikes = json.loads((root / "TaipeiBus/BikeNetwork.json").read_text(encoding="utf-8"))
    bike_provenance = json.loads((root / "release/youbike-data-provenance.json").read_text(encoding="utf-8"))
    require(bikes["schema"] == 1 and len(bikes["stations"]) >= 1000, "Bundled YouBike station list is incomplete.")
    require(len(bikes["stations"]) == bike_provenance["stations"], "Bundled YouBike station count does not match its provenance.")
    require(len({station["id"] for station in bikes["stations"]}) == len(bikes["stations"]), "Duplicate YouBike station IDs.")
    live_fields = {"available_rent_bikes", "available_return_bikes", "infoTime", "srcUpdateTime"}
    # The service area is the regions the app bundles (release/service_area.py reads the same file).
    regions = json.loads((root / "TransitCore/Sources/TransitCore/Regions/regions.json").read_text(encoding="utf-8"))
    boxes = [box for region in regions["regions"] for box in region["bounds"]]
    require(regions["home"] in {region["id"] for region in regions["regions"]}, "The home region is not defined.")
    require(all(source["feed"].startswith("https://") for source in regions["sources"]), "Region feeds must be https.")
    for station in bikes["stations"]:
        require(not live_fields & set(station), "Live YouBike counts must not be bundled with the app.")
        latitude, longitude = station["coordinate"]["latitude"], station["coordinate"]["longitude"]
        require(any(south <= latitude <= north and west <= longitude <= east for south, west, north, east in boxes),
                "Bundled YouBike station outside the service area.")
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
    store_copy = json.loads((root / "release/app-store.zh-Hant.json").read_text(encoding="utf-8"))
    # App Store Connect's documented version-information limits. Review notes and
    # keywords use UTF-8 bytes, unlike the character limits on customer-facing copy.
    for field, maximum in {"name": 30, "subtitle": 30, "description": 4000,
                           "promotionalText": 170, "whatsNew": 4000}.items():
        require(0 < len(store_copy[field]) <= maximum, f"App Store {field} exceeds its {maximum}-character limit.")
    for field, maximum in {"keywords": 100, "reviewNotes": 4000}.items():
        require(0 < len(store_copy[field].encode("utf-8")) <= maximum,
                f"App Store {field} exceeds its {maximum}-byte limit.")
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
    require(not list(app.rglob("*.storekit")), "Local payment test products must not enter the distributed app.")
    require(info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") == "AppIcon", "Compiled app icon missing.")
    if tuple(map(int, version.split("."))) >= (1,3,0):
        require((app / "MetroNetwork.json").is_file(), "Metro metadata missing from signed archive")
        for name in ["GetRoute","GetStop","GetPathDetail","GetProvider","GetBusShape"]:
            require((app / "BusMetadata" / (name + ".gz")).is_file(), "Static bus fallback missing from signed archive: " + name)
    if tuple(map(int, version.split("."))) >= (1, 8, 0):
        bike_file = app / "BikeNetwork.json"
        require(bike_file.is_file(), "YouBike station list missing from signed archive")
        require(bike_file.stat().st_size <= 4 * 1024 * 1024, "Bundled YouBike data exceeds its verified size limit.")
        bikes = json.loads(bike_file.read_text(encoding="utf-8"))
        require(bikes.get("schema") == 1 and len(bikes.get("stations", [])) >= 1000,
                "The archive does not contain the verified YouBike station list.")
    if tuple(map(int, version.split("."))) >= (1, 1, 9):
        catalog_file = app / "OfficialTravelTimes.json"
        require(catalog_file.is_file(), "The actual archive is missing shared official travel times.")
        require(catalog_file.stat().st_size <= 32 * 1024 * 1024, "Bundled official data exceeds its verified size limit.")
        catalog = json.loads(catalog_file.read_text(encoding="utf-8"))
        require(catalog.get("schema") == 1 and len(catalog.get("routes", [])) >= 100,
                "The archive does not contain the verified full-route catalog.")
        require(str(catalog.get("source", "")).startswith("https://tdx.transportdata.tw/"), "Official source attribution missing.")
        require(not any(key in catalog for key in ("client_id", "client_secret", "access_token", "password")),
                "Authentication fields are not allowed in the public travel-time data.")
        print(f"Bundled official travel profiles: {len(catalog['routes'])}")
    if tuple(map(int, version.split("."))) >= (1, 6, 0):
        widgets = app / "PlugIns" / "TaipeiBusWidgets.appex"
        require((widgets / "Info.plist").is_file(), "The widget and Live Activity extension is missing from the archive.")
        extension = plistlib.loads((widgets / "Info.plist").read_bytes())
        require(extension["CFBundleIdentifier"] == bundle_id + ".Widgets", "Widget extension Bundle ID mismatch.")
        require(extension["CFBundleShortVersionString"] == version and extension["CFBundleVersion"] == build_number,
                "Widget extension version must match the app.")
        require(extension.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
                "Widget extension point missing.")
        require(info.get("NSSupportsLiveActivities") is True, "Live Activities are not enabled for the app.")
        group = info.get("BusSharedKeychainGroup", "")
        require(group.endswith("." + bundle_id + ".shared") and group == extension.get("BusSharedKeychainGroup"),
                "The app and widget must share one keychain group.")
        # The signed binaries, not just Info.plist, must carry the shared group, or the widget
        # cannot read saved trips on a real phone.
        for bundle in (app, widgets):
            signed = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)],
                                    capture_output=True, check=True).stdout
            groups = plistlib.loads(signed).get("keychain-access-groups", []) if signed.strip() else []
            require(group in groups, f"{bundle.name} is not signed with the shared keychain group.")
        print(f"Widget extension and shared keychain group verified: {group.split('.', 1)[1]}")
    executable = (app / info["CFBundleExecutable"]).read_bytes()
    require(b"--preview-island" not in executable and b"--island-walking" not in executable,
            "Island rendering audit controls must never enter the distributed app.")
    require(b"--preview-capture" not in executable, "Debug preview flags leaked into the Release binary.")
    require(b"--preview-metro-fixture" not in executable and b"--preview-mixed-planning" not in executable and b"QA-TRAIN-01" not in executable,
            "Metro verification fixtures must never enter the distributed app.")
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
