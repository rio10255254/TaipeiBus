"""Boot one disposable iPhone and preserve bounded, diagnosable simctl calls."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

simctl = subprocess.check_output(["xcrun", "--find", "simctl"], text=True).strip()


def run(*args, timeout=60, capture=False):
    print("Simulator command:", " ".join(args), flush=True)
    return subprocess.run([simctl, *args], check=True, timeout=timeout, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


phase = sys.argv[1] if len(sys.argv) > 1 else "all"
assert phase in ("prepare", "launch", "all"), "Expected prepare or launch"
if phase != "launch":
    runtimes = json.loads(run("list", "runtimes", "-j", capture=True))["runtimes"]
    runtimes = [r for r in runtimes if r.get("isAvailable") and "iOS 26" in r["name"]]
    assert runtimes, "iOS 26 simulator unavailable"
    runtime = max(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))["identifier"]
    device = run("create", "TaipeiBus-AI", "com.apple.CoreSimulator.SimDeviceType.iPhone-17", runtime, capture=True).strip()
    with open(os.environ["GITHUB_ENV"], "a") as env_file:
        env_file.write(f"AI_SIMULATOR={device}\n")
    if phase == "prepare":
        sys.exit(0)
else:
    device = os.environ["AI_SIMULATOR"]
temporary = Path(os.environ["RUNNER_TEMP"])
app = str(temporary / "ai-build/Build/Products/Debug-iphonesimulator/TaipeiBus.app")
run("boot", device)
# A fresh iOS 26 runtime on the standard Intel runner migrates its system data
# for several minutes. Restarting during that migration only delays readiness.
run("bootstatus", device, "-b", timeout=600)
for attempt in range(2):
    try:
        run("install", device, app, timeout=180)
        break
    except subprocess.TimeoutExpired:
        if attempt:
            raise
        # The repository's existing preview workflow uses the same recovery for
        # a hosted CoreSimulator installation RPC that stalls after a fresh boot.
        print("Restarting this disposable simulator after an installation RPC timeout.", flush=True)
        run("shutdown", device, timeout=120)
        run("boot", device)
        run("bootstatus", device, "-b", timeout=180)
container = Path(run("get_app_container", device, "com.example.TaipeiBus", "data", timeout=180, capture=True).strip())
token = uuid.uuid4().hex
run("launch", device, "com.example.TaipeiBus", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
    "--test-language", "zh-Hant", "--usability-fixture", "--preview-journey-search", "--preview-capture", token,
    timeout=180)
marker = container / "Documents/transit-preview-ready"
deadline = time.monotonic() + 90
while not marker.exists() or marker.read_text() != token:
    if time.monotonic() >= deadline:
        raise RuntimeError("The app did not reach its requested preview state.")
    time.sleep(1)
print("App confirmed the requested journey-search preview is ready.", flush=True)
# Let the already initialized SwiftUI hierarchy present its first frame.
time.sleep(2)
run("io", device, "screenshot", str(temporary / "ai-simulator.png"), timeout=180)
