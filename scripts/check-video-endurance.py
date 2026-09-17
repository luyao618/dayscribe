#!/usr/bin/env python3
"""Two-hour real window capture, paired audio, resource and start/end sync evidence.

Use --seconds 30 for calibration. An explicitly identified owned audio endurance
run can continue concurrently; its process and build are never changed here.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import statistics
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seconds', type=float, default=2*3600)
parser.add_argument('--alongside-audio-root', type=Path)
parser.add_argument('--app', type=Path, help='Use an isolated signed Scriber.app without changing an active capture build')
args = parser.parse_args()
if not math.isfinite(args.seconds) or args.seconds < 20: parser.error('--seconds must be at least 20')
project = Path(__file__).resolve().parent.parent
app_bundle = (args.app or project/'build/Scriber.app').resolve()
existing = subprocess.run(['pgrep', '-x', 'Scriber'], capture_output=True, text=True)
pids = set(map(int, existing.stdout.split()))
peer = None
if args.alongside_audio_root:
    peer = args.alongside_audio_root.resolve()
    if not peer.is_relative_to(project/'artifacts'): parser.error('Concurrent capture must be an owned artifacts run')
    owner = json.loads((peer/'owner.json').read_text())
    state = json.loads((peer/'state.json').read_text())
    command = subprocess.check_output(['ps', '-p', str(owner['appPID']), '-o', 'args='], text=True).strip()
    expected = f'{project}/build/Scriber.app/Contents/MacOS/Scriber --mixed-audio-check {peer} 28800 --audio-sources both'
    if command != expected or state['pid'] != owner['appPID'] or state['status'] != 'recording' or pids != {owner['appPID']}:
        parser.error('Existing capture does not match the explicitly owned active audio run')
elif pids: parser.error('Quit existing Scriber or explicitly identify the owned concurrent audio test')
root = Path(tempfile.mkdtemp(prefix='video-endurance-', dir=project/'artifacts'))
print('Evidence directory:', root, flush=True)

def save(name, value):
    path = root/name
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2)); temporary.replace(path)

def read(name):
    path = root/name
    return json.loads(path.read_text()) if path.exists() else None

fixture = None
app = None
cancelled = False
def cancel(_signal, _frame):
    global cancelled
    cancelled = True
signal.signal(signal.SIGTERM, cancel)
signal.signal(signal.SIGINT, cancel)
try:
    fixture_binary, inspector = root/'VideoSyncFixture', root/'InspectMedia'
    for source, output in [('VideoSyncFixture.swift', fixture_binary), ('InspectMedia.swift', inspector)]:
        subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', str(project/'tools'/source), '-o', str(output)], check=True)
    digest = hashlib.sha256()
    with (app_bundle/'Contents/MacOS/Scriber').open('rb') as binary:
        for block in iter(lambda: binary.read(1024*1024), b''): digest.update(block)
    save('run.json', {'runnerPID': os.getpid(), 'requestedSeconds': args.seconds, 'realTime': True,
        'binarySHA256': digest.hexdigest(), 'appBundle': str(app_bundle), 'concurrentAudioRoot': str(peer) if peer else None,
        'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=project, text=True).strip(),
        'startedUTC': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())})
    with (root/'fixture.log').open('w') as fixture_log, (root/'app.log').open('w') as app_log:
        fixture = subprocess.Popen([str(fixture_binary), str(root), str(args.seconds)], stdout=fixture_log, stderr=fixture_log)
        deadline = time.monotonic()+20
        while not read('fixture.json'):
            assert not cancelled and fixture.poll() is None and time.monotonic() < deadline, 'Fixture failed to open'
            time.sleep(.1)
        target = read('fixture.json')
        app = subprocess.Popen([str(app_bundle/'Contents/MacOS/Scriber'), '--display-video-check',
            str(root), str(args.seconds), '--audio-sources', 'both', '--capture-window', str(target['windowID'])],
            stdout=app_log, stderr=app_log)
        save('owner.json', {'runnerPID': os.getpid(), 'appPID': app.pid, 'fixturePID': fixture.pid, 'root': str(root)})
        started = None
        next_sample = 0
        trace = []
        deadline = time.monotonic()+30
        with (root/'resources.jsonl').open('w', buffering=1) as resources:
            while True:
                if cancelled: raise RuntimeError('Video acceptance cancelled')
                state = read('state.json')
                now = time.monotonic()
                if state:
                    assert state['pid'] == app.pid
                    if state['status'] == 'recording' and started is None:
                        started = now; deadline = now+args.seconds+120
                        (root/'start-cues').touch()
                    elapsed = now-started if started else 0
                    if state['status'] == 'recording' and elapsed >= next_sample:
                        assert state['powerProtectionActive'], state
                        usage = subprocess.check_output(['ps', '-p', str(app.pid), '-o', 'rss=,%cpu=,time='], text=True).split()
                        item = {'elapsed': elapsed, 'rssKiB': int(usage[0]), 'cpuPercent': float(usage[1]), 'cpuTime': usage[2],
                            'frames': state['frames'], 'videoFrames': state['videoFrames'], 'sourceFrames': state['sourceFrames'],
                            'sourceClockSkew': state['sourceMaximumClockSkewFrames'], 'sourceFailures': state['sourceFailures']}
                        trace.append(item); resources.write(json.dumps(item)+'\n'); save('progress.json', item)
                        next_sample = elapsed+min(30, args.seconds/6)
                result = read('result.json')
                if result: break
                if fixture.poll() is not None:
                    raise RuntimeError(f'Video fixture exited with code {fixture.returncode}; see fixture.log')
                if app.poll() is not None:
                    raise RuntimeError(f'Capture exited with code {app.returncode} without a final report; see app.log')
                if now >= deadline:
                    raise TimeoutError('Capture/start/finalization deadline exceeded')
                time.sleep(.2 if started is None else 1)
        app.wait(timeout=15)
        assert app.returncode == 0 and result['status'] == 'completed' and not result['error'], result
        assert result['audioSaved'] and result['videoSaved'] and not result['powerProtectionActive'], result
        assert result['wallElapsedSeconds'] >= args.seconds and result['frames'] >= int(args.seconds*48000), result
        assert result['videoFrames'] >= args.seconds*10, 'Moving test window did not sustain picture updates'
        fixture.terminate(); fixture.wait(timeout=10)
        native = json.loads(subprocess.check_output([str(inspector), result['path'], result['videoPath']], text=True))
        save('native-decode.json', native)
        for file in native:
            audio = next(t for t in file['streams'] if t['type'] == 'audio')
            assert audio['frames'] == result['frames'], native
        video_track = next(t for t in native[1]['streams'] if t['type'] == 'video')
        assert video_track['framesInMediaSegments'] == result['videoFrames'], native
        assert abs(video_track['trackEnd']-result['durationSeconds']) <= 1/30, native
        counted = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v',
            '-count_frames', '-show_entries', 'stream=nb_read_frames,width,height', '-of', 'json', result['videoPath']], text=True))
        encoded = counted['streams'][0]
        assert int(encoded['nb_read_frames']) == result['videoFrames'], counted
        assert (encoded['width'], encoded['height']) == (target['width'], target['height']), counted
        if geometry := result.get('videoCaptureGeometry'):
            assert (encoded['width'], encoded['height']) == (geometry['pixelWidth'], geometry['pixelHeight']), geometry
        decoded = subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', result['videoPath'],
            '-fps_mode', 'passthrough', '-enc_time_base:v', 'demux', '-f', 'null', '-'], capture_output=True, text=True)
        (root/'ffmpeg-decode.log').write_text(decoded.stderr)
        assert decoded.returncode == 0 and not decoded.stderr.strip(), decoded.stderr
        hashes = [subprocess.check_output(['ffmpeg', '-v', 'error', '-xerror', '-i', path, '-vn', '-c:a', 'pcm_f32le',
            '-ac', '2', '-ar', '48000', '-f', 'hash', '-hash', 'sha256', '-'], text=True).strip()
            for path in (result['path'], result['videoPath'])]
        assert hashes[0] == hashes[1], hashes
        subprocess.run([sys.executable, str(project/'scripts/inspect-video-sync.py'), str(root)], check=True)
        # Save an actual decoded picture for visual QA, away from the flash.
        subprocess.run(['ffmpeg', '-v', 'error', '-ss', '6', '-i', result['videoPath'],
            '-frames:v', '1', str(root/'captured-frame.png')], check=True)
        warmed = [s for s in trace if s['elapsed'] >= min(300, args.seconds/4)]
        width = max(1, min(10, len(warmed)//3))
        metrics = {'peakRSSKiB': max(s['rssKiB'] for s in trace),
            'warmRSSKiB': statistics.median(s['rssKiB'] for s in warmed[:width]),
            'endRSSKiB': statistics.median(s['rssKiB'] for s in warmed[-width:]),
            'meanCPUPercent': statistics.mean(s['cpuPercent'] for s in warmed),
            'finalizationSeconds': result['finalizationSeconds']}
        save('verified.json', {'longDuration': args.seconds >= 7200, 'requestedSeconds': args.seconds,
            'result': result, 'resources': metrics, 'sync': read('sync.json'), 'audioHash': hashes[0],
            'resourceTrendNeedsReview': True})
        print('PASS: real-time video, native/full decode, identical paired audio and beginning/end synchronization', metrics, flush=True)
except BaseException as error:
    save('failure.json', {'error': str(error), 'appPID': app.pid if app else None,
                         'appExitCode': app.poll() if app else None,
                         'fixturePID': fixture.pid if fixture else None,
                         'fixtureExitCode': fixture.poll() if fixture else None})
    raise
finally:
    if app and app.poll() is None: app.terminate(); app.wait(timeout=30)
    if fixture and fixture.poll() is None: fixture.terminate(); fixture.wait(timeout=10)
