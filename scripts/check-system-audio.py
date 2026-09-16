#!/usr/bin/env python3
"""Play a known stimulus through macOS, capture it natively, then inspect the recording."""
import argparse
import array
import json
import math
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import wave
import os

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--seconds", type=float, default=8)
parser.add_argument("--interrupt-after", type=float)
args = parser.parse_args()
if not math.isfinite(args.seconds) or args.seconds < 6:
    parser.error("--seconds must be finite and at least 6")
if args.interrupt_after is not None and not 5 <= args.interrupt_after < args.seconds:
    parser.error("--interrupt-after must be at least 5 and below --seconds")
if not all(shutil.which(tool) for tool in ("ffmpeg", "ffprobe", "afplay")):
    parser.error("ffmpeg, ffprobe and afplay are required for validation")
if subprocess.run(["pgrep", "-x", "Scriber"], capture_output=True).returncode == 0:
    parser.error("Quit the existing Scriber instance before starting a new check")

project = Path(__file__).resolve().parent.parent
(project / "artifacts").mkdir(exist_ok=True)
root = Path(tempfile.mkdtemp(prefix="system-audio-check-", dir=project / "artifacts"))
print(f"Evidence directory: {root}", flush=True)
stimulus = root / "stimulus.wav"
pcm = array.array("h")
for index in range(4 * 48_000):
    frequency = 880 if index < 2 * 48_000 else 1760
    local = index % (2 * 48_000)
    fade = min(1, local / 480, (2 * 48_000 - local) / 480)
    pcm.append(int(1000 * fade * math.sin(index * frequency * 2 * math.pi / 48_000)))
with wave.open(str(stimulus), "wb") as wav:
    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(48_000)
    wav.writeframes(pcm.tobytes())
subprocess.run(["open", str(project / "build/Scriber.app"), "--args", "--show-panel",
                "--system-audio-check", str(root), str(args.seconds)], check=True)

def read_state():
    path = root / "state.json"
    return json.loads(path.read_text()) if path.exists() else {}

deadline = time.monotonic() + 60
while time.monotonic() < deadline:
    state = read_state()
    if state.get("status") in ("failed", "completed", "interrupted"):
        raise RuntimeError(state)
    if state.get("status") == "recording":
        break
    time.sleep(0.1)
else:
    raise TimeoutError(f"Existing capture is still pending; inspect {root}. Do not restart blindly.")
pid = state["pid"]
command = subprocess.check_output(["ps", "-p", str(pid), "-o", "args="], text=True)
assert str(root) in command, "Unexpected capture process"
player = subprocess.Popen(["afplay", str(stimulus)])
began = time.monotonic()
interrupted = False
try:
    deadline = began + args.seconds + 30
    while not (root / "result.json").exists() and time.monotonic() < deadline:
        if args.interrupt_after is not None and not interrupted and time.monotonic() - began >= args.interrupt_after:
            os.kill(pid, signal.SIGTERM)
            interrupted = True
        time.sleep(0.1)
    assert (root / "result.json").exists(), f"Capture not complete; existing PID {pid}, {root}"
finally:
    if player.poll() is None:
        player.terminate()
    player.wait()
result = json.loads((root / "result.json").read_text())
print(json.dumps(result, indent=2))
assert result["status"] == ("interrupted" if args.interrupt_after is not None else "completed"), result
deadline = time.monotonic() + 10
while subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode == 0 and time.monotonic() < deadline:
    time.sleep(0.1)
assert subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0, "Capture process did not exit"
recording = Path(result["path"])
assert recording.parent == root and recording.suffix == ".m4a"
probe = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-show_entries",
    "format=duration,size:stream=codec_name,sample_rate,channels", "-of", "json", str(recording)
], text=True))
assert probe["streams"][0]["codec_name"] == "aac" and probe["streams"][0]["channels"] == 2, probe
expected_duration = args.interrupt_after if args.interrupt_after is not None else args.seconds
assert abs(float(probe["format"]["duration"]) - expected_duration) < 0.5, probe
subprocess.run(["ffmpeg", "-v", "error", "-i", str(recording), "-f", "null", "-"], check=True)
decoded = subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(recording),
                                   "-t", "16", "-ac", "1", "-ar", "48000", "-f", "f32le", "-"])
samples = array.array("f"); samples.frombytes(decoded)

def power(block, frequency):
    coefficient = 2 * math.cos(2 * math.pi * frequency / 48_000)
    a = b = 0.0
    for index, value in enumerate(block):
        value *= 0.5 - 0.5 * math.cos(2 * math.pi * index / (len(block) - 1))
        current = value + coefficient * a - b
        b, a = a, current
    return max(0, a * a + b * b - coefficient * a * b) / len(block) ** 2

energies = {frequency: 0.0 for frequency in (880, 1760, 3127)}
windows = []
for offset in range(0, len(samples) - 4096, 2048):
    block = samples[offset:offset + 4096]
    measured = {}
    for frequency in energies:
        measured[frequency] = power(block, frequency)
        energies[frequency] = max(energies[frequency], measured[frequency])
    windows.append(((offset + 2048) / 48_000, measured))
for frequency in (880, 1760):
    assert energies[frequency] > max(1e-9, energies[3127] * 20), energies
centroids = {}
for frequency, other in ((880, 1760), (1760, 880)):
    selected = [(t, p[frequency]) for t, p in windows
                if p[frequency] > energies[frequency] * 0.5 and p[frequency] > p[other] * 10]
    assert selected, "Stimulus cannot be distinguished from other system audio"
    centroids[frequency] = sum(t * p for t, p in selected) / sum(p for _, p in selected)
assert 1.5 < centroids[1760] - centroids[880] < 2.5, centroids
(root / "ffprobe.json").write_text(json.dumps(probe, indent=2))
(root / "spectrum.json").write_text(json.dumps({"power": energies, "centroidSeconds": centroids}, indent=2))
print(f"PASS: real system capture, complete decode, ordered stimulus frequencies: {centroids}")
