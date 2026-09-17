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
parser.add_argument("--video", action="store_true", help="Record the main display to MP4 plus the same standalone M4A")
parser.add_argument("--seconds", type=float, default=8)
parser.add_argument("--interrupt-after", type=float)
parser.add_argument("--sources", choices=("system", "microphone", "both"), default="system")
parser.add_argument("--microphone-device")
parser.add_argument("--capture-display")
parser.add_argument("--capture-window")
parser.add_argument("--capture-region")
parser.add_argument("--playback-device", help="Route the fixture to this device UID without changing system defaults")
parser.add_argument("--stimulus-amplitude", type=int, default=1000, help="Test PCM peak, 1–4096 out of 32767")
parser.add_argument("--expected-microphone-rate", type=int)
parser.add_argument("--panel", action="store_true", help="Exercise the normal recorder panel with real capture")
parser.add_argument("--quit-via-appkit", action="store_true", help="Use NSApplication termination on the interruption signal")
args = parser.parse_args()
if not 1 <= args.stimulus_amplitude <= 4096:
    parser.error("--stimulus-amplitude must be between 1 and 4096")
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
player_command = ["afplay", str(stimulus)]
if args.playback_device:
    helper = project / "artifacts/PlayAudioFixture"
    subprocess.run(["xcrun", "swiftc", str(project / "tools/PlayAudioFixture.swift"), "-o", str(helper)], check=True)
    player_command = [str(helper), str(stimulus), args.playback_device]
pcm = array.array("h")
for index in range(4 * 48_000):
    frequency = 880 if index < 2 * 48_000 else 1760
    local = index % (2 * 48_000)
    fade = min(1, local / 480, (2 * 48_000 - local) / 480)
    pcm.append(int(args.stimulus_amplitude * fade * math.sin(index * frequency * 2 * math.pi / 48_000)))
with wave.open(str(stimulus), "wb") as wav:
    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(48_000)
    wav.writeframes(pcm.tobytes())
command = ["open", str(project / "build/Scriber.app"), "--args", "--show-panel",
           "--display-video-check" if args.video else ("--panel-audio-check" if args.panel else "--mixed-audio-check"), str(root), str(args.seconds), "--audio-sources", args.sources]
if args.panel:
    command += ["--panel-snapshots"]
if args.quit_via_appkit:
    command += ["--quit-via-appkit"]
if args.microphone_device:
    command += ["--microphone-device", args.microphone_device]
for flag in ("capture_display", "capture_window", "capture_region"):
    if getattr(args, flag) is not None:
        command += ["--" + flag.replace("_", "-"), getattr(args, flag)]
subprocess.run(command, check=True)

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
player = subprocess.Popen(player_command)
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
assert not result["error"], result
expected_sources = {"system", "microphone"} if args.sources == "both" else {args.sources}
assert set(result["sourceFrames"]) == expected_sources, result
assert all(result["sourceFrames"][source] > 0 for source in expected_sources), result
if args.expected_microphone_rate is not None:
    assert result["sourceRates"].get("microphone") == args.expected_microphone_rate, result
assert len(list(root.glob("*.m4a"))) == 1, "Expected one final mixed audio file"
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
(root / "ffprobe.json").write_text(json.dumps(probe, indent=2))
# Video's common epoch includes bounded stream startup before the diagnostic wait.
assert abs(float(probe["format"]["duration"]) - expected_duration) < (2 if args.video else 0.5), probe
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
(root / "spectrum.json").write_text(json.dumps({"power": energies}, indent=2))
for frequency in (880, 1760):
    assert energies[frequency] > max(1e-9, energies[3127] * 20), energies
centroids = {}
for frequency, other in ((880, 1760), (1760, 880)):
    selected = [(t, p[frequency]) for t, p in windows
                if p[frequency] > energies[frequency] * 0.5 and p[frequency] > p[other] * 10]
    assert selected, "Stimulus cannot be distinguished from other system audio"
    centroids[frequency] = sum(t * p for t, p in selected) / sum(p for _, p in selected)
assert 1.5 < centroids[1760] - centroids[880] < 2.5, centroids
(root / "spectrum.json").write_text(json.dumps({"power": energies, "centroidSeconds": centroids}, indent=2))
print(f"PASS: real {args.sources} capture, one decoded M4A, ordered stimulus frequencies: {centroids}")

if args.video:
    assert result["audioSaved"] and result["videoSaved"], result
    assert result["screenReceivedFrames"] > 0 and result["videoFrames"] >= result["screenReceivedFrames"], result
    assert len(list(root.glob("*.mp4"))) == 1
    video_path = Path(result["videoPath"])
    assert video_path.with_suffix(".m4a") == recording
    video_probe = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_name,codec_type,width,height,start_time,duration,color_space,color_transfer,color_primaries",
        "-of", "json", str(video_path)], text=True))
    (root / "video-ffprobe.json").write_text(json.dumps(video_probe, indent=2))
    assert {x["codec_name"] for x in video_probe["streams"]} == {"h264", "aac"}, video_probe
    picture = next(x for x in video_probe["streams"] if x["codec_type"] == "video")
    assert (picture.get("color_space"), picture.get("color_transfer"), picture.get("color_primaries")) == (
        "bt709", "iec61966-2-1", "bt709"), picture
    minimum = (2, 2) if args.capture_window or args.capture_region else (640, 480)
    assert picture["width"] >= minimum[0] and picture["height"] >= minimum[1], picture
    assert abs(result["durationSeconds"] - result["videoDurationSeconds"]) < 1 / 48000, result
    assert abs(float(video_probe["format"]["duration"]) - float(probe["format"]["duration"])) < 0.1
    # Preserve the variable screen-frame timestamps; a guessed constant output
    # rate can manufacture repeated DTS values in the null muxer.
    decode = subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-i", str(video_path),
        "-fps_mode", "passthrough", "-enc_time_base:v", "demux", "-f", "null", "-"],
        capture_output=True, text=True, check=True)
    assert not decode.stderr, decode.stderr
    packet_probe = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,dts_time",
        "-of", "json", str(video_path)], text=True))
    packet_times = [float(x["pts_time"]) for x in packet_probe["packets"]]
    dts_times = [float(x["dts_time"]) for x in packet_probe["packets"]]
    assert all(b > a for a, b in zip(dts_times, dts_times[1:])), dts_times
    expected_first = result["screenFirstHostTime"] - result["videoEpochHostTime"]
    assert abs(packet_times[0] - expected_first) < 0.002, (packet_times[0], expected_first)
    assert all(b > a for a, b in zip(packet_times, packet_times[1:])), packet_times
    assert len(packet_times) == result["videoFrames"], (len(packet_times), result["videoFrames"])
    (root / "screen-timeline.json").write_text(json.dumps({"firstCaptureRelativeSeconds": expected_first,
        "firstPacketSeconds": packet_times[0], "lastPacketSeconds": packet_times[-1], "encodedFrames": len(packet_times)}, indent=2))
    video_audio = array.array("f")
    video_audio.frombytes(subprocess.check_output([
        "ffmpeg", "-v", "error", "-i", str(video_path), "-t", "16", "-vn", "-ac", "1", "-ar", "48000", "-f", "f32le", "-"]))
    common = min(len(samples), len(video_audio))
    expected_decoded = min(result["frames"], 16 * 48000)
    assert len(samples) == len(video_audio) == expected_decoded, (len(samples), len(video_audio), expected_decoded)
    maximum_error = max(abs(samples[i] - video_audio[i]) for i in range(common))
    assert maximum_error < 0.0001, maximum_error
    (root / "paired-audio.json").write_text(json.dumps({"comparedFrames": common, "maximumSampleError": maximum_error}, indent=2))
    print(f"PASS: actual {picture['width']}x{picture['height']} screen, decoded MP4+M4A, same PCM endpoint and matching decoded audio")
