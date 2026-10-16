"""Refresh simulator fixes; opt-in bounded jitter defeats distance filtering."""
import subprocess
import sys
import time

device = sys.argv[1]
jitter = '--jitter' in sys.argv[2:]
sequence = 0
while True:
    try:
        # The route-menu fixture disables real walking reroutes, leaving Core
        # Location's 20 m distance filter active. Identical coordinates can retain
        # their old timestamp. Two fixes 27 m apart model stationary sensor noise;
        # both remain near the same origin and retain the app's 20 s safety gate.
        latitude = 25.0377 + (0.00012 if sequence % 2 else -0.00012) if jitter else 25.0377
        sequence += 1
        result = subprocess.run(['xcrun', 'simctl', 'location', device, 'set', f'{latitude:.6f},121.56'],
                                capture_output=True, text=True, timeout=20)
        if result.returncode:
            print('Simulator location refresh returned a temporary error.', flush=True)
    except subprocess.TimeoutExpired:
        print('Simulator location refresh timed out; trying again.', flush=True)
    time.sleep(4)
