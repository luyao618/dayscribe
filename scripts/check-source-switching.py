#!/usr/bin/env python3
"""Verify real source changes, native callbacks and the recorded signal; keep evidence local."""
import argparse
import array
import json
import math
from pathlib import Path
import subprocess
import tempfile
import time
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--sources", choices=("both", "system", "microphone"), default="both")
parser.add_argument("--microphone-device")
args = parser.parse_args()
if subprocess.run(["pgrep", "-x", "Scriber"], capture_output=True).returncode == 0:
    parser.error("Quit the existing Scriber before this check")
project = Path(__file__).resolve().parent.parent
(project / "artifacts").mkdir(exist_ok=True)
root = Path(tempfile.mkdtemp(prefix="source-switch-check-", dir=project / "artifacts"))
print(f"Evidence directory: {root}", flush=True)
stimulus = root / "stimulus.wav"
signal = array.array("h", (int(1000 * math.sin(i * 880 * 2 * math.pi / 48000)) for i in range(12 * 48000)))
with wave.open(str(stimulus), "wb") as wav:
    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(48000)
    wav.writeframes(signal.tobytes())
command = ["open", str(project / "build/Scriber.app"), "--args", "--show-panel", "--panel-audio-check",
           str(root), "11", "--audio-sources", args.sources, "--switch-sources", "--panel-snapshots"]
if args.microphone_device:
    command += ["--microphone-device", args.microphone_device]
subprocess.run(command, check=True)

def state():
    path = root / "state.json"
    return json.loads(path.read_text()) if path.exists() else {}

deadline = time.monotonic() + 60
while time.monotonic() < deadline:
    current = state()
    if current.get("status") == "recording":
        break
    if current.get("status") in ("failed", "completed", "interrupted"):
        raise RuntimeError(current)
    time.sleep(0.1)
else:
    raise TimeoutError(f"Existing capture is pending in {root}; do not restart blindly")
pid = current["pid"]
player = subprocess.Popen(["afplay", str(stimulus)])
try:
    deadline = time.monotonic() + 35
    while not (root / "result.json").exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    assert (root / "result.json").exists(), f"Inspect existing capture PID {pid}: {root}"
finally:
    if player.poll() is None:
        player.terminate()
    player.wait()
result = json.loads((root / "result.json").read_text())
print(json.dumps({k: v for k, v in result.items() if k != "sourceTrace"}, indent=2))
assert result["status"] == "completed" and not result["error"], result
assert [event["sources"] for event in result["sourceEvents"]] == [[0], [1], [0, 1], []], result
assert [event["success"] for event in result["sourceEvents"]] == [True, True, True, False], result
assert result["sources"] == [0, 1], result
recording = Path(result["path"])
assert recording.parent == root and len(list(root.glob("*.m4a"))) == 1
subprocess.run(["ffmpeg", "-v", "error", "-i", str(recording), "-f", "null", "-"], check=True)
decoded = subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(recording), "-ac", "1", "-ar", "48000", "-f", "f32le", "-"])
samples = array.array("f"); samples.frombytes(decoded)
epoch = min(result["sourceFirstTimes"].values())
events = result["sourceEvents"]

def level(start, end):
    a, b = int(start * 48000), int(end * 48000)
    assert 0 <= a < b <= len(samples)
    real = imaginary = 0.0
    for i in range(a, b):
        real += samples[i] * math.cos(i * 880 * 2 * math.pi / 48000)
        imaginary += samples[i] * math.sin(i * 880 * 2 * math.pi / 48000)
    return math.hypot(real, imaginary) * 2 / (b - a)

intervals = [(events[i]["appliedHostTime"] + 0.5, events[i + 1]["requestedHostTime"] - 0.4) for i in range(3)]
levels = [level(a - epoch, b - epoch) for a, b in intervals]
assert levels[0] > 0.005 and levels[2] > 0.005, levels
assert levels[1] < min(levels[0], levels[2]) / 10, levels
for index, (disabled, active) in enumerate([("microphone", "system"), ("system", "microphone")]):
    a, b = intervals[index]
    trace = [x for x in result["sourceTrace"] if a < x["hostTime"] < b]
    assert len(trace) >= 3, trace
    assert trace[-1]["receivedFrames"].get(disabled, 0) == trace[0]["receivedFrames"].get(disabled, 0), trace
    assert trace[-1]["receivedFrames"].get(active, 0) > trace[0]["receivedFrames"].get(active, 0), trace
for filename in ("panel-recording.png", "panel-saved.png"):
    assert (root / filename).is_file(), filename
deadline = time.monotonic() + 10
while subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode == 0 and time.monotonic() < deadline:
    time.sleep(0.1)
assert subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0, "Capture did not exit"
(root / "switch-signal.json").write_text(json.dumps({"toneAmplitudes": levels, "intervalsHostTime": intervals}, indent=2))
print(f"PASS: live source changes, hardware callback stop/restart, one decoded file; tone amplitudes {levels}")
