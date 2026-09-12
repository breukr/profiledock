#!/usr/bin/env python3
"""Original ProfileDock chimes, dedicated to the public domain under CC0 1.0."""
import math
import struct
import wave
from pathlib import Path

destination = Path(__file__).resolve().parent.parent / "Resources" / "Sounds"
destination.mkdir(parents=True, exist_ok=True)
rate = 44100
for name, notes in {
    "finished": [(0, 784, 0.20), (0.13, 1046.5, 0.28)],
    "needsInput": [(0, 880, 0.15), (0.22, 659.25, 0.24)],
}.items():
    frames = []
    for i in range(int(rate * 0.55)):
        t = i / rate
        value = 0
        for start, hz, duration in notes:
            local = t - start
            if 0 <= local < duration:
                envelope = min(1, local / 0.012) * (1 - local / duration) ** 2
                value += 0.3 * envelope * (math.sin(2 * math.pi * hz * local) + 0.12 * math.sin(4 * math.pi * hz * local))
        frames.append(struct.pack("<h", round(max(-1, min(1, value)) * 32767)))
    with wave.open(str(destination / f"{name}.wav"), "wb") as audio:
        audio.setparams((1, 2, rate, 0, "NONE", "not compressed"))
        audio.writeframes(b"".join(frames))
