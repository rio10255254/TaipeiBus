#!/usr/bin/env python3
"""The band the promo reels are scored with: sampled acoustic guitar, marimba, glockenspiel,
recorder and hand drums (see assets/*/CREDITS.md: University of Iowa MIS, free for any use, and
VCSL, CC0) beside a synthesised pad, bass, kick and small sound effects. The instrument code is
shared with the WordCat promo it was first written for; the music itself is in make-sound.py.
Needs numpy, scipy and ffmpeg.
"""
import math
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np
from scipy.signal import butter, fftconvolve, lfilter, sosfilt

ROOT = Path(__file__).resolve().parent.parent
SR = 44100
BEAT = 0.5  # 120 bpm
BAR = BEAT * 4
SWING = 0.04  # a touch of lilt on the off-beats
rng = np.random.default_rng(1090)

def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def place(bus, sig, at, gain=1.0):
    i = int(round(at * SR))
    if i >= len(bus) or i + len(sig) <= 0:
        return
    if i < 0:
        sig, i = sig[-i:], 0
    end = min(len(bus), i + len(sig))
    bus[i:end] += sig[: end - i] * gain


def lowpass(x, hz, order=2):
    return sosfilt(butter(order, hz, "low", fs=SR, output="sos"), x)


def highpass(x, hz, order=2):
    return sosfilt(butter(order, hz, "high", fs=SR, output="sos"), x)


def bandpass(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, hi], "band", fs=SR, output="sos"), x)


# ── Sampled instruments ──────────────────────────────────────────────────────
# Acoustic guitar: University of Iowa Musical Instrument Samples (free for any use).
# Soprano recorder, glockenspiel, marimba, hand drums, ocean drum: VCSL (CC0).

NAMES = {"C": 0, "Cs": 1, "D": 2, "Ds": 3, "E": 4, "F": 5, "Fs": 6, "G": 7, "Gs": 8, "A": 9, "As": 10, "B": 11}
_banks = {}


def _decode(path):
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-f", "s16le", "-ac", "1", "-ar", str(SR), "-"],
        capture_output=True,
        check=True,
    ).stdout
    return np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768


def bank(folder):
    """note number → recording, trimmed to its onset and normalised."""
    if folder not in _banks:
        notes = {}
        for f in (ROOT / "assets" / folder).glob("*.mp3"):
            name = f.stem.rstrip("0123456789")
            note = 12 * (int(f.stem[len(name) :]) + 1) + NAMES[name]
            audio = _decode(f)
            onset = int(np.argmax(np.abs(audio) > 0.02 * np.max(np.abs(audio))))
            audio = audio[max(0, onset - 16) :]
            notes[note] = audio / (np.max(np.abs(audio)) + 1e-9)
        _banks[folder] = notes
    return _banks[folder]


def sampled(folder, note, length):
    notes = bank(folder)
    source = min(notes, key=lambda k: abs(k - note))
    ratio = 2 ** ((note - source) / 12)
    src = notes[source]
    n = max(1, min(int(length * SR), int(len(src) / ratio) - 1))
    return np.interp(np.arange(n) * ratio, np.arange(len(src)), src)


def guitar(note, length=1.0, velocity=0.6):
    """One string, stopped cleanly at `length` (damped when the next strum lands)."""
    out = sampled("iowa-guitar", note, length)
    t = np.arange(len(out)) / SR
    release = np.clip((length - t) / 0.035, 0, 1)
    return lowpass(out * release, 1700 + 3300 * velocity) * (0.3 + 0.9 * velocity)


def marimba(note, velocity=0.6):
    """A marimba note: warm wood, the island colour."""
    out = sampled("vcsl-marimba", note, 1.2)
    return lowpass(out, 2500 + 5000 * velocity) * (0.25 + 0.8 * velocity)


_one_shots = {}


def one_shot(name):
    """A single recorded hit (hand drums) or the ocean bed, from assets/vcsl-percussion."""
    if name not in _one_shots:
        _one_shots[name] = _decode(ROOT / "assets" / "vcsl-percussion" / f"{name}.mp3")
    return _one_shots[name]


def pad(notes, length):
    """A warm, slow synth pad: detuned saws, softly filtered, breathing in and out."""
    n = int(length * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for note in notes:
        for detune in (-0.08, 0.0, 0.09):
            f = midi(note) * 2 ** (detune / 12)
            out += 2 * ((t * f + rng.random()) % 1.0) - 1
    out = lowpass(out / (3 * len(notes)), 1400, 2)
    shape = np.clip(t / 0.35, 0, 1) * np.clip((length - t) / 0.4, 0, 1)
    return out * shape


def peaking(x, hz, gain_db, q=1.0):
    """A bell EQ (RBJ cookbook): cut or boost around `hz`."""
    a = 10 ** (gain_db / 40)
    w = 2 * np.pi * hz / SR
    alpha = np.sin(w) / (2 * q)
    b = [1 + alpha * a, -2 * np.cos(w), 1 - alpha * a]
    den = [1 + alpha / a, -2 * np.cos(w), 1 - alpha / a]
    return lfilter(np.array(b) / den[0], np.array(den) / den[0], x)


def high_shelf(x, hz, gain_db):
    """Lift (or lower) everything above `hz`: the "air" on top."""
    a = 10 ** (gain_db / 40)
    w = 2 * np.pi * hz / SR
    alpha = np.sin(w) / 2 * np.sqrt(2)
    cw = np.cos(w)
    b = [a * ((a + 1) + (a - 1) * cw + 2 * np.sqrt(a) * alpha), -2 * a * ((a - 1) + (a + 1) * cw), a * ((a + 1) + (a - 1) * cw - 2 * np.sqrt(a) * alpha)]
    den = [(a + 1) - (a - 1) * cw + 2 * np.sqrt(a) * alpha, 2 * ((a - 1) - (a + 1) * cw), (a + 1) - (a - 1) * cw - 2 * np.sqrt(a) * alpha]
    return lfilter(np.array(b) / den[0], np.array(den) / den[0], x)


def tame(x, lo, hi, threshold, ratio=3.0):
    """A resonance tamer: only when the band lo–hi rings loud is it pulled down."""
    band = bandpass(x, lo, hi, 2)
    env_ = lowpass(np.abs(band), 30, 1)
    over = np.maximum(env_ / threshold, 1.0)
    reduce = over ** (1 / ratio - 1)  # gain < 1 only above the threshold
    return x - band + band * reduce


def widen(x, depth=0.004, rate=0.9):
    """Two slightly delayed, slowly wavering copies: wider and softer than one point of sound."""
    n = len(x)
    t = np.arange(n) / SR
    out = x.copy()
    for i, base in enumerate((0.011, 0.017)):
        d = (base + depth * np.sin(2 * np.pi * rate * t + i * 2.1)) * SR
        out += 0.45 * np.interp(np.arange(n) - d, np.arange(n), x, left=0)
    return out / 1.6


def bright_not_harsh(x):
    """Bright from harmonics and air, not from the 2–5 kHz the ear is sharpest to."""
    warm = np.tanh(2.2 * x) / np.tanh(2.2)  # gentle saturation: richer overtones
    y = 0.6 * x + 0.4 * warm
    y = tame(y, 900, 1700, threshold=0.05)  # hold back the ringing of long high notes
    y = peaking(y, 2800, -5, q=1.4)  # the ear's most sensitive band
    y = peaking(y, 4000, -3, q=1.2)
    y = high_shelf(y, 7500, 5)  # air: sparkle without bite
    return y


def echo(x, delay, feedback=0.35, repeats=3, tone=4500):
    """A soft echo: each repeat quieter and a little darker."""
    out = x.copy()
    step = int(delay * SR)
    tap = x
    for r in range(1, repeats + 1):
        tap = lowpass(tap, tone) * feedback
        shifted = np.zeros_like(x)
        shifted[step * r :] = tap[: len(x) - step * r]
        out += shifted
    return out


def lead(note, length, velocity=0.7):
    """The tune on a real soprano recorder: airy and bright, like a clear whistle."""
    out = sampled("vcsl-recorder", note, length + 0.12)
    t = np.arange(len(out)) / SR
    shape = np.clip(t / 0.012, 0, 1) * np.clip((length + 0.1 - t) / 0.08, 0, 1)
    return highpass(out * shape, 350) * velocity


def glock(note, velocity=0.6):
    """A real glockenspiel note: the sparkle on top."""
    out = sampled("vcsl-glockenspiel", note, 2.0)
    return out * (0.2 + 0.8 * velocity)


def strum(notes, length, velocity, up=False):
    """A strum across the strings: down from the low string, or up across the top ones."""
    order = sorted(notes)
    if up:
        order = order[-4:][::-1]
    gap = (0.007 if up else 0.011) * (1.25 - velocity * 0.5)
    out = np.zeros(int((length + gap * len(order)) * SR) + 1)
    for i, note in enumerate(order):
        v = velocity * (0.8 if up else 1.0) * (0.9 + 0.1 * rng.random())
        place(out, guitar(note, max(0.02, length - i * gap), v), i * gap)
    return out


def chuck(notes):
    """A muted strum: the strings slapped and stopped at once, a percussive "chk"."""
    n = int(0.06 * SR)
    t = np.arange(n) / SR
    body = np.zeros(n)
    for i, note in enumerate(sorted(notes)):
        place(body, guitar(note, 0.045, 0.5), i * 0.004, 0.35)
    slap = bandpass(rng.uniform(-1, 1, n), 700, 3500) * np.exp(-t / 0.012)
    return lowpass(body + 0.5 * slap, 3500)


def reverse_swell(notes, length):
    """The next chord strummed backwards: it swells up into the downbeat."""
    ring = np.zeros(int(length * 1.6 * SR))
    for note in sorted(notes):
        place(ring, guitar(note, length * 1.6, 0.55), 0)
    ring = ring[: int(length * SR)]
    return ring[::-1] * np.linspace(0, 1, len(ring)) ** 1.5


# ── Drums and texture ────────────────────────────────────────────────────────


def kick():
    n = int(0.5 * SR)
    t = np.arange(n) / SR
    f = midi(34) + 70 * np.exp(-t / 0.03)  # settles on B-flat, in key
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.25)
    knock = lowpass(rng.uniform(-1, 1, n), 1200) * np.exp(-t / 0.006) * 0.25
    return lowpass(body + knock, 3000)


def snare():
    n = int(0.35 * SR)
    t = np.arange(n) / SR
    noise = bandpass(rng.uniform(-1, 1, n), 900, 5000) * np.exp(-t / 0.075)
    tone = np.sin(2 * np.pi * 185 * t) * np.exp(-t / 0.045)
    return lowpass(0.75 * noise + 0.45 * tone, 4500)


def rim():
    n = int(0.08 * SR)
    t = np.arange(n) / SR
    return bandpass(rng.uniform(-1, 1, n), 1500, 4500) * np.exp(-t / 0.012) + np.sin(2 * np.pi * 820 * t) * np.exp(-t / 0.01)


def hat(open_=False):
    n = int((0.22 if open_ else 0.05) * SR)
    t = np.arange(n) / SR
    return lowpass(highpass(rng.uniform(-1, 1, n), 6500, 4), 10000) * np.exp(-t / (0.08 if open_ else 0.014))


def sub(note, length):
    n = int(length * SR)
    t = np.arange(n) / SR
    f = midi(note)
    tone = np.sin(2 * np.pi * f * t) + 0.18 * np.sin(4 * np.pi * f * t)
    return tone * np.clip(t / 0.02, 0, 1) * np.clip((length - t) / 0.08, 0, 1) * np.exp(-t / (length * 0.9))


def low_hit(length=1.8):
    n = int(length * SR)
    t = np.arange(n) / SR
    boom = np.sin(2 * np.pi * (midi(29) + 30 * np.exp(-t / 0.06)) * t) * np.exp(-t / 0.45)  # F, in key
    air = lowpass(highpass(rng.uniform(-1, 1, n), 3000), 9000) * np.exp(-t / 0.5) * 0.12
    return boom + air


def whoosh(length):
    n = int(length * SR)
    t = np.arange(n) / SR
    noise = rng.uniform(-1, 1, n)
    out = np.zeros(n)
    hop = 512
    for i in range(0, n, hop):
        centre = 500 + 2600 * math.sin(math.pi * i / n)
        seg = noise[max(0, i - 2048) : i + hop]
        out[i : i + hop] = bandpass(seg, centre * 0.6, centre * 1.5)[-len(out[i : i + hop]) :]
    return out * np.sin(np.pi * np.clip(t / length, 0, 1)) ** 2


def pop():
    n = int(0.16 * SR)
    t = np.arange(n) / SR
    return np.sin(2 * np.pi * np.cumsum(260 + 600 * np.exp(-t / 0.02)) / SR) * np.exp(-t / 0.05)


def tap():
    n = int(0.05 * SR)
    t = np.arange(n) / SR
    return bandpass(rng.uniform(-1, 1, n), 1800, 5000) * np.exp(-t / 0.007)


def stamp():
    n = int(0.3 * SR)
    t = np.arange(n) / SR
    return np.sin(2 * np.pi * (65 + 50 * np.exp(-t / 0.02)) * t) * np.exp(-t / 0.08) + 0.5 * bandpass(
        rng.uniform(-1, 1, n), 300, 2500
    ) * np.exp(-t / 0.025)


def ding():
    out = np.zeros(int(1.6 * SR))
    place(out, guitar(74, 1.5, 0.6), 0)
    place(out, guitar(81, 1.4, 0.5), 0.1)
    return out


def crackle(n):
    """Vinyl: a soft hiss and scattered little pops."""
    hiss = lowpass(highpass(rng.normal(0, 1, n), 1500), 7000) * 0.012
    clicks = np.zeros(n)
    idx = rng.choice(n, size=int(n / SR * 9), replace=False)
    clicks[idx] = rng.uniform(0.15, 0.6, len(idx)) * rng.choice([-1, 1], len(idx))
    clicks = highpass(clicks, 2000) * 0.25
    return hiss + clicks


def room(length=2.4):
    """A soft room: decaying noise, darker as it fades."""
    n = int(length * SR)
    t = np.arange(n) / SR
    ir = rng.normal(0, 1, n) * np.exp(-t / 0.55)
    ir = lowpass(ir, 3500)
    ir[0] = 0
    return ir / np.sqrt(np.sum(ir**2))


def clap():
    n = int(0.3 * SR)
    t = np.arange(n) / SR
    burst = sum(
        np.roll(bandpass(rng.uniform(-1, 1, n), 900, 5000) * np.exp(-t / 0.012), int(d * SR)) for d in (0, 0.009, 0.019)
    )
    tail = bandpass(rng.uniform(-1, 1, n), 1000, 4000) * np.exp(-t / 0.09) * 0.4
    return lowpass(burst + tail, 6000)


def shaker():
    n = int(0.09 * SR)
    t = np.arange(n) / SR
    env_ = np.clip(t / 0.015, 0, 1) * np.exp(-t / 0.03)
    return lowpass(highpass(rng.uniform(-1, 1, n), 4000), 9000) * env_


def ebass(note, length):
    """A round finger-played electric bass: a little bite, then a warm body."""
    n = int(length * SR)
    t = np.arange(n) / SR
    f = midi(note)
    saw = 2 * ((t * f) % 1.0) - 1
    body = np.sin(2 * np.pi * f * t) * 0.8 + lowpass(saw, 900) * 0.5
    pluck_env = np.clip(t / 0.006, 0, 1) * (0.6 * np.exp(-t / 0.12) + 0.4 * np.exp(-t / 0.8))
    return lowpass(body * pluck_env * np.clip((length - t) / 0.05, 0, 1), 1600)


def tambourine():
    n = int(0.16 * SR)
    t = np.arange(n) / SR
    jingle = bandpass(rng.uniform(-1, 1, n), 5000, 11000) * (np.exp(-t / 0.05) + 0.4 * np.exp(-t / 0.012))
    return jingle


def riser(length):
    """Filtered noise sweeping up into a downbeat."""
    n = int(length * SR)
    noise = rng.uniform(-1, 1, n)
    out = np.zeros(n)
    hop = 1024
    for i in range(0, n, hop):
        centre = 500 * (12 ** (i / n))
        seg = noise[max(0, i - 4096) : i + hop]
        out[i : i + hop] = bandpass(seg, centre * 0.7, min(centre * 1.5, SR / 2 - 100))[-len(out[i : i + hop]) :]
    return out * (np.arange(n) / n) ** 2


def write_mp3(stereo, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        with wave.open(tmp.name, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes((np.clip(stereo, -1, 1) * 32767).astype("<i2").tobytes())
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", tmp.name, "-b:a", "192k", str(path)], check=True)
