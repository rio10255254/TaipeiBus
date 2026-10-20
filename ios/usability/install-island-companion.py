"""Install a simulator-only second app to exercise the real minimal island.

Two activities owned by one app may still be presented as one compact island.
The companion uses the exact DEBUG app and widget under a different bundle ID.
It is created only in the runner's temporary directory and is never archived.
"""
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

source, destination, device = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
assert source.name == "TaipeiBus.app" and source.is_dir()
assert not destination.exists(), "Do not overwrite another simulator app"
shutil.copytree(source, destination)

def update(path, values, remove=()):
    data = plistlib.loads(path.read_bytes())
    data.update(values)
    for key in remove:
        data.pop(key, None)
    path.write_bytes(plistlib.dumps(data))

bundle = "com.example.TaipeiBus.IslandCompanion"
update(destination / "Info.plist",
       {"CFBundleIdentifier": bundle, "CFBundleDisplayName": "Island Test Companion"},
       ["CFBundleURLTypes"])
for extension in (destination / "PlugIns").glob("*.appex"):
    update(extension / "Info.plist", {"CFBundleIdentifier": bundle + ".Widgets"})
subprocess.run(["xcrun", "simctl", "install", device, str(destination)], check=True)
