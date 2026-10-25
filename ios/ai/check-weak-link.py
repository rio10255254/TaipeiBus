#!/usr/bin/env python3
"""Verify the built app can launch without FoundationModels on iOS 17–25."""
import re
import subprocess
import sys

commands = subprocess.check_output(['xcrun', 'otool', '-l', sys.argv[1]], text=True)
loads = []
for command in re.split(r'Load command \d+', commands):
    if re.search(r'name .*?/FoundationModels\.framework/FoundationModels\s', command):
        loads.extend(re.findall(r'\bcmd (LC_\w+)', command))
assert loads and all(load == 'LC_LOAD_WEAK_DYLIB' for load in loads), f'FoundationModels must be weak linked; found {loads}'
print('FoundationModels uses LC_LOAD_WEAK_DYLIB in the built executable.')
