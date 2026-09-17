#!/usr/bin/env python3
"""Check actual window/region capture using an app-owned visible quadrant fixture."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--display-id", type=int, help="Place the fixture on a specific connected display")
args = parser.parse_args()
project = Path(__file__).resolve().parent.parent
(project / "artifacts").mkdir(exist_ok=True)
root = Path(tempfile.mkdtemp(prefix="target-check-", dir=project / "artifacts"))
print(f"Target evidence: {root}", flush=True)
helper = root / "CaptureTargetFixture"
subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(project / "tools/CaptureTargetFixture.swift"), "-o", str(helper)], check=True)
report = root / "fixture.json"
command = [str(helper), str(report)]
if args.display_id is not None:
    command += [str(args.display_id)]
fixture = subprocess.Popen(command)
try:
    deadline = time.monotonic() + 10
    while not report.exists() and time.monotonic() < deadline and fixture.poll() is None:
        time.sleep(0.1)
    assert report.exists(), "Fixture did not open on the requested display"
    target = json.loads(report.read_text())
    assert target["actualFrame"] == target["requestedFrame"], target
    for kind in ("window", "region"):
        print(f"Checking {kind} on display {target['displayID']}", flush=True)
        command = ["python3", str(project / "scripts/check-system-audio.py"), "--video", "--sources", "system", "--seconds", "8"]
        if kind == "window":
            command += ["--capture-window", str(target["windowID"])]
        else:
            command += ["--capture-display", str(target["displayID"]), "--capture-region", ",".join(str(v) for v in target["region"])]
        capture = subprocess.run(command, capture_output=True, text=True, timeout=100)
        (root / f"{kind}.log").write_text(capture.stdout + capture.stderr)
        assert capture.returncode == 0, f"Capture failed; inspect {root / (kind + '.log')} before retrying"
        match = re.search(r"^Evidence directory: (.+)$", capture.stdout, re.MULTILINE)
        assert match, capture.stdout
        evidence = Path(match[1])
        result = json.loads((evidence / "result.json").read_text())
        probe = json.loads((evidence / "video-ffprobe.json").read_text())
        video = next(x for x in probe["streams"] if x["codec_type"] == "video")
        width, height = video["width"], video["height"]
        assert (width, height) == (target["width"], target["height"]), (video, target)
        pixels = subprocess.check_output(["ffmpeg", "-v", "error", "-ss", "2", "-i", result["videoPath"],
            "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"])
        assert len(pixels) == width * height * 3
        colors = []
        for x, y in ((width // 4, height // 4), (width * 3 // 4, height // 4),
                     (width // 4, height * 3 // 4), (width * 3 // 4, height * 3 // 4)):
            colors.append([sum(pixels[((y + dy) * width + x + dx) * 3 + c]
                for dx in range(-10, 11) for dy in range(-10, 11)) / 441 for c in range(3)])
        for actual, expected in zip(colors, ((1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0))):
            assert all(value > 150 if active else value < 90 for value, active in zip(actual, expected)), colors
        subprocess.run(["ffmpeg", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{width}x{height}",
            "-i", "pipe:0", "-frames:v", "1", str(root / f"{kind}.png")], input=pixels, check=True)
        (root / f"{kind}-bounds.json").write_text(json.dumps({"captureEvidence": str(evidence), "size": [width, height], "quadrantRGB": colors}, indent=2))
        print(f"PASS: {kind}, {width}x{height}, all four quadrants in their correct positions", flush=True)
    invalid = root / "unavailable-window"
    invalid.mkdir()
    subprocess.run(["open", str(project / "build/Scriber.app"), "--args", "--display-video-check",
        str(invalid), "1", "--audio-sources", "system", "--capture-window", "4294967295"], check=True)
    deadline = time.monotonic() + 15
    while not (invalid / "result.json").exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    assert (invalid / "result.json").exists(), f"Inspect the existing failed-target check in {invalid}"
    failure = json.loads((invalid / "result.json").read_text())
    assert failure["status"] == "failed" and "不可用" in failure["error"], failure
    assert not failure["audioSaved"] and not failure["videoSaved"] and failure["frames"] == 0
    assert failure["screenReceivedFrames"] == 0
    deadline = time.monotonic() + 5
    while subprocess.run(["kill", "-0", str(failure["pid"])], capture_output=True).returncode == 0 and time.monotonic() < deadline:
        time.sleep(0.1)
    assert subprocess.run(["kill", "-0", str(failure["pid"])], capture_output=True).returncode != 0
    print("PASS: unavailable target reports failure, records nothing and exits")
finally:
    if fixture.poll() is None:
        fixture.terminate()
    fixture.wait(timeout=10)
