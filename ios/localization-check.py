"""Verify shipped language resources and every literal translation key."""
import json
import plistlib
import re
from pathlib import Path

root = Path(__file__).resolve().parent
catalog = json.loads((root / "TransitCore/Sources/TransitCore/Localization/en.json").read_text(encoding="utf-8"))
assert len(catalog) >= 350, "English catalog is incomplete"
for key, value in catalog.items():
    assert key.count("%@") == value.count("%@"), f"Placeholder mismatch: {key}"
    assert not re.search(r"[\u3400-\u9fff]", value), f"Chinese generic UI in English translation: {key}"
missing = []
for folder in [root / "TaipeiBus", root / "TransitCore/Sources/TransitCore"]:
    for path in folder.glob("*.swift"):
        for match in re.finditer(r'(?:AppText\.text|live\.text|settings\.text)\(\s*"((?:[^"\\]|\\.)*)"', path.read_text(encoding="utf-8")):
            key = json.loads('"' + match.group(1) + '"')
            if re.search(r"[\u3400-\u9fff]", key) and key not in catalog:
                missing.append((path.name, key))
assert not missing, f"Missing translations: {missing}"
info = plistlib.loads((root / "TaipeiBus/Info.plist").read_bytes())
assert set(info["CFBundleLocalizations"]) == {"en", "zh-Hant"}
for language in ["en", "zh-Hant"]:
    text = (root / f"TaipeiBus/{language}.lproj/InfoPlist.strings").read_text(encoding="utf-8")
    assert '"CFBundleDisplayName"' in text and '"NSLocationWhenInUseUsageDescription"' in text
print(f"Language resources checked: {len(catalog)} English templates, bilingual stop data, localized app name and location purpose.")
