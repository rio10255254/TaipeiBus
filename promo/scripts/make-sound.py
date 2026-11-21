#!/usr/bin/env python3
"""Time and mix the films: the narrator over a light commuting groove.

Reads src/episodes.json and the lines scripts/make-voice.py spoke. Each line gets a slot that starts
on a beat (120 bpm) and lasts as many beats as written, or until its words are said and a breath
after. The end card follows with the sound logo: three rising notes and a chord, like a platform
chime (A–D–F♯ landing on D). Writes

- src/timing.json: the slots in seconds, for src/Reel.tsx
- public/audio/<episode>.mp3: voice, music and effects, mastered to −14 LUFS

The music is the films' own: D major on Bm7 → Gmaj7 → D → A, muted guitar and a walking bass under a
marimba figure that climbs like a route being drawn, with glockenspiel on the downbeats.
"""
import json
import math
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np
from scipy.ndimage import maximum_filter1d, minimum_filter1d
from scipy.signal import resample_poly

sys.path.insert(0, str(Path(__file__).resolve().parent))
import instruments as m  # noqa: E402

ROOT = m.ROOT
SR = m.SR
BEAT = m.BEAT
SCRIPT = json.loads((ROOT / "src" / "episodes.json").read_text())
VOICE = ROOT / "public" / "voice"
LEAD_IN = 0.14
BREATH = 0.32
END_BEATS = 8

# (bass note, guitar shape low to high, chord tones, pad voicing)
BM = (47, [47, 54, 57, 62, 66, 71], {11, 2, 6, 9}, [62, 66, 69, 74])  # Bm7
G_ = (43, [55, 62, 66, 71, 74], {7, 11, 2, 6}, [62, 66, 71, 74])  # Gmaj7
D_ = (50, [50, 57, 62, 66, 69], {2, 6, 9}, [62, 66, 69, 74])  # D
A_ = (45, [45, 52, 57, 61, 64, 69], {9, 1, 4}, [61, 64, 69, 73])  # A
LOOP = [BM, G_, D_, A_]


def decode(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).astype(float)


def load_voice(path):
    """A spoken line, trimmed of silence and polished: clean, present, even."""
    audio = decode(path)
    level = np.abs(audio)
    loud = np.where(level > 0.02 * level.max())[0]
    audio = audio[max(0, loud[0] - int(0.03 * SR)): loud[-1] + int(0.08 * SR)]
    audio = m.highpass(audio, 90)
    audio = m.peaking(audio, 220, 1.5, 0.9)
    audio = m.peaking(audio, 3200, 2.5, 1.0)
    audio = m.high_shelf(audio, 8000, 2.0)
    env = np.sqrt(np.maximum(m.lowpass(audio ** 2, 20), 0) + 1e-9)
    audio = audio * np.minimum(1.0, (env / (env.max() * 0.35)) ** -0.45)
    return audio / np.abs(audio).max() * 0.9


def loudness(stereo):
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        with wave.open(tmp.name, "wb") as w:
            w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
            w.writeframes((np.clip(stereo, -1, 1) * 32767).astype("<i2").tobytes())
        log = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", tmp.name, "-af", "ebur128", "-f", "null", "-"],
                             capture_output=True, text=True).stderr
    return float(log.rsplit("I:", 1)[1].split("LUFS")[0])


def master(out, target=-14.0, ceiling=0.89):
    out = out / np.abs(out).max() * ceiling
    out = out * 10 ** ((target - loudness(out)) / 20)
    peak = maximum_filter1d(np.abs(out).max(axis=1), size=int(0.005 * SR), origin=-int(0.0025 * SR))
    gain = np.minimum(1.0, ceiling / np.maximum(peak, 1e-9))
    gain = minimum_filter1d(gain, size=int(0.01 * SR))
    gain = np.minimum(gain, m.lowpass(gain, 12))
    return out * gain[:, None]


def layout(episode):
    slots, t = [], 0.0
    for n, line in enumerate(episode["lines"]):
        path = VOICE / f"{episode['id']}-{n}.mp3"
        audio = load_voice(path) if line.get("say") and path.exists() else np.zeros(1)
        spoken = len(audio) / SR if len(audio) > 1 else 0.0
        need = math.ceil((LEAD_IN + spoken + BREATH) / BEAT)
        beats = max(line.get("beats", 0), need)
        if line.get("beats") and need > line["beats"]:
            print(f"  {episode['id']} line {n}: needs {need} beats, {line['beats']} written; using {need}")
        slots.append({"start": t, "length": beats * BEAT, "voiceStart": t + LEAD_IN, "voiceLength": spoken, "audio": audio})
        t += beats * BEAT
    return slots, t


def flip():
    n = int(0.14 * SR); t = np.arange(n) / SR
    return m.bandpass(m.rng.uniform(-1, 1, n), 1400, 7000) * np.sin(np.pi * t / t[-1]) ** 2 * (0.4 + 0.6 * t / t[-1])


def thud():
    n = int(0.22 * SR); t = np.arange(n) / SR
    return np.sin(2 * np.pi * (70 + 60 * np.exp(-t / 0.015)) * t) * np.exp(-t / 0.05) + 0.25 * m.bandpass(m.rng.uniform(-1, 1, n), 200, 1200) * np.exp(-t / 0.02)


def tick():
    n = int(0.04 * SR); t = np.arange(n) / SR
    return m.bandpass(m.rng.uniform(-1, 1, n), 2500, 6000) * np.exp(-t / 0.004)


def chime():
    """Two soft glockenspiel notes, a fifth apart: something arrived."""
    n = int(0.9 * SR); out = np.zeros(n)
    m.place(out, m.glock(86, 0.5), 0.0, 0.8)
    m.place(out, m.glock(93, 0.5), 0.11, 0.7)
    return out


def groove(seconds, lift_from=None):
    """The bed under the voice. From `lift_from` (seconds) the kick goes to every beat and a hat joins."""
    n = int((seconds + 2) * SR)
    gtr, mar, bass, drums, glk, padb = (np.zeros(n) for _ in range(6))
    bars = math.ceil(seconds / (4 * BEAT))
    for b in range(bars):
        bass_note, shape, _, voicing = LOOP[b % 4]
        start = b * 4 * BEAT
        full = lift_from is not None and start >= lift_from - 1e-6
        # Guitar: one soft strum on the downbeat, muted chucks on the backbeats, light upstrokes between.
        m.place(gtr, m.strum(shape, BEAT * 1.6, 0.42), start)
        for beat in (1, 3):
            m.place(gtr, m.chuck(shape), start + beat * BEAT, 0.7)
        for half in ((1.5, 2.5, 3.5) if full else (2.5,)):
            m.place(gtr, m.strum(shape, BEAT * 0.4, 0.28, up=True), start + half * BEAT + m.SWING)
        # Marimba: the chord climbing in eighths, like stops along a line, resting on beat four.
        tones = sorted(voicing)
        climb = [tones[0], tones[1], tones[2], tones[1], tones[2], tones[3]] if full else [tones[0], tones[2], tones[1], tones[3]]
        step = BEAT / 2 if full else BEAT
        for j, note in enumerate(climb):
            m.place(mar, m.marimba(note + 12, 0.42 + 0.05 * (j % 2 == 0)), start + j * step + (m.SWING if (j % 2 and full) else 0), 0.55)
        # Glockenspiel: a glint on the downbeat of every other bar.
        if b % 2 == 0:
            m.place(glk, m.glock(tones[-1] + 12, 0.35), start, 0.3)
        # Bass: root, a bounce up the octave, then walking to the next chord.
        nxt = LOOP[(b + 1) % 4][0]
        m.place(bass, m.ebass(bass_note, BEAT * 1.3), start)
        m.place(bass, m.ebass(bass_note + 12, BEAT * 0.4), start + 1.5 * BEAT)
        m.place(bass, m.ebass(bass_note, BEAT * 0.9), start + 2 * BEAT)
        m.place(bass, m.ebass(bass_note + (2 if nxt > bass_note else -2), BEAT * 0.45), start + 3.5 * BEAT, 0.8)
        # A warm pad under it all.
        m.place(padb, m.pad(voicing, BEAT * 4.2), start, 0.5)
        # Drums: kick, a rim on the backbeat, shaker eighths.
        for beat in ((0, 1, 2, 3) if full else (0, 2)):
            m.place(drums, m.kick(), start + beat * BEAT, 0.5 if beat in (0, 2) else 0.34)
        for beat in (1, 3):
            m.place(drums, m.rim(), start + beat * BEAT, 0.5)
            if full:
                m.place(drums, m.clap(), start + beat * BEAT, 0.2)
        for eighth in range(8):
            m.place(drums, m.shaker(), start + eighth * BEAT / 2 + (m.SWING if eighth % 2 else 0), 0.2)
            if full and eighth % 2:
                m.place(drums, m.hat(), start + eighth * BEAT / 2 + m.SWING, 0.16)
        if b % 4 == 3:
            m.place(drums, m.one_shot("bongo-high"), start + 3.25 * BEAT, 0.28)
            m.place(drums, m.one_shot("bongo-low"), start + 3.5 * BEAT, 0.3)
    return gtr * 0.85 + mar * 0.6 + bass * 0.5 + drums + glk * 0.5 + padb * 0.35


def logo(at, bus, tune):
    """The sound logo: A–D–F♯ rising like a platform chime, landing on a D chord."""
    for beat, note, beats in [(0, 81, 0.5), (0.5, 86, 0.5), (1.0, 90, 2.5)]:
        m.place(tune, m.glock(note, 0.6), at + beat * BEAT, 0.8)
        m.place(tune, m.marimba(note - 12, 0.7), at + beat * BEAT, 0.8)
    m.place(bus, m.strum(D_[1], BEAT * 4, 0.55), at + 1.0 * BEAT)
    m.place(bus, m.pad(D_[3], BEAT * 5), at + 1.0 * BEAT, 0.5)
    m.place(bus, m.ebass(D_[0] - 12, BEAT * 3.5), at + 1.0 * BEAT, 0.6)
    m.place(bus, m.kick(), at + 1.0 * BEAT, 0.6)
    for i, note in enumerate([86, 90, 93, 98]):
        m.place(tune, m.glock(note, 0.4), at + 1.0 * BEAT + 0.7 + i * 0.12, 0.3)


def mix(episode):
    slots, body = layout(episode)
    total = body + episode.get("endBeats", END_BEATS) * BEAT
    n = int(total * SR)
    voice, sfx, band, tune = (np.zeros(n + SR) for _ in range(4))
    lift = slots[episode["liftFrom"]]["start"] if "liftFrom" in episode else None
    music = groove(body, lift)[: n + SR]
    music = np.pad(music, (0, n + SR - len(music)))
    fade = np.ones(n + SR)
    a, b = int((body - BEAT) * SR), int(body * SR)
    fade[a:b] = np.linspace(1, 0, b - a); fade[b:] = 0
    music *= fade
    if "grooveFrom" in episode:
        music[: int(slots[episode["grooveFrom"]]["start"] * SR)] = 0
    sounds = {"pop": (m.pop, 0.4), "tap": (m.tap, 0.9), "whoosh": (lambda: m.whoosh(BEAT), 0.45), "ding": (m.ding, 0.5), "stamp": (m.stamp, 0.5),
              "flip": (flip, 0.55), "thud": (thud, 0.6), "tick": (tick, 0.6), "chime": (chime, 0.6)}
    for slot, line in zip(slots, episode["lines"]):
        if len(slot["audio"]) > 1:
            m.place(voice, slot["audio"], slot["voiceStart"])
        for beat, name in line.get("cues", []):
            make, gain = sounds[name]
            m.place(sfx, make(), slot["start"] + beat * BEAT, gain)
    m.place(sfx, m.whoosh(BEAT), body - BEAT, 0.5)
    logo(body, band, tune)
    outro = VOICE / f"{episode['id']}-outro.mp3"
    if episode.get("outroSay") and outro.exists():
        m.place(voice, load_voice(outro), body + episode.get("outroAt", 1.6))
    if np.abs(voice).max() > 0:
        env = m.lowpass(np.abs(voice), 8)
        music *= 1 - 0.66 * np.clip(env / (env.max() * 0.25), 0, 1)
    tune = m.echo(m.bright_not_harsh(tune), BEAT * 0.75, 0.25, 2)

    def stereo(x, width=0.0):
        return np.stack([x * (1 - width), x * (1 + width)], axis=1)

    out = stereo(voice * 0.95) + stereo(music * 0.44) + stereo(sfx * 0.6) + stereo(band * 0.5) + stereo(m.widen(tune * 0.5))
    out = out[:n]
    out[-int(0.3 * SR):] *= np.linspace(1, 0, int(0.3 * SR))[:, None]
    out = master(out)
    timing = {"total": round(total, 3), "end": round(body, 3),
              "slots": [{k: round(v, 3) for k, v in s.items() if k != "audio"} for s in slots]}
    return out, timing


def main():
    wanted = set(a for a in sys.argv[1:] if not a.startswith("--"))
    path = ROOT / "src" / "timing.json"
    timings = json.loads(path.read_text()) if path.exists() else {}
    for episode in SCRIPT["episodes"]:
        if wanted and episode["id"] not in wanted:
            continue
        stereo, timing = mix(episode)
        out = ROOT / "public" / "audio" / f"{episode['id']}.mp3"
        m.write_mp3(stereo, out)
        timings[episode["id"]] = timing
        print(f"{episode['id']}: {timing['total']:.2f}s -> {out.relative_to(ROOT)}")
    path.write_text(json.dumps(timings, indent=2) + "\n")


if __name__ == "__main__":
    main()
