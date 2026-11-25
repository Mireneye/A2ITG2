"""Test MP3s for src/audio (python + the lame command: a test helper, not app code).

A 3-second stereo 44.1 kHz track, silent except for one-sample clicks at exactly 1.000 s and 2.000 s
(samples 44100 and 88200), encoded by LAME three ways that StepMania treats differently:
  click_cbr_info.mp3  constant bitrate: LAME writes an "Info" frame first (StepMania plays it as silence)
  click_vbr_xing.mp3  variable bitrate: LAME writes a "Xing" frame first (StepMania skips it)
  click_cbr_none.mp3  constant bitrate, no info frame (-t)
And busy.mp3: 10 seconds of tones over noise, dense like music, for the size-limit tests (silence
compresses to almost nothing whatever the bitrate allows).
Writes into tests/fixtures/ (git-ignored).
"""
import os, struct, subprocess, wave

RATE, SECONDS, CLICKS = 44100, 3, (44100, 88200)
here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "..", "tests", "fixtures")
os.makedirs(out, exist_ok=True)

wav = os.path.join(out, "click.wav")
with wave.open(wav, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(RATE)
    frames = bytearray(RATE * SECONDS * 4)
    for at in CLICKS:
        struct.pack_into("<hh", frames, at * 4, 30000, 30000)
    w.writeframes(bytes(frames))

for name, args in (("click_cbr_info", ["-b", "128"]), ("click_vbr_xing", ["-V", "2"]), ("click_cbr_none", ["-b", "128", "-t"])):
    subprocess.run(["lame", "--quiet", *args, wav, os.path.join(out, name + ".mp3")], check=True)
import math, random
random.seed(7)
busy = os.path.join(out, "busy.wav")
with wave.open(busy, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(RATE)
    frames = bytearray()
    for i in range(RATE * 10):
        t = i / RATE
        tone = sum(math.sin(2 * math.pi * f * t) for f in (220, 331, 517, 1250, 3100)) / 5
        left = 0.5 * tone + 0.25 * (random.random() * 2 - 1)
        right = 0.5 * tone + 0.25 * (random.random() * 2 - 1)
        frames += struct.pack("<hh", int(left * 30000), int(right * 30000))
    w.writeframes(bytes(frames))
subprocess.run(["lame", "--quiet", "-b", "192", busy, os.path.join(out, "busy.mp3")], check=True)
print("wrote", out)
