#!/usr/bin/env python3
"""Run a real native microphone check; keep media/evidence under ignored artifacts/."""
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--seconds", type=float, default=5)
parser.add_argument("--interrupt-after", type=float)
args = parser.parse_args()
if not math.isfinite(args.seconds) or args.seconds <= 0:
    parser.error("--seconds must be positive and finite")
if args.interrupt_after is not None and not 0 < args.interrupt_after < args.seconds:
    parser.error("--interrupt-after must be between zero and --seconds")
if not all(shutil.which(tool) for tool in ("ffmpeg", "ffprobe")):
    parser.error("Install ffmpeg (including ffprobe) for media verification")
if subprocess.run(["pgrep", "-x", "Scriber"], capture_output=True).returncode == 0:
    parser.error("Quit the existing Scriber instance before this check")

project = Path(__file__).resolve().parent.parent
app = project / "build/Scriber.app"
if not app.exists():
    parser.error("Build Scriber.app with scripts/build-app.sh first")
artifacts = project / "artifacts"
artifacts.mkdir(exist_ok=True)
root = Path(tempfile.mkdtemp(prefix="mic-check-", dir=artifacts))
result_file = root / "result.json"
print(f"Evidence directory: {root}", flush=True)
subprocess.run(["open", str(app), "--args", "--show-panel", "--microphone-check",
                str(root), str(args.seconds)], check=True)

def wait_for(predicate, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise TimeoutError(f"Check still pending; inspect existing Scriber and {root}. "
                       "The app has not been killed or restarted.")

if args.interrupt_after is not None:
    wait_for(lambda: result_file.exists() or bool(list(root.glob("*.m4a"))), 60)
    if not result_file.exists():
        time.sleep(args.interrupt_after)
        pids = subprocess.check_output(["pgrep", "-x", "Scriber"], text=True).split()
        assert len(pids) == 1, pids
        pid = int(pids[0])
        command = subprocess.check_output(["ps", "-p", str(pid), "-o", "args="], text=True)
        assert str(root) in command, "Refusing to signal an unrelated process"
        os.kill(pid, signal.SIGTERM)

wait_for(result_file.exists, args.seconds + 60)
result = json.loads(result_file.read_text())
expected = "interrupted" if args.interrupt_after is not None else "completed"
assert result["status"] == expected, result
wait_for(lambda: subprocess.run(["kill", "-0", str(result["pid"])],
                                capture_output=True).returncode != 0, 10)
media = Path(result["path"])
assert media.parent == root and media.is_file(), result
probe = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-show_entries",
    "format=duration,size:stream=codec_name,sample_rate,channels", "-of", "json", str(media)
], text=True))
assert probe["streams"][0]["codec_name"] == "aac", probe
duration = float(probe["format"]["duration"])
target = args.interrupt_after if args.interrupt_after is not None else args.seconds
assert abs(duration - target) < 0.5, (duration, target)
subprocess.run(["ffmpeg", "-v", "error", "-i", str(media), "-f", "null", "-"],
               capture_output=True, check=True)
(root / "ffprobe.json").write_text(json.dumps(probe, indent=2))
print(json.dumps(result, indent=2))
print(f"PASS: {expected}; {duration:.3f}s AAC; full decode succeeded.")
