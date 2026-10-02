"""Install a reusable App Store signing identity on an ephemeral macOS runner."""
import base64
import hashlib
import json
import os
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path
from urllib.request import urlopen


def validate_profile(profile, team, bundle, now=None):
    now = now or datetime.utcnow()
    if team not in profile.get("TeamIdentifier", []):
        raise ValueError("App Store profile belongs to a different Apple team.")
    entitlements = profile.get("Entitlements", {})
    if entitlements.get("application-identifier") != f"{team}.{bundle}":
        raise ValueError("App Store profile does not match the app's Bundle ID.")
    if entitlements.get("get-task-allow") is not False or "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices"):
        raise ValueError("A TestFlight build requires an App Store distribution profile.")
    if profile.get("ExpirationDate", now) <= now + timedelta(days=7):
        raise ValueError("App Store profile expires within seven days.")
    uuid = profile.get("UUID", "")
    if not re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", uuid):
        raise ValueError("Invalid provisioning profile UUID.")
    certificates = profile.get("DeveloperCertificates", [])
    if len(certificates) != 1 or not isinstance(certificates[0], bytes):
        raise ValueError("App Store profile must contain one distribution certificate.")
    return uuid, hashlib.sha1(certificates[0]).hexdigest().upper()


def command(arguments, redact=()):
    result = subprocess.run(arguments, capture_output=True)
    if result.returncode:
        message = result.stderr.decode("utf-8", errors="replace")
        for value in redact:
            if value:
                message = message.replace(value, "[redacted]")
        raise ValueError(f"{Path(arguments[0]).name} failed: {message.strip()}")
    return result.stdout


def install(directory):
    required = ("APPLE_DISTRIBUTION_P12", "APPLE_DISTRIBUTION_PASSWORD", "APPLE_APP_STORE_PROFILE")
    if any(not os.environ.get(name) for name in required):
        raise ValueError("Configure App Store signing with ios/Configure-Distribution.ps1 first.")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    p12, profile_path = directory / "distribution.p12", directory / "app-store.mobileprovision"
    for name, path in ((required[0], p12), (required[2], profile_path)):
        path.write_bytes(base64.b64decode(os.environ[name].strip(), validate=True))
        path.chmod(0o600)
    profile = plistlib.loads(command(["/usr/bin/security", "cms", "-D", "-i", str(profile_path)]))
    uuid, certificate = validate_profile(profile, os.environ["APPLE_TEAM_ID"], os.environ["BUS_BUNDLE_ID"])
    keychain = directory / "distribution.keychain-db"
    previous = shlex.split(command(["/usr/bin/security", "list-keychains", "-d", "user"]).decode())
    metadata = {"previous_keychains": previous, "installed_profiles": []}
    metadata_path = directory / "signing-installation.json"
    metadata_path.write_text(json.dumps(metadata))
    keychain_password = secrets.token_hex(32)
    password = os.environ[required[1]].strip()
    print(f"::add-mask::{keychain_password}", flush=True)
    redactions = (password, keychain_password)
    command(["/usr/bin/security", "create-keychain", "-p", keychain_password, str(keychain)], redactions)
    command(["/usr/bin/security", "set-keychain-settings", "-lut", "21600", str(keychain)])
    command(["/usr/bin/security", "unlock-keychain", "-p", keychain_password, str(keychain)], redactions)
    command(["/usr/bin/security", "import", str(p12), "-P", password, "-k", str(keychain),
             "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"], redactions)
    # Apple Distribution certificates use Apple's WWDR G3 intermediate.
    intermediate = directory / "AppleWWDRCAG3.cer"
    with urlopen("https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer", timeout=30) as response:
        intermediate.write_bytes(response.read())
    command(["/usr/bin/security", "import", str(intermediate), "-k", str(keychain)])
    command(["/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
             "-s", "-k", keychain_password, str(keychain)], redactions)
    command(["/usr/bin/security", "list-keychains", "-d", "user", "-s", str(keychain), *previous])
    identities = command(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning", str(keychain)]).decode()
    if certificate not in identities.upper():
        raise ValueError("The installed signing key does not match the profile's distribution certificate.")
    # Support both provisioning-profile locations used by recent Xcode versions.
    for root in (Path.home() / "Library/MobileDevice/Provisioning Profiles",
                 Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"):
        root.mkdir(parents=True, exist_ok=True)
        destination = root / f"{uuid}.mobileprovision"
        if destination.exists():
            if destination.read_bytes() != profile_path.read_bytes():
                raise ValueError("An existing provisioning profile has conflicting contents.")
            continue
        metadata["installed_profiles"].append(str(destination))
        metadata_path.write_text(json.dumps(metadata))
        shutil.copyfile(profile_path, destination)
        destination.chmod(0o600)
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write(f"BUS_PROFILE_UUID={uuid}\nBUS_SIGNING_CERTIFICATE_SHA1={certificate}\n")
    print("App Store distribution signing is ready; no registered test devices are required.")


def cleanup(directory):
    metadata_path = directory / "signing-installation.json"
    failures = []
    if metadata_path.exists():
        metadata = json.loads(metadata_path.read_text())
        try:
            command(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *metadata["previous_keychains"]])
        except ValueError:
            failures.append("Could not restore the original keychain search list.")
        roots = {Path.home() / "Library/MobileDevice/Provisioning Profiles",
                 Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"}
        for value in metadata["installed_profiles"]:
            path = Path(value)
            if path.parent in roots and re.fullmatch(r"[A-Fa-f0-9-]{36}\.mobileprovision", path.name):
                path.unlink(missing_ok=True)
            else:
                failures.append("Unexpected provisioning profile cleanup path.")
    keychain = directory / "distribution.keychain-db"
    if keychain.exists():
        try:
            command(["/usr/bin/security", "delete-keychain", str(keychain)])
        except ValueError:
            failures.append("Could not remove the temporary distribution keychain.")
    for name in ("AuthKey.p8", "distribution.p12", "app-store.mobileprovision", "AppleWWDRCAG3.cer", "signing-installation.json"):
        (directory / name).unlink(missing_ok=True)
    if failures:
        raise ValueError(" ".join(failures))
    print("Temporary signing files and provisioning profiles removed.")


if __name__ == "__main__":
    try:
        directory = Path(os.environ["RUNNER_TEMP"]) / "bus-signing"
        if sys.argv[1:] == ["install"]:
            install(directory)
        elif sys.argv[1:] == ["cleanup"]:
            cleanup(directory)
        else:
            raise ValueError("Usage: signing.py install|cleanup")
    except (ValueError, KeyError, OSError) as error:
        raise SystemExit(f"Distribution signing failed: {error}")
