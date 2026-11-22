#!/usr/bin/env python3
"""Synthesises the app's sound effects. All original, no samples."""
import wave
from pathlib import Path

import numpy as np

RATE = 44100
OUT = Path(__file__).resolve().parent.parent / "App/Resources/Sounds"


def timeline(seconds):
    return np.arange(int(RATE * seconds)) / RATE


def save(name, audio, peak=0.55):
    fade = min(300, len(audio) // 4)
    audio[-fade:] *= np.linspace(1, 0, fade)
    data = (audio / np.abs(audio).max() * peak * 32767).astype("<i2")
    with wave.open(str(OUT / f"{name}.wav"), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(data.tobytes())


def synth(freq, t):
    tone = sum(np.sin(2 * np.pi * freq * k * t) / k ** 1.5 for k in (1, 2, 3, 5))
    return tone * np.exp(-t * 11) * np.minimum(1, t * 250)


t = timeline(0.2)
sweep = 240 + 900 * (t / 0.2) ** 0.5
save("send", np.sin(2 * np.pi * np.cumsum(sweep) / RATE) * np.exp(-t * 16) * np.minimum(1, t * 300))

audio = np.zeros(int(RATE * 0.55))
for start, freq in ((0, 440.0), (0.07, 554.37), (0.14, 830.61)):
    note = synth(freq, timeline(0.4))
    at = int(start * RATE)
    audio[at:at + len(note)] += note
save("receive", audio)

audio = np.zeros(int(RATE * 0.8))
for start, freq in ((0, 329.63), (0.08, 415.3), (0.16, 493.88), (0.24, 659.26)):
    note = synth(freq, timeline(0.5))
    at = int(start * RATE)
    audio[at:at + len(note)] += note
save("join", audio)
