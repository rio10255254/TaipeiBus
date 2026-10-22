"""Boot one disposable iPhone and preserve bounded, diagnosable simctl calls."""
import json
import os
from pathlib import Path
import subprocess

simctl = subprocess.check_output(["xcrun", "--find", "simctl"], text=True).strip()


def run(*args, timeout=60, capture=False):
    print("Simulator command:", " ".join(args), flush=True)
    return subprocess.run([simctl, *args], check=True, timeout=timeout, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


runtimes = json.loads(run("list", "runtimes", "-j", capture=True))["runtimes"]
runtimes = [r for r in runtimes if r.get("isAvailable") and "iOS 26" in r["name"]]
assert runtimes, "iOS 26 simulator unavailable"
runtime = max(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))["identifier"]
device = run("create", "TaipeiBus-AI", "com.apple.CoreSimulator.SimDeviceType.iPhone-17", runtime, capture=True).strip()
with open(os.environ["GITHUB_ENV"], "a") as env_file:
    env_file.write(f"AI_SIMULATOR={device}\n")
temporary = Path(os.environ["RUNNER_TEMP"])
app = str(temporary / "ai-build/Build/Products/Debug-iphonesimulator/TaipeiBus.app")
run("boot", device)
for attempt in range(2):
    try:
        run("bootstatus", device, "-b", timeout=180)
        run("install", device, app, timeout=180)
        break
    except subprocess.TimeoutExpired:
        if attempt:
            raise
        # The repository's existing preview workflow uses the same recovery for
        # a hosted CoreSimulator installation RPC that stalls after a fresh boot.
        print("Restarting this disposable simulator after a boot/install RPC timeout.", flush=True)
        run("shutdown", device)
        run("boot", device)
run("launch", device, "com.example.TaipeiBus", timeout=180)
run("io", device, "screenshot", str(temporary / "ai-simulator.png"), timeout=180)
