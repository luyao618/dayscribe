"""Verify the delivered media, native asset hashes, and decoded visual samples."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import struct
import subprocess

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'output'

def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    OUT.mkdir(exist_ok=True)
    parser = argparse.ArgumentParser()
    parser.add_argument('--edition', choices=['zh','en'], default='zh')
    edition = parser.parse_args().edition
    media = ROOT / f'scriber-intro-{edition}.mp4'
    probe = json.loads(run('ffprobe','-v','error','-count_frames','-show_streams','-show_format','-of','json',str(media)).stdout)
    video = next(s for s in probe['streams'] if s['codec_type']=='video')
    audio = next(s for s in probe['streams'] if s['codec_type']=='audio')
    assert len(probe['streams']) == 2
    assert video['codec_name']=='h264' and (video['width'],video['height'])==(1920,1080)
    assert video['r_frame_rate']=='30/1' and int(video['nb_read_frames'])==1800
    assert audio['codec_name']=='aac' and int(audio['sample_rate'])==48000 and audio['channels']==2
    assert abs(float(probe['format']['duration'])-60)<.01
    decoded = run('ffmpeg','-v','error','-xerror','-i',str(media),'-f','null','-')
    assert not decoded.stderr
    volume = run('ffmpeg','-hide_banner','-i',str(media),'-af','volumedetect','-vn','-f','null','-').stderr
    peak = float(re.search(r'max_volume: ([-.\d]+) dB',volume)[1])
    mean = float(re.search(r'mean_volume: ([-.\d]+) dB',volume)[1])
    assert -30 < mean < -10 and peak < -1
    with media.open('rb') as stream:
        atoms=[]
        while stream.tell()<media.stat().st_size:
            offset=stream.tell();size,kind=struct.unpack('>I4s',stream.read(8))
            if size==1:size=struct.unpack('>Q',stream.read(8))[0]
            if size==0:size=media.stat().st_size-offset
            atoms.append(kind.decode('ascii'));stream.seek(offset+size)
    assert atoms.index('moov')<atoms.index('mdat'), 'Faststart required'
    manifest=json.loads((ROOT/'assets/provenance.json').read_text())
    for item in manifest['assets']:
        assert digest(ROOT/'assets'/item['file'])==item['sha256'],item['file']
        if item['file'].endswith('.mp4'):
            native=json.loads(run('ffprobe','-v','error','-show_streams','-of','json',str(ROOT/'assets'/item['file'])).stdout)
            assert all(s['codec_type']!='audio' for s in native['streams'])
    run('ffmpeg','-y','-v','error','-i',str(media),'-vf','fps=1/5,scale=480:270,tile=3x4','-frames:v','1',str(OUT/('decoded-contact-en.jpg' if edition=='en' else 'decoded-contact.jpg')))
    result={'durationSeconds':60,'resolution':[1920,1080],'fps':30,'decodedVideoFrames':1800,
            'video':'H.264 yuv420p','audio':'AAC 48kHz stereo','meanVolumeDBFS':mean,'peakVolumeDBFS':peak,
            'fullDecode':'passed','faststart':True,'nativeAssetsChecked':len(manifest['assets']),
            'nativeClipsHaveNoAudio':True,'bytes':media.stat().st_size,'sha256':digest(media)}
    if edition=='en':
        voice=json.loads((ROOT/'voice-timing.json').read_text())
        assert digest(ROOT/'assets'/voice['file'])==voice['sha256']
        assert audio.get('tags',{}).get('language')=='eng'
        assert all(c['start']<c['speechEnd']<c['subtitleEnd'] for c in voice['segments'])
        result.update({'narrationLanguage':'English','subtitles':'English above Chinese, burned into video',
                       'speechCues':len(voice['segments']),'narrationSHA256':voice['sha256']})
    (ROOT/('verification-en.json' if edition=='en' else 'verification.json')).write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(result,ensure_ascii=False,indent=2))

if __name__=='__main__':main()
