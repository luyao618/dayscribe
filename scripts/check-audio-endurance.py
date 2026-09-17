#!/usr/bin/env python3
"""Real-time dual-source audio acceptance with bounded resource/decode evidence.

The default runs for eight actual hours. --seconds 30 is a harness smoke test,
not long-duration acceptance. Outputs stay in an isolated ignored directory.
"""
import argparse
import array
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import statistics
import subprocess
import tempfile
import time
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seconds', type=float, default=8 * 3600)
args = parser.parse_args()
if not math.isfinite(args.seconds) or args.seconds < 20:
    parser.error('--seconds must be finite and at least 20')
project = Path(__file__).resolve().parent.parent
if subprocess.run(['pgrep', '-x', 'Scriber'], capture_output=True).returncode == 0:
    parser.error('Quit existing Scriber before starting this independent acceptance run')
root = Path(tempfile.mkdtemp(prefix='audio-endurance-', dir=project / 'artifacts'))
print('Evidence directory:', root, flush=True)

def save(name, value):
    destination = root / name
    temporary = destination.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2))
    temporary.replace(destination)

def read(name):
    path = root / name
    return json.loads(path.read_text()) if path.exists() else None

stimulus = root / 'stimulus.wav'
pcm = array.array('h')
for i in range(4 * 48000):
    frequency = 880 if i < 2 * 48000 else 1760
    fade = min(1, (i % 96000) / 480, (96000 - i % 96000) / 480)
    pcm.append(int(1000 * fade * math.sin(i * frequency * 2 * math.pi / 48000)))
with wave.open(str(stimulus), 'wb') as output:
    output.setnchannels(1); output.setsampwidth(2); output.setframerate(48000)
    output.writeframes(pcm.tobytes())
del pcm

def tone_amplitudes(path, start):
    raw = subprocess.check_output(['ffmpeg', '-v', 'error', '-ss', str(start), '-i', str(path),
        '-t', '7', '-vn', '-ac', '1', '-ar', '48000', '-f', 'f32le', '-'])
    values = array.array('f'); values.frombytes(raw)
    peaks = {}
    # A one-second window avoids diluting the two separate stimulus tones.
    for frequency in (880, 1760):
        powers = []
        for offset in range(0, len(values) - 48000 + 1, 24000):
            real = sum(values[offset+i] * math.cos(i*frequency*2*math.pi/48000) for i in range(48000))
            imaginary = sum(values[offset+i] * math.sin(i*frequency*2*math.pi/48000) for i in range(48000))
            powers.append(2*math.hypot(real, imaginary)/48000)
        peaks[str(frequency)] = max(powers, default=0)
    assert min(peaks.values()) > .005, ('Missing beginning/end stimulus', start, peaks)
    return peaks

app = None
players = []
cancelled = False
def cancel(_signal, _frame):
    global cancelled
    cancelled = True
signal.signal(signal.SIGTERM, cancel)
signal.signal(signal.SIGINT, cancel)
try:
    helper = root / 'InspectMedia'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(project/'tools/InspectMedia.swift'),
        '-o', str(helper)], check=True)
    save('run.json', {'requestedSeconds': args.seconds, 'startedUTC': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=project, text=True).strip(),
        'runnerPID': os.getpid(), 'realTime': True, 'hardware': 'system defaults; see source state in trace'})
    with (project/'build/Scriber.app/Contents/MacOS/Scriber').open('rb') as executable:
        digest = hashlib.sha256()
        for block in iter(lambda: executable.read(1024*1024), b''): digest.update(block)
    save('app-identity.json', {'binarySHA256': digest.hexdigest()})
    with (root/'app.log').open('w') as log:
        app = subprocess.Popen([str(project/'build/Scriber.app/Contents/MacOS/Scriber'),
            '--mixed-audio-check', str(root), str(args.seconds), '--audio-sources', 'both'],
            stdout=log, stderr=log)
        save('owner.json', {'runnerPID': os.getpid(), 'appPID': app.pid, 'root': str(root)})
        deadline = time.monotonic() + 30
        started = None
        trace = []
        next_sample = 0
        ending_played = False
        finishing_observed = None
        last_frames = -1
        with (root/'resources.jsonl').open('w', buffering=1) as resource_log:
            while True:
                if cancelled: raise RuntimeError('Acceptance cancelled; capture is finalized in cleanup')
                now = time.monotonic()
                state = read('state.json')
                if state:
                    assert state['pid'] == app.pid, 'Unexpected capture process'
                    if state['status'] == 'recording' and started is None:
                        started = now
                        deadline = started + args.seconds + 120
                        players.append(subprocess.Popen(['afplay', str(stimulus)]))
                    elapsed = now - started if started else 0
                    if state['status'] == 'finishing' and finishing_observed is None:
                        finishing_observed = now
                    if started and elapsed >= args.seconds - 6 and not ending_played:
                        players.append(subprocess.Popen(['afplay', str(stimulus)]))
                        ending_played = True
                    if state['status'] == 'recording' and elapsed >= next_sample:
                        assert state['powerProtectionActive'], 'Recording lost native power protection'
                        assert state['frames'] >= last_frames, 'PCM timeline moved backward'
                        last_frames = state['frames']
                        usage = subprocess.check_output(['ps', '-p', str(app.pid), '-o', 'rss=,%cpu=,time='], text=True).split()
                        entry = {'elapsed': elapsed, 'rssKiB': int(usage[0]), 'cpuPercent': float(usage[1]),
                            'cpuTime': usage[2], 'frames': state['frames'], 'sourceFrames': state['sourceFrames'],
                            'sourceClockSkew': state['sourceMaximumClockSkewFrames'], 'sourceRates': state['sourceRates'],
                            'sourceFailures': state['sourceFailures'], 'reconnectCounts': state['reconnectCounts']}
                        trace.append(entry); resource_log.write(json.dumps(entry)+'\n')
                        save('progress.json', {**entry, 'requestedSeconds': args.seconds, 'appPID': app.pid})
                        next_sample = elapsed + min(30, args.seconds/6)
                result = read('result.json')
                if result: break
                assert app.poll() is None, ('App exited without a result', app.returncode)
                assert now < deadline, 'Capture/start/finalization deadline exceeded'
                time.sleep(.2 if started is None else 1)
        observed_end = time.monotonic()
        app.wait(timeout=15)
        assert app.returncode == 0 and result['status'] == 'completed' and result['audioSaved'], result
        assert ending_played and result['wallElapsedSeconds'] >= args.seconds, result
        assert result['frames'] >= int(args.seconds * 48000), result
        assert not result['error'] and not result['powerProtectionActive'], result
        assert isinstance(result['finalizationSeconds'], (int, float)) and result['finalizationSeconds'] >= 0, result
        for source in ('system', 'microphone'):
            assert result['sourceFrames'].get(source, 0) > (args.seconds - 2)*48000, result
        media = Path(result['path'])
        native = json.loads(subprocess.check_output([str(helper), str(media)], text=True))
        save('native-decode.json', native)
        streams = native[0]['streams']
        assert len(streams) == 1 and streams[0]['type'] == 'audio' and streams[0]['frames'] == result['frames'], native
        subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', str(media), '-f', 'null', '-'], check=True)
        stimuli = {'beginning': tone_amplitudes(media, 0), 'ending': tone_amplitudes(media, args.seconds-7)}
        warmed = [x for x in trace if x['elapsed'] >= min(300, args.seconds/4)]
        assert warmed, 'No resource samples collected'
        width = max(1, min(10, len(warmed)//3))
        metrics = {'peakRSSKiB': max(x['rssKiB'] for x in trace),
            'warmRSSKiB': statistics.median(x['rssKiB'] for x in warmed[:width]),
            'endRSSKiB': statistics.median(x['rssKiB'] for x in warmed[-width:]),
            'meanCPUPercent': statistics.mean(x['cpuPercent'] for x in warmed),
            'observedWallSeconds': observed_end-started, 'reportedWallSeconds': result['wallElapsedSeconds'],
            'observedFinalizationSeconds': observed_end-finishing_observed if finishing_observed else None,
            'finalizationSeconds': result['finalizationSeconds'],
            'samplingSeconds': min(30, args.seconds/6), 'mediaBytes': media.stat().st_size}
        save('verified.json', {'requestedSeconds': args.seconds, 'longDuration': args.seconds >= 8*3600,
            'result': result, 'resources': metrics, 'stimuli': stimuli,
            'resourceTrendNeedsReview': True, 'finalizationObservationResolutionSeconds': 1})
        print('PASS: real-time capture, native/full FFmpeg decode, beginning/end stimuli; resource trend requires review:', metrics, flush=True)
except BaseException as error:
    save('failure.json', {'error': str(error), 'appPID': app.pid if app else None})
    raise
finally:
    if app and app.poll() is None:
        app.terminate()
        app.wait(timeout=30)
    for player in players:
        if player.poll() is None: player.terminate()
        player.wait()
