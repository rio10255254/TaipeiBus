"""Record actual simulator interactions while running a native QA command."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(os.environ["RUNNER_TEMP"])
simctl = subprocess.check_output(["xcrun", "--find", "simctl"], text=True).strip()
output = root / os.environ.get("BUS_INTERACTION_RECORDING_NAME", "iPhone17-interactions.mp4")
log_path = root / (output.stem + "-record.log")
with log_path.open("w") as log:
    recorder = subprocess.Popen([simctl, "io", os.environ["BUS_SIM_DEVICE"], "recordVideo",
        "--codec=h264", str(output)], stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 30
        while "Recording started" not in log_path.read_text(errors="replace"):
            if recorder.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("Interaction recorder did not start")
            time.sleep(0.25)
        # The clock at the first recorded frame, to line the footage up with marks in the test log.
        print(f"Recording started at {time.time():.2f}", flush=True)
        subprocess.run(sys.argv[1:], check=True)
    finally:
        if recorder.poll() is None:
            recorder.send_signal(signal.SIGINT)
            try:
                # A quarter of an hour of footage takes far longer to close than a short clip; a file
                # cut off before its index is written cannot be played at all.
                recorder.wait(timeout=180)
            except subprocess.TimeoutExpired:
                recorder.terminate()
                recorder.wait(timeout=10)
    if recorder.returncode != 0 or not output.exists() or output.stat().st_size < 100_000:
        raise RuntimeError("Interaction recording is incomplete")
    print(f"Recorded native interactions: {output.name}, {output.stat().st_size} bytes")
