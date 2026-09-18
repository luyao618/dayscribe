"""Generate the timed English voice and paired English/Chinese subtitles locally.

Uses the standard Kokoro af_heart voice, not a clone of any person. Model files
are downloaded only with --download-models and must match voice-sources.json.
"""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

import numpy as np
import soundfile as sf
from kokoro_onnx import Kokoro

ROOT = Path(__file__).resolve().parent
CACHE = ROOT / 'output' / 'voice-models'
CUES = json.loads((ROOT / 'narration-en.json').read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stamp(seconds, decimal=','):
    ms = round(seconds * 1000)
    return f'{ms//3600000:02d}:{ms//60000%60:02d}:{ms//1000%60:02d}{decimal}{ms%1000:03d}'


def subtitles():
    for language in ['en', 'zh', 'bilingual']:
        parts = []
        for index, cue in enumerate(CUES, 1):
            value = cue['en']+'\n'+cue['zh'] if language=='bilingual' else cue[language]
            parts.append(f"{index}\n{stamp(cue['start'])} --> {stamp(cue['end'])}\n{value}")
        result = '\n\n'.join(parts)+'\n'
        (ROOT / f'scriber-en-{language}.srt').write_text(result)
        vtt = result
        for cue in CUES:
            for key in ['start', 'end']:
                vtt = vtt.replace(stamp(cue[key]), stamp(cue[key], '.'))
        (ROOT / f'scriber-en-{language}.vtt').write_text('WEBVTT\n\n'+vtt)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--download-models', action='store_true')
    args = parser.parse_args()
    CACHE.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((ROOT / 'voice-sources.json').read_text())
    for item in manifest['files']:
        path = CACHE / item['file']
        if not path.exists():
            if not args.download_models:
                raise SystemExit('Model missing; rerun with --download-models to fetch the pinned public model.')
            temporary = path.with_suffix(path.suffix+'.part')
            with urllib.request.urlopen(item['url'], timeout=60) as response, temporary.open('wb') as output:
                while block := response.read(1024*1024): output.write(block)
            if sha(temporary)!=item['sha256']: raise RuntimeError('Downloaded model hash mismatch')
            temporary.replace(path)
        assert path.stat().st_size==item['bytes'] and sha(path)==item['sha256'], path
    engine = Kokoro(str(CACHE/'kokoro-v1.0.int8.onnx'), str(CACHE/'voices-v1.0.bin'))
    rate = 24000
    master = np.zeros(60*rate, dtype=np.float32)
    segments = []
    prior_end = 0
    for cue in CUES:
        assert prior_end <= cue['start'] < cue['end'] <= 60
        prior_end = cue['end']
        available = cue['end']-cue['start']-.08
        speed = .95
        for attempt in range(3):
            audio, actual_rate = engine.create(cue['spoken'], voice='af_heart', speed=speed, lang='en-us')
            assert actual_rate==rate and np.isfinite(audio).all() and len(audio)>0
            if len(audio)/rate <= available: break
            speed *= len(audio)/rate/available*1.025
            if speed>1.22: raise RuntimeError(f"Shorten narration cue {cue['id']} instead of rushing speech")
        duration = len(audio)/rate
        assert duration <= available, (cue['id'],duration,available)
        start = round(cue['start']*rate)
        master[start:start+len(audio)] = audio
        segments.append({'id':cue['id'],'start':cue['start'],'speechEnd':cue['start']+duration,
                         'subtitleEnd':cue['end'],'speechSeconds':duration,'speed':speed,'text':cue['spoken']})
        print(f"Cue {cue['id']}: {duration:.3f}s / {available:.3f}s, speed {speed:.3f}", flush=True)
    peak = float(np.max(np.abs(master)))
    assert peak > .01
    master *= .78/peak
    target = ROOT / 'assets' / 'narration-en.flac'
    sf.write(target, master, rate, subtype='PCM_16')
    info = {'engine':'kokoro-onnx 0.6.1','voice':'af_heart','locale':'en-us',
            'disclosure':'AI-generated narration using a standard pretrained voice; no voice cloning.',
            'modelLicense':'Apache-2.0','sampleRate':rate,'channels':1,'durationSeconds':60,
            'file':target.name,'sha256':sha(target),'segments':segments}
    (ROOT/'voice-timing.json').write_text(json.dumps(info,ensure_ascii=False,indent=2)+'\n')
    subtitles()
    print(target)

if __name__=='__main__': main()
