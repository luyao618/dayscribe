#!/usr/bin/env python3
"""Verify an actual capture owns its session through saving and process death."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--crash', action='store_true')
parser.add_argument('--video', action='store_true', help='Check ownership through closing both MP4 and M4A')
args = parser.parse_args()
if subprocess.run(['pgrep', '-x', 'Scriber'], capture_output=True).returncode == 0:
    parser.error('Quit the existing Scriber first')
project = Path(__file__).resolve().parent.parent
(project / 'artifacts').mkdir(exist_ok=True)
root = Path(tempfile.mkdtemp(prefix='session-lease-', dir=project / 'artifacts'))
pid = None
print('Evidence directory:', root, flush=True)

def acquire(path):
    # Do not create a missing lock: capture must publish it before the manifest.
    descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False
    finally:
        os.close(descriptor)

try:
    subprocess.run(['open', str(project / 'build/Scriber.app'), '--args',
                    '--display-video-check' if args.video else '--mixed-audio-check', str(root),
                    '60' if args.crash else '5', '--audio-sources', 'both', '--keep-check-open'], check=True)
    deadline = time.monotonic() + 20
    active = None
    while time.monotonic() < deadline:
        if (root / 'state.json').exists():
            state = json.loads((root / 'state.json').read_text()); pid = state['pid']
            assert state['status'] not in ['completed', 'failed'], state
            if state['status'] == 'recording' and state['frames'] > 48000:
                active = state; break
        time.sleep(.05)
    assert active
    stage = Path(active['path']).parent
    lock = stage / 'capture.lock'
    manifest = json.loads((stage / 'session.json').read_text())
    assert manifest['closed'] == [] and not acquire(lock)
    if args.crash:
        while time.monotonic() < deadline:
            state = json.loads((root / 'state.json').read_text())
            assert state['status'] == 'recording', state
            if state['durationSeconds'] > 3: break
            time.sleep(.05)
        assert state['durationSeconds'] > 3
        actual = subprocess.check_output(['ps', '-p', str(pid), '-o', 'args='], text=True)
        assert str(root) in actual
        assert not acquire(lock)
        os.kill(pid, signal.SIGKILL)
        for _ in range(100):
            if subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode: break
            time.sleep(.1)
        assert subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode
        saved_path = state['path']
    else:
        deadline = time.monotonic() + 15
        while not (root / 'result.json').exists() and time.monotonic() < deadline: time.sleep(.05)
        state = json.loads((root / 'result.json').read_text())
        assert state['status'] == 'completed' and state['audioSaved'], state
        assert subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode == 0, 'App must remain alive for this check'
        manifest = json.loads((stage / 'session.json').read_text())
        kinds = ['m4a', 'mp4'] if args.video else ['m4a']
        assert manifest['closed'] == kinds and manifest['published'] == kinds, manifest
        if args.video: assert state['videoSaved'], state
        saved_path = state['path']
    assert acquire(lock), 'Session should be available after finalization or process death'
    assert lock.exists(), 'Releasing must not unlink the shared lock'
    subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', saved_path, '-f', 'null', '-'], check=True)
    if args.video:
        subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', state['videoPath'],
                        '-fps_mode', 'passthrough', '-enc_time_base:v', 'demux', '-f', 'null', '-'], check=True)
    (root / 'lease-verification.json').write_text(json.dumps({'active': active, 'after': state,
                                                           'crash': args.crash, 'availableAfter': True}, indent=2))
    print('PASS: active session excluded; ownership released after', 'SIGKILL' if args.crash else 'save while app stays alive', flush=True)
finally:
    if pid and subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode == 0:
        actual = subprocess.check_output(['ps', '-p', str(pid), '-o', 'args='], text=True)
        if str(root) in actual:
            os.kill(pid, signal.SIGTERM)
            for _ in range(100):
                if subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode: break
                time.sleep(.1)
            assert subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode
