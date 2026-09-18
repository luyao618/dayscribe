#!/usr/bin/env python3
"""Interrupt real SCK streams; verify recovery, bounded retries and retained media.

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
parser.add_argument('--permanent', action='store_true', help='Repeatedly interrupt recovered streams to exhaust retries')
parser.add_argument('--failed-addition', action='store_true', help='Try to add an unavailable mic while real system capture continues')
parser.add_argument('--stall', action='store_true', help='Stop samples without sending a failure; exercise the watchdog')
args = parser.parse_args()
if subprocess.run(['pgrep', '-x', 'Scriber'], capture_output=True).returncode == 0:
    parser.error('Quit the existing Scriber first')
project = Path(__file__).resolve().parent.parent
root = Path(tempfile.mkdtemp(prefix='source-failure-', dir=project / 'artifacts'))
print('Evidence directory:', root, flush=True)
mode = 'system' if args.failed_addition else (args.source if args.only_source else 'both')
seconds = 10 if args.permanent else 6
# This diagnostic asserts Chinese messages; pin only this process's language.
command = ['open', str(project / 'build/Scriber.app'), '--args', '-AppleLanguages', '(zh-Hans)', '--show-panel',
           '--display-video-check' if args.video else '--panel-audio-check', str(root), str(seconds), '--audio-sources', mode]
if args.failed_addition:
    command += ['--failed-addition-check', '--microphone-device', 'Scriber-Missing-Diagnostic-Input']
else:
    command += [('--stall-' if args.stall else '--interrupt-') + args.source + '-source']
if args.permanent: command += ['--persistent-source-interruption']
stimulus = root / 'stimulus.wav'
pcm = array.array('h', (int(1000 * math.sin(i * 880 * 2 * math.pi / 48000)) for i in range((seconds + 2) * 48000)))
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
    assert result['audioSaved'], result
    if args.failed_addition:
        assert result['status'] == 'completed' and not result['error'], result
        assert result['sourceEvents'] == [{'success': False, 'sources': [0],
            'message': '无法开启新的声音来源，原有录制继续：麦克风设备不可用。'}], result
        assert not result['sourceFrames'].get('microphone', 0) and not result['reconnectCounts'], result
        wanted = [0]
    else:
        assert result['status'] == 'failed' and result['error'], result
        assert 1 <= result['reconnectCounts'].get(args.source, 0) <= 2, result
        if args.permanent:
            assert args.source in result['sourceFailures'] and result['reconnectCounts'][args.source] == 2, result
        else:
            assert args.source not in result['sourceFailures'] and '已恢复' in result['recoveryNotice'], result
        wanted = [0 if args.source == 'system' else 1] if args.only_source else [0, 1]
    assert result['sources'] == wanted, 'A failure must not silently change user selection'
    if args.only_source and args.permanent:
        assert 1 < result['wallElapsedSeconds'] < seconds, result
    else:
        assert result['wallElapsedSeconds'] >= seconds, result
        trace = result['sourceTrace']
        late = [x for x in trace if x['hostTime'] > trace[-1]['hostTime'] - 1.2]
        assert len(late) >= 4, late
        for source in ['system', 'microphone']:
            if (0 if source == 'system' else 1) not in wanted: continue
            first, last = (x['receivedFrames'].get(source, 0) for x in [late[0], late[-1]])
            if args.permanent and source == args.source: assert last == first, late
            else: assert last > first, late
        if not args.only_source and not args.failed_addition:
            healthy = 'microphone' if args.source == 'system' else 'system'
            assert not result['reconnectCounts'].get(healthy, 0), result
    files = [result['path']] + ([result['videoPath']] if args.video else [])
    decoded = []
    for path in files:
        subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', path, '-fps_mode', 'passthrough',
                        '-enc_time_base:v', 'demux', '-f', 'null', '-'], check=True)
        pcm = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', path, '-vn', '-ac', '1', '-ar', '48000', '-f', 'f32le', '-'])
        decoded.append(pcm)
    assert len(decoded[0]) // 4 == result['frames'], result
    if args.failed_addition or (args.source == 'microphone' and not args.only_source):
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
    assert (manifest.get('captureError') or '') == result['error'], manifest
    for _ in range(100):
        if subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode: break
        time.sleep(.1)
    assert subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode, 'Capture did not exit after finalization'
    print('PASS:', args.source, 'failed addition' if args.failed_addition else ('permanent' if args.permanent else 'recovered'),
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
