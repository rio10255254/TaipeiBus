#!/usr/bin/env python3
"""Speak each film's lines with ElevenLabs (the voice named in src/episodes.json).

Every line with a `say` is spoken to public/voice/<episode>-<n>.mp3, and `outroSay` to
<episode>-outro.mp3. `say` may carry audio tags such as [warm]; they steer the delivery and are not
read out. The API key comes from ELEVENLABS_API_KEY, or is added by the cloud session's proxy.

    python3 scripts/make-voice.py ep1 [--force]
"""
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = json.loads((ROOT / "src" / "episodes.json").read_text())
OUT = ROOT / "public" / "voice"


def speak(text, voice, path):
    body = {"text": text, "model_id": voice.get("model", "eleven_v4"), "language_code": voice.get("language", "zh")}
    if "settings" in voice:
        body["voice_settings"] = voice["settings"]
    key = os.environ.get("ELEVENLABS_API_KEY", "set-by-proxy")
    url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice['voiceId']}?output_format=mp3_44100_128"
    code = subprocess.run(
        ["curl", "-sS", "-m", "120", "-o", str(path), "-w", "%{http_code}", "-X", "POST", url,
         "-H", f"xi-api-key: {key}", "-H", "Content-Type: application/json", "-d", json.dumps(body)],
        capture_output=True, text=True, check=True,
    ).stdout
    if code != "200":
        raise SystemExit(f"ElevenLabs answered {code}: {path.read_text(errors='replace')[:300]}")


def main():
    force = "--force" in sys.argv
    wanted = set(a for a in sys.argv[1:] if not a.startswith("--"))
    OUT.mkdir(parents=True, exist_ok=True)
    for episode in SCRIPT["episodes"]:
        if wanted and episode["id"] not in wanted:
            continue
        voice = SCRIPT["voice"] | episode.get("voice", {})
        jobs = [(n, line["say"]) for n, line in enumerate(episode["lines"]) if line.get("say")]
        if episode.get("outroSay"):
            jobs.append(("outro", episode["outroSay"]))
        for n, say in jobs:
            path = OUT / f"{episode['id']}-{n}.mp3"
            note = path.with_suffix(".txt")
            if path.exists() and not force and note.exists() and note.read_text() == say:
                continue
            speak(say, voice, path)
            note.write_text(say)
            print(f"{path.relative_to(ROOT)}  {say}")


if __name__ == "__main__":
    main()
