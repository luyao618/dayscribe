#!/usr/bin/env python3
"""Measure actual recorded flash/tone offsets at both ends of a fixture capture."""
import array
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import sys

def inspect(root):
    fixture = json.loads((root/'fixture.json').read_text())
    result = json.loads((root/'result.json').read_text())
    video = result['videoPath']
    groups = []
    epoch = result['videoEpochHostTime']
    for expected_cues in (fixture['cueHostTimes'][:3], fixture['cueHostTimes'][3:]):
        start = max(0, expected_cues[0] - epoch - .5)
        x, y, width, height = fixture['marker']
        rendered = subprocess.run(['ffmpeg', '-v', 'info', '-ss', str(start), '-i', video,
            '-an', '-vf', f'crop={width}:{height}:{x}:{y},scale=1:1,format=gray,trim=duration=4,showinfo',
            '-fps_mode', 'passthrough', '-f', 'rawvideo', '-'], capture_output=True, check=True)
        times = [start + float(x) for x in re.findall(r'\bn:\s*\d+.*?\bpts_time:\s*([\d.e+-]+)', rendered.stderr.decode())]
        assert len(times) == len(rendered.stdout), (len(times), len(rendered.stdout))
        flashes = [times[i] for i, value in enumerate(rendered.stdout)
                   if value > 180 and (i == 0 or rendered.stdout[i-1] <= 180)]
        raw = subprocess.check_output(['ffmpeg', '-v', 'error', '-ss', str(start), '-i', video,
            '-t', '4', '-vn', '-ac', '1', '-ar', '48000', '-f', 'f32le', '-'])
        samples = array.array('f'); samples.frombytes(raw)
        # Five-millisecond tone windows bound onset resolution without storing
        # the full recording or introducing a bandpass filter's group delay.
        size = 240
        cosine = [math.cos(i*880*2*math.pi/48000) for i in range(size)]
        sine = [math.sin(i*880*2*math.pi/48000) for i in range(size)]
        tones = []
        active = False
        for offset in range(0, len(samples)-size+1, size):
            real = sum(samples[offset+i]*cosine[i] for i in range(size))
            imaginary = sum(samples[offset+i]*sine[i] for i in range(size))
            present = 2*math.hypot(real, imaginary)/size > .007
            if present and not active: tones.append(start+offset/48000)
            active = present
        assert len(flashes) == len(tones) == 3, {'flashes': flashes, 'tones': tones, 'start': start}
        offsets = [audio-picture for audio, picture in zip(tones, flashes)]
        expected = [cue-epoch for cue in expected_cues]
        assert all(abs(picture-cue) <= .1 for picture, cue in zip(flashes, expected)), (flashes, expected)
        assert all(abs(value) <= .1 for value in offsets), offsets
        groups.append({'flashes': flashes, 'tones': tones, 'audioMinusVideoSeconds': offsets,
                       'medianOffsetSeconds': statistics.median(offsets)})
    drift = groups[1]['medianOffsetSeconds'] - groups[0]['medianOffsetSeconds']
    assert abs(drift) <= .05, ('Beginning/end synchronization drift', drift)
    report = {'groups': groups, 'driftSeconds': drift, 'audioOnsetResolutionSeconds': .005,
              'maximumAbsoluteOffsetSeconds': .1, 'maximumDriftSeconds': .05,
              'fixtureOutputPresentationLatency': fixture['outputPresentationLatency']}
    (root/'sync.json').write_text(json.dumps(report, indent=2))
    return report

if __name__ == '__main__':
    print(json.dumps(inspect(Path(sys.argv[1]).resolve()), indent=2))
