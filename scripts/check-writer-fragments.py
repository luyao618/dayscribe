#!/usr/bin/env python3
"""Validate production encoders with paced generated media, including SIGKILL.

This is a codec/file fixture, not screen/microphone capture or a long soak test.
Build CrashWriterFixture and InspectMedia as documented in docs/VALIDATION.md.
"""
import argparse
import hashlib
import json
from pathlib import Path
import signal
import struct
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--finish', action='store_true', help='Finish a 14.257-second control normally')
parser.add_argument('--sparse-video', action='store_true', help='One captured picture, then SCK idle callbacks')
args = parser.parse_args()
project = Path(__file__).resolve().parent.parent
(project / 'artifacts').mkdir(exist_ok=True)
root = Path(tempfile.mkdtemp(prefix='writer-fragments-', dir=project / 'artifacts'))
seconds = 14.257 if args.finish else 30
command = [str(project / 'artifacts/CrashWriterFixture'), str(root), str(seconds)]
if args.sparse_video: command.append('--sparse-video')
print('Evidence directory:', root, flush=True)
with (root / 'writer.log').open('wb') as log:
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + seconds + 15
        while process.poll() is None and time.monotonic() < deadline:
            if not args.finish and (root / 'progress.json').exists():
                if json.loads((root / 'progress.json').read_text())['mediaSeconds'] >= 13:
                    process.kill()
                    break
            time.sleep(.05)
    finally:
        if process.poll() is None: process.kill()
        exit_code = process.wait()
report = {'writerExit': exit_code, 'normalFinish': args.finish, 'sparseVideo': args.sparse_video, 'files': {}}
decoded = []
for name in ['audio.m4a', 'video.mp4']:
    path = root / name
    boxes = []
    if path.exists():
        total = path.stat().st_size
        with path.open('rb') as file:
            offset = 0
            while offset + 8 <= total:
                file.seek(offset)
                size, kind = struct.unpack('>I4s', file.read(8))
                original_size, header = size, 8
                if size == 1:
                    if offset + 16 > total: break
                    size = struct.unpack('>Q', file.read(8))[0]; header = 16
                if size == 0: size = total - offset
                boxes.append({'offset': offset, 'size': size, 'openEnded': original_size == 0,
                              'type': kind.decode('ascii', errors='replace'), 'complete': offset + size <= total})
                if size < header or offset + size > total: break
                offset += size
    check = subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', str(path), '-fps_mode', 'passthrough',
                            '-enc_time_base:v', 'demux', '-f', 'null', '-'], capture_output=True, text=True)
    pcm = subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', str(path), '-vn', '-ac', '1', '-ar', '48000',
                          '-f', 'f32le', '-'], capture_output=True)
    decoded.append(pcm.stdout)
    report['files'][name] = {'boxes': boxes, 'decodeExit': check.returncode, 'decodeError': check.stderr,
                            'pcmExit': pcm.returncode, 'frames': len(pcm.stdout) // 4,
                            'pcmSHA256': hashlib.sha256(pcm.stdout).hexdigest()}
native = subprocess.run([str(project / 'artifacts/InspectMedia'), str(root / 'audio.m4a'), str(root / 'video.mp4')],
                        capture_output=True, text=True)
report['nativeExit'] = native.returncode
report['nativeError'] = native.stderr
report['native'] = json.loads(native.stdout) if native.returncode == 0 else None
comparison = subprocess.run([str(project / 'artifacts/InspectMedia'), '--compare-audio',
                            str(root / 'audio.m4a'), str(root / 'video.mp4')], capture_output=True, text=True)
report['nativeComparison'] = json.loads(comparison.stdout) if comparison.returncode == 0 else None
report['nativeComparisonExit'] = comparison.returncode
report['nativeComparisonError'] = comparison.stderr
(root / 'inspection.json').write_text(json.dumps(report, indent=2))
assert exit_code == (0 if args.finish else -signal.SIGKILL), (root, exit_code)
assert all(item['decodeExit'] == 0 and item['pcmExit'] == 0 for item in report['files'].values()), report
assert decoded[0] == decoded[1] and decoded[0], report
frames = len(decoded[0]) // 4
if args.finish: assert frames == int(seconds * 48000), report
else:
    assert frames / 48000 >= 11.8, report
    assert all(any(box['type'] == 'moof' for box in item['boxes']) for item in report['files'].values()), report
assert native.returncode == 0, report
audio = [next(stream for stream in file['streams'] if stream['type'] == 'audio') for file in report['native']]
metadata = [{k: v for k, v in item.items() if k != 'pcmSHA256'} for item in audio]
assert metadata[0] == metadata[1], report
# Apple's two reader paths can differ by Float32 rounding (~1.2e-7 observed).
# Keep exact FFmpeg PCM equality above; bound native numeric differences too.
assert comparison.returncode == 0 and report['nativeComparison']['maxError'] < 1e-6, report
assert len(report['native'][0]['streams']) == 1, 'The M4A must contain only an audio track'
print('PASS:', 'normal finish' if args.finish else 'SIGKILL prefix', 'sparse' if args.sparse_video else 'moving',
      frames, 'decoded audio frames, matching native/FFmpeg pairs', flush=True)
