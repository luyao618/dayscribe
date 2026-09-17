#!/usr/bin/env python3
"""Interrupt a real SCK audio stream; verify isolation and retained decodable output.

This deliberately stops a stream. It is not a physical device-disconnection test.
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
parser.add_argument('--source', choices=['system', 'microphone'], default='microphone')
parser.add_argument('--only-source', action='store_true', help='Verify safe stop when the only selected stream fails')
parser.add_argument('--video', action='store_true')
parser.add_argument('--stall', action='store_true', help='Stop samples without sending a failure; exercise the watchdog')
args = parser.parse_args()
if subprocess.run(['pgrep', '-x', 'Scriber'], capture_output=True).returncode == 0:
    parser.error('Quit the existing Scriber first')
project = Path(__file__).resolve().parent.parent
root = Path(tempfile.mkdtemp(prefix='source-failure-', dir=project / 'artifacts'))
print('Evidence directory:', root, flush=True)
mode = args.source if args.only_source else 'both'
command = ['open', str(project / 'build/Scriber.app'), '--args', '--show-panel',
           '--display-video-check' if args.video else '--panel-audio-check', str(root), '6',
           '--audio-sources', mode, ('--stall-' if args.stall else '--interrupt-') + args.source + '-source']
stimulus = root / 'stimulus.wav'
pcm = array.array('h', (int(1000 * math.sin(i * 880 * 2 * math.pi / 48000)) for i in range(8 * 48000)))
with wave.open(str(stimulus), 'wb') as wav:
    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(48000); wav.writeframes(pcm.tobytes())
pid = None
player = None
try:
    subprocess.run(command, check=True)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if (root / 'state.json').exists():
            state = json.loads((root / 'state.json').read_text())
            pid = state['pid']
            if state['status'] == 'recording' and player is None:
                player = subprocess.Popen(['afplay', str(stimulus)])
            if (root / 'result.json').exists(): break
        time.sleep(.1)
    assert (root / 'result.json').exists(), f'Inspect live process {pid}: {root}'
    result = json.loads((root / 'result.json').read_text())
    assert result['status'] == 'failed' and result['audioSaved'] and result['error'], result
    assert args.source in result['sourceFailures'], result
    if args.stall: assert '超过 1 秒' in result['sourceFailures'][args.source], result
    wanted = [0 if args.source == 'system' else 1] if args.only_source else [0, 1]
    assert result['sources'] == wanted, 'A failure must not silently change user selection'
    if args.only_source:
        assert 1 < result['wallElapsedSeconds'] < 5, result
    else:
        assert result['wallElapsedSeconds'] >= 6, result
        trace = result['sourceTrace']
        late = [x for x in trace if x['hostTime'] > trace[0]['hostTime'] + 3]
        assert len(late) >= 8, late
        healthy = 'microphone' if args.source == 'system' else 'system'
        assert late[-1]['receivedFrames'][healthy] > late[0]['receivedFrames'][healthy], late
        assert late[-1]['receivedFrames'].get(args.source, 0) == late[0]['receivedFrames'].get(args.source, 0), late
    files = [result['path']] + ([result['videoPath']] if args.video else [])
    decoded = []
    for path in files:
        subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', path, '-fps_mode', 'passthrough',
                        '-enc_time_base:v', 'demux', '-f', 'null', '-'], check=True)
        pcm = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', path, '-vn', '-ac', '1', '-ar', '48000', '-f', 'f32le', '-'])
        decoded.append(pcm)
    assert len(decoded[0]) // 4 == result['frames'], result
    if args.source == 'microphone' and not args.only_source:
        samples = array.array('f'); samples.frombytes(decoded[0])
        first, last = 4 * 48000, 5 * 48000
        real = sum(samples[i] * math.cos(i * 880 * 2 * math.pi / 48000) for i in range(first, last))
        imaginary = sum(samples[i] * math.sin(i * 880 * 2 * math.pi / 48000) for i in range(first, last))
        assert 2 * math.hypot(real, imaginary) / (last - first) > .005, 'Surviving system tone missing from encoded media'
    if args.video:
        assert result['videoSaved'] and result['videoFrames'] > 0, result
        assert decoded[0] == decoded[1]
    manifests = list(root.glob('.scriber-*/session.json'))
    assert len(manifests) == 1
    manifest = json.loads(manifests[0].read_text())
    assert manifest['captureError'] == result['error'], manifest
    for _ in range(100):
        if subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode: break
        time.sleep(.1)
    assert subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode, 'Capture did not exit after finalization'
    print('PASS:', args.source, 'sole' if args.only_source else 'survivor continues',
          'video' if args.video else 'audio', result['durationSeconds'], result['frames'], flush=True)
finally:
    if player is not None:
        if player.poll() is None: player.terminate()
        player.wait()
    if pid and subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode == 0:
        command = subprocess.check_output(['ps', '-p', str(pid), '-o', 'args='], text=True)
        if str(root) in command:
            os.kill(pid, signal.SIGTERM)
            for _ in range(100):
                if subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode: break
                time.sleep(.1)
            assert subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode, 'Owned capture has not exited'
