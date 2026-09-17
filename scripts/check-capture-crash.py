#!/usr/bin/env python3
"""SIGKILL an owned real Scriber capture and inspect the retained media prefix.

This tests write checkpoints; it does not test application restart/recovery UI.
"""
import argparse
import array
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--window', action='store_true', help='Capture an owned static quadrant window and both audio sources')
args = parser.parse_args()
if subprocess.run(['pgrep', '-x', 'Scriber'], capture_output=True).returncode == 0:
    parser.error('Quit the existing Scriber before this check')
project = Path(__file__).resolve().parent.parent
(project / 'artifacts').mkdir(exist_ok=True)
root = Path(tempfile.mkdtemp(prefix='capture-crash-', dir=project / 'artifacts'))
capture = root / 'capture'; capture.mkdir()
print('Evidence directory:', root, flush=True)
fixture = player = None
pid = None
target = None
try:
    command = ['open', str(project / 'build/Scriber.app'), '--args',
               '--display-video-check' if args.window else '--mixed-audio-check', str(capture), '60',
               '--audio-sources', 'both', '--microphone-device', 'BuiltInMicrophoneDevice']
    if args.window:
        helper = root / 'Fixture'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(project / 'tools/CaptureTargetFixture.swift'), '-o', str(helper)], check=True)
        fixture = subprocess.Popen([str(helper), str(root / 'fixture.json')])
        deadline = time.monotonic() + 10
        while not (root / 'fixture.json').exists() and time.monotonic() < deadline: time.sleep(.1)
        target = json.loads((root / 'fixture.json').read_text())
        command += ['--capture-window', str(target['windowID'])]
    tone = array.array('h', (int(1000 * math.sin(i * 880 * 2 * math.pi / 48000)) for i in range(20 * 48000)))
    with wave.open(str(root / 'tone.wav'), 'wb') as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(48000); wav.writeframes(tone.tobytes())
    subprocess.run(command, check=True)
    deadline = time.monotonic() + 40
    last = None
    while time.monotonic() < deadline:
        if (capture / 'state.json').exists():
            last = json.loads((capture / 'state.json').read_text()); pid = last['pid']
            assert last['status'] not in ['completed', 'failed'], last
            if last['status'] == 'recording' and player is None:
                player = subprocess.Popen(['afplay', str(root / 'tone.wav')])
            if last['durationSeconds'] >= 14:
                actual = subprocess.check_output(['ps', '-p', str(pid), '-o', 'args='], text=True)
                assert str(capture) in actual, 'Unexpected capture process'
                os.kill(pid, signal.SIGKILL)
                break
        time.sleep(.05)
    else: raise TimeoutError(f'Capture not ready for intentional crash: {root}')
    for _ in range(100):
        if subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode: break
        time.sleep(.1)
    assert subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode
    paths = [last['path']] + ([last['videoPath']] if args.window else [])
    pcm = []
    for path in paths:
        subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', path, '-fps_mode', 'passthrough',
                        '-enc_time_base:v', 'demux', '-f', 'null', '-'], check=True)
        pcm.append(subprocess.check_output(['ffmpeg', '-v', 'error', '-xerror', '-i', path, '-vn', '-ac', '1',
                                           '-ar', '48000', '-f', 'f32le', '-']))
    assert all(len(data) / 4 / 48000 >= 10 for data in pcm), [len(data) / 4 / 48000 for data in pcm]
    assert set(last['sourceFrames']) == {'system', 'microphone'} and all(last['sourceFrames'].values()), last
    samples = array.array('f'); samples.frombytes(pcm[0])
    first, end = 4 * 48000, 5 * 48000
    real = sum(samples[i] * math.cos(i * 880 * 2 * math.pi / 48000) for i in range(first, end))
    imaginary = sum(samples[i] * math.sin(i * 880 * 2 * math.pi / 48000) for i in range(first, end))
    amplitude = 2 * math.hypot(real, imaginary) / (end - first)
    assert amplitude > .005, amplitude
    if args.window:
        common = min(map(len, pcm)); assert pcm[0][:common] == pcm[1][:common]
        assert last['screenIdleFrames'] > 0 and last['screenRepeatedFrames'] > 0, last
        pixels = subprocess.check_output(['ffmpeg', '-v', 'error', '-ss', '2', '-i', last['videoPath'],
                                         '-frames:v', '1', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'])
        width, height = target['width'], target['height']
        assert len(pixels) == width * height * 3
        for (x, y), expected in zip([(width//4, height//4), (3*width//4, height//4), (width//4, 3*height//4), (3*width//4, 3*height//4)],
                                    [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)]):
            rgb = pixels[(y * width + x) * 3:(y * width + x) * 3 + 3]
            assert all(value > 150 if active else value < 90 for value, active in zip(rgb, expected)), list(rgb)
    native = subprocess.check_output([str(project / 'artifacts/InspectMedia'), *paths], text=True)
    report = {'atKill': last, 'decodedAudioFrames': [len(data) // 4 for data in pcm],
              'toneAmplitude': amplitude, 'native': json.loads(native)}
    (root / 'verified-prefix.json').write_text(json.dumps(report, indent=2))
    print('PASS: real capture SIGKILL prefix', report['decodedAudioFrames'], 'static window' if args.window else 'audio', flush=True)
finally:
    if player is not None:
        if player.poll() is None: player.terminate()
        player.wait()
    if pid and subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode == 0:
        actual = subprocess.check_output(['ps', '-p', str(pid), '-o', 'args='], text=True)
        if str(capture) in actual:
            os.kill(pid, signal.SIGTERM)
            for _ in range(100):
                if subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode: break
                time.sleep(.1)
            assert subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode
    if fixture is not None:
        if fixture.poll() is None: fixture.terminate()
        fixture.wait(timeout=10)
