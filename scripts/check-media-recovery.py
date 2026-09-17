#!/usr/bin/env python3
"""Restore an existing owned crash sample and truncated COPIES, preserving sources.

Pass a media path from a prior capture-crash test. No application startup or
history publication is exercised by this lower-level recovery validation.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
args = parser.parse_args()
source = args.source.absolute()
project = Path(__file__).resolve().parent.parent
(project / 'artifacts').mkdir(exist_ok=True)
root = Path(tempfile.mkdtemp(prefix='media-recovery-', dir=project / 'artifacts'))
print('Evidence directory:', root, flush=True)

def digest(path):
    with path.open('rb') as file: return hashlib.file_digest(file, 'sha256').hexdigest()

def decode(path):
    subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', str(path), '-fps_mode', 'passthrough',
                    '-enc_time_base:v', 'demux', '-f', 'null', '-'], check=True)
    return subprocess.check_output(['ffmpeg', '-v', 'error', '-xerror', '-i', str(path), '-vn',
                                   '-ac', '1', '-ar', '48000', '-f', 'f32le', '-'])

def recover(path, name, success=True):
    before = digest(path)
    result = subprocess.run([str(project / 'artifacts/RecoverMedia'), str(path), str(root / name)], capture_output=True, text=True)
    (root / (name + '.log')).write_text(result.stdout + result.stderr)
    assert digest(path) == before, 'Original bytes changed'
    if not success:
        assert result.returncode != 0 and not (root / name / ('recovered' + path.suffix)).exists()
        return None
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    data = decode(report['path'])
    assert len(data) > 48000 * 4, report
    report['ffmpegFrames'] = len(data) // 4
    return report, data

lease = os.open(source.parent / 'capture.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
try:
    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
    blocked = subprocess.run([str(project / 'artifacts/RecoverMedia'), str(source), str(root / 'blocked')], capture_output=True, text=True)
    assert blocked.returncode != 0 and '使用中' in blocked.stderr and not (root / 'blocked').exists(), blocked
finally:
    os.close(lease)

original_hash = digest(source)
original, reference = recover(source, 'original')
assert reference == decode(source), 'Recovery changed the indexed audio samples'
if source.suffix == '.mp4':
    def picture_hash(path):
        return subprocess.check_output(['ffmpeg', '-v', 'error', '-xerror', '-i', str(path), '-an',
                                        '-fps_mode', 'passthrough', '-pix_fmt', 'rgb24', '-f', 'md5', '-'])
    assert picture_hash(source) == picture_hash(original['path']), 'Recovery changed the decoded pictures'
boxes = []
with source.open('rb') as file:
    total = source.stat().st_size; offset = 0
    while offset + 8 <= total:
        file.seek(offset); size, kind = struct.unpack('>I4s', file.read(8)); header = 8
        if size == 1:
            if offset + 16 > total: break
            size = struct.unpack('>Q', file.read(8))[0]; header = 16
        if size == 0: size = total - offset
        if size < header or offset + size > total: break
        boxes.append((offset, size, kind, header)); offset += size
movie = next(box for box in boxes if box[2] == b'moov')
fragment = next(box for box in reversed(boxes) if box[2] == b'moof')
media = next(box for box in reversed(boxes) if box[2] == b'mdat' and box[0] < fragment[0])
cuts = {'torn-index': fragment[0] + fragment[3] + (fragment[1] - fragment[3]) // 2,
        'torn-media': media[0] + media[3] + (media[1] - media[3]) // 2, 'no-index': movie[0]}
results = {'original': original}
for name, end in cuts.items():
    folder = root / (name + '-source'); folder.mkdir()
    path = folder / source.name
    shutil.copyfile(source, path)
    with path.open('r+b') as file: file.truncate(end)
    restored = recover(path, name, success=name != 'no-index')
    if restored:
        report, data = restored
        assert len(data) < len(reference) and data == reference[:len(data)], report
        results[name] = report
assert digest(source) == original_hash
(root / 'verified.json').write_text(json.dumps(results, indent=2))
print('PASS: active-session refusal, native recovery, torn-index/media fallback, no-index refusal and unchanged originals', flush=True)
