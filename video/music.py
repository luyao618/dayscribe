"""Original, deterministic 60-second instrumental. No samples or external audio."""
from pathlib import Path
import wave
import numpy as np

RATE = 48000
DURATION = 60

def make(path):
    audio = np.zeros((RATE * DURATION, 2), dtype=np.float64)
    beat = 60 / 96
    chords = [(50, 57, 61, 64, 69), (43, 54, 59, 62, 66),
              (47, 57, 62, 66, 69), (45, 57, 59, 64, 69)]
    def put(start, note, duration, gain, pan=0.0, pad=False):
        t = np.arange(int(duration * RATE)) / RATE
        hz = 440 * 2 ** ((note - 69) / 12)
        if pad:
            env = np.minimum(t / .6, 1) * np.minimum((duration - t) / .8, 1)
            sound = (np.sin(2*np.pi*hz*t)+.3*np.sin(2*np.pi*hz*1.0015*t))/1.3*env
        else:
            env = (1-np.exp(-t/.007)) * np.exp(-t/1.05) * np.minimum((duration-t)/.08, 1)
            sound = (np.sin(2*np.pi*hz*t)+.24*np.sin(2*np.pi*hz*2*t)*np.exp(-t*3)+.06*np.sin(2*np.pi*hz*3*t))*env
        start = int(start*RATE)
        n = min(len(t),len(audio)-start)
        if n <= 0:return
        stereo = np.array([np.cos((pan+1)*np.pi/4),np.sin((pan+1)*np.pi/4)])
        audio[start:start+n] += sound[:n,None]*gain*stereo
    for bar in range(24):
        start = bar*4*beat
        chord = chords[bar%4]
        for note in chord[1:4]: put(start,note,3.0,.017,pad=True)
        put(start,chord[0],2.4,.06)
        for i,idx in enumerate([1,3,2,4]):
            put(start+(i+.5)*beat,chord[idx]+12,2.5,.078,(-.3,.3,-.15,.15)[i])
        if bar >= 4:
            for step in (0,2):
                t=np.arange(int(.16*RATE))/RATE
                kick=np.sin(2*np.pi*(51*t+2.3*(1-np.exp(-t*25))))*np.exp(-t*29)*.025
                at=int((start+step*beat)*RATE);n=min(len(kick),len(audio)-at)
                if n>0:audio[at:at+n]+=kick[:n,None]
    # Short stereo echoes soften the plucks without obscuring the UI's pace.
    delay=int(.375*RATE)
    dry=audio.copy()
    audio[delay:] += dry[:-delay,::-1]*.16
    fade=np.minimum(np.arange(len(audio))/RATE/2,1)*np.minimum((len(audio)-1-np.arange(len(audio)))/RATE/2.5,1)
    audio *= fade[:,None]
    peak=float(np.abs(audio).max())
    audio *= .32/max(peak,1e-9)
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    with wave.open(str(path),'wb') as w:
        w.setnchannels(2);w.setsampwidth(2);w.setframerate(RATE)
        w.writeframes(np.rint(audio*32767).astype('<i2').tobytes())
    print(f'Original soundtrack: {DURATION}s, stereo {RATE}Hz, peak {20*np.log10(.32):.1f}dBFS')

if __name__=='__main__':
    make(Path(__file__).parent/'output'/'music.wav')
