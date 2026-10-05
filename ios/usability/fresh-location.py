"""A stationary simulator passenger with continuously fresh sensor timestamps."""
import subprocess
import sys
import time

device = sys.argv[1]
while True:
    try:
        result = subprocess.run(['xcrun', 'simctl', 'location', device, 'set', '25.0377,121.56'],
                                capture_output=True, text=True, timeout=20)
        if result.returncode:
            print('Simulator location refresh returned a temporary error.', flush=True)
    except subprocess.TimeoutExpired:
        print('Simulator location refresh timed out; trying again.', flush=True)
    time.sleep(4)
