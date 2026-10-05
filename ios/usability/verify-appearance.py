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
    steady = None
    steady_since = time.monotonic()
    while time.monotonic() < deadline:
        try:
            state = json.loads((container / 'Documents/appearance-probe.json').read_text())
            if state['darkMode'] == dark and state['vehicle'] and state['following'] and state['zoom'] > 16 and not state['cameraMoving']:
                same = steady and state['pid'] == steady['pid'] and state['vehicle'] == steady['vehicle'] and abs(state['zoom'] - steady['zoom']) < 0.005
                if not same:
                    steady_since = time.monotonic()
                steady = state
                if time.monotonic() - steady_since >= 1.2:
                    return state
            else:
                steady = None
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.3)
    raise RuntimeError(f'System appearance did not reach dark={dark} with the active bus intact')

before = wait_for(False)
(root / 'baseline.json').write_text(json.dumps(before, indent=2))
try:
    for dark, name in [(False, 'light-before'), (True, 'dark'), (False, 'light-after')]:
        sim('ui', device, 'appearance', 'dark' if dark else 'light')
        state = wait_for(dark)
        (root / f'{name}.json').write_text(json.dumps(state, indent=2))
        assert state['pid'] == before['pid'], 'App process restarted'
        assert state['vehicle'] == before['vehicle'], 'Selected bus changed'
        assert abs(state['zoom'] - before['zoom']) < 0.05, 'Map zoom reset'
        assert abs(state['latitude'] - before['latitude']) < 0.0001, 'Map center reset'
        sim('io', device, 'screenshot', str(root / f'{name}.png'))
finally:
    sim('ui', device, 'appearance', 'light')
print('System light/dark/light verified in one process with the same active bus and viewport.')
