"""Toggle the actual simulator setting while one app process follows a bus."""
import json
import os
import subprocess
import time
from pathlib import Path

device = os.environ['BUS_SIM_DEVICE']
bundle = 'com.example.TaipeiBus'
root = Path(os.environ['RUNNER_TEMP']) / 'appearance-switches'
root.mkdir(exist_ok=True)

def sim(*args, check=True):
    return subprocess.run(['xcrun', 'simctl', *args], check=check, capture_output=True, text=True, timeout=60)

sim('terminate', device, bundle, check=False)
sim('ui', device, 'appearance', 'light')
sim('launch', device, bundle, '-AppleLanguages', '(zh-Hant)', '-AppleLocale', 'zh_TW',
    '--test-map-controls', '--preview-boarding-fixture', '--preview-cooperated-fixture',
    '--preview-track-next', '--usability-fixture')
container = Path(sim('get_app_container', device, bundle, 'data').stdout.strip())

def wait_for(dark):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        try:
            state = json.loads((container / 'Documents/appearance-probe.json').read_text())
            if state['darkMode'] == dark and state['vehicle'] and state['pitch'] > 50:
                return state
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.3)
    raise RuntimeError(f'System appearance did not reach dark={dark} with the active bus intact')

before = wait_for(False)
try:
    for dark, name in [(False, 'light-before'), (True, 'dark'), (False, 'light-after')]:
        sim('ui', device, 'appearance', 'dark' if dark else 'light')
        state = wait_for(dark)
        assert state['pid'] == before['pid'], 'App process restarted'
        assert state['vehicle'] == before['vehicle'], 'Selected bus changed'
        assert abs(state['zoom'] - before['zoom']) < 0.05, 'Map zoom reset'
        assert abs(state['latitude'] - before['latitude']) < 0.0001, 'Map center reset'
        (root / f'{name}.json').write_text(json.dumps(state, indent=2))
        sim('io', device, 'screenshot', str(root / f'{name}.png'))
finally:
    sim('ui', device, 'appearance', 'light')
print('System light/dark/light verified in one process with the same active bus and viewport.')
