"""English presentation and narration, with English/Chinese burned-in subtitles.

Reuses the original native footage; it does not translate or fake the app UI.
The original Chinese film and renderer remain available.
"""
import argparse
import json
import math
from pathlib import Path
import subprocess

from PIL import Image, ImageDraw
import render as v

ROOT, OUT = v.ROOT, v.OUT
CUES = json.loads((ROOT/'narration-en.json').read_text())
AUDIO = v.Clip('audio-demo.mp4',435)
REGION = v.Clip('region-demo.mp4',1040)
VIDEO = v.Clip('video-demo.mp4',415)
SCENES = [(0,6,'Keep the moment'),(6,12,'Open Scriber'),(12,22,'Record audio'),
          (22,29,'Stay in control'),(29,40,'Record your screen'),(40,48,'Get your files'),
          (48,55,'Find it later'),(55,60,'Put it to work')]


def header(im,t,step):
    v.mark(im,96,49,40,t)
    v.text(im,'Scriber',(144,47),36,weight='bold',family='brand')
    v.text(im,'macOS  /  Audio & screen recording',(1824,58),22,v.SLATE,anchor='rt')
    d=ImageDraw.Draw(im)
    d.line((96,1019,1824,1019),fill=v.LINE,width=2)
    d.line((96,1019,96+1728*t/60,1019),fill=v.IRIS,width=3)
    v.text(im,step,(96,1040),18,v.SLATE)
    v.text(im,f'{int(t):02d} / 60',(1824,1040),17,v.SLATE,family='mono',anchor='rt')


def subtitle(im,t):
    cue=next((c for c in CUES if c['start']<=t<c['end']),None)
    if cue is None:return
    # Two stable rows, clear of the native panel and playback labels.
    d=ImageDraw.Draw(im)
    for language,size,y,color in [('en',32,923,v.INK),('zh',29,968,v.SLATE)]:
        assert d.textlength(cue[language],font=v.font(size))<=1728, cue['id']
        v.text(im,cue[language],(960,y),size,color,anchor='mt')


def copy(im,title,body,tag,y=243,entry=1):
    v.copy(im,title,body,tag,y=y,enter=entry)


def native(im,source,entry=1):
    return v.panel(im,source,xy=(1235,126),width=435,entry=entry)


def frame(t):
    im=v.BASE.copy()
    start,end,step=next(s for s in SCENES if s[0]<=t<s[1])
    q=t-start;entry=v.ease(q/.8)
    header(im,t,step)
    if start==0:
        copy(im,'Worth keeping?\nJust hit record.','Meetings, calls, videos.\nKeep a local copy of what matters.','A RECORDER FOR YOUR MAC',entry=entry)
        native(im,'audio-ready.png',entry)
        v.ribbon(im,t,width=830,y=725)
    elif start==6:
        copy(im,'One shortcut.\nReady to record.','Open Scriber from the menu bar.\nOr press Option + R.','OPEN THE PANEL',entry=entry)
        native(im,'audio-ready.png',entry)
        d=ImageDraw.Draw(im)
        for x,label,w in [(112,'⌥',92),(220,'R',92)]:
            d.rounded_rectangle((x,607,x+w,699),radius=18,fill='white',outline=v.LINE,width=2)
            v.text(im,label,(x+w/2,621),47,v.INK,'medium','brand',anchor='mt')
        v.text(im,'Your shortcut. Customizable.',(340,637),26,v.SLATE)
        v.text(im,'First time? Allow recording permissions in macOS.',(112,763),25,v.SLATE)
    elif start==12:
        copy(im,'Your audio.\nYour controls.','System audio and microphone.\nSwitch either source on or off.','RECORD AUDIO',entry=entry)
        native(im,AUDIO.frame(q))
        w=v.pill(im,'System audio',112,647,v.IRIS)
        v.pill(im,'Microphone',112+w+20,647,v.JADE)
        v.text(im,'Hide the panel. Keep recording.',(112,765),27,v.SLATE)
    elif start==22:
        copy(im,'Always know\nwhat is recording.','Watch the timer and audio levels.\nRename your file while you record.','STAY IN CONTROL',entry=entry)
        native(im,AUDIO.frame(10+q))
        v.ribbon(im,t,y=730,width=815,height=50)
    elif start==29:
        if q<3.8:
            copy(im,'Keep the picture,\ntoo.','Choose screen recording.\nThen pick what you want to capture.','RECORD YOUR SCREEN',entry=entry)
            v.panel(im,'range-options.png',width=415,xy=(1245,126))
            x=112
            for label in ['Region','Window','Full screen']:x+=v.pill(im,label,x,647)+14
        elif q<8.2:
            v.text(im,'Frame\nwhat matters.',(110,181),70,v.INK,'bold')
            v.text(im,'Drag to select.\nPress Return to start.',(116,383),31,v.SLATE)
            pic=REGION.frame(min(4.8,q-3.8+.3))
            v.panel(im,pic,xy=(760,240))
            v.pill(im,'Selected region',112,540)
        else:
            copy(im,'Picture and sound.\nTogether.','Finished? Click Stop and Save.','SCREEN RECORDING',entry=entry)
            v.panel(im,VIDEO.frame(q-8.2),xy=(1245,126))
    elif start==40:
        v.text(im,'One recording. Two useful files.',(960,164),68,v.INK,'bold',anchor='mt')
        v.text(im,'Watch the video. Use the audio on its own.',(960,263),32,v.SLATE,anchor='mt')
        v.document(im,540,362,'MP4',v.IRIS,q,'Demo.mp4','Video with sound')
        v.document(im,1080,362,'M4A',v.JADE,q+.5,'Demo.m4a','Separate audio')
        v.text(im,'+',(960,471),72,v.SLATE,'regular','brand',anchor='mt')
        v.text(im,'Audio-only recording saves one mixed M4A file.',(960,826),27,v.SLATE,anchor='mt')
    elif start==48:
        if q<3.3:
            copy(im,'Your files.\nYour folders.','Choose separate folders for audio\nand screen recordings. Save automatically.','SAVE LOCALLY',entry=entry)
            v.panel(im,'destinations.png',width=530,xy=(1168,244))
        else:
            copy(im,'Ready when\nyou need it.','Play, rename, or reveal in Finder.\nEverything is there in your history.','FIND IT LATER',entry=entry)
            v.panel(im,'playback.png',width=470,xy=(1208,161))
        v.text(im,'Local files. Ready for your next tool.',(112,757),27,v.SLATE)
    else:
        v.mark(im,692,206,88,q)
        v.text(im,'Scriber',(965,209),103,v.INK,'bold','brand',anchor='mt')
        v.text(im,'Record it. Put it to work.',(960,406),78,v.INK,'bold',anchor='mt')
        v.ribbon(im,t,x=555,y=583,width=810,height=52)
        v.text(im,'Replay. Share. Bring it to your agent.',(960,704),34,v.SLATE,anchor='mt')
        v.text(im,'Audio & screen recording for macOS',(960,791),26,v.IRIS,'medium',anchor='mt')
        v.text(im,'macOS 26+ · Apple Silicon',(960,840),21,v.SLATE,anchor='mt')
    subtitle(im,t)
    return im.convert('RGB')


def soundtrack():
    if not (OUT/'music.wav').exists():v.make_music(OUT/'music.wav')
    result=OUT/'soundtrack-en.flac'
    graph='[0:a]aresample=48000,pan=stereo|c0=c0|c1=c0[voice];[1:a]volume=0.13[bed];[voice][bed]amix=inputs=2:normalize=0,loudnorm=I=-18:TP=-1.5:LRA=7[a]'
    subprocess.run(['ffmpeg','-y','-v','error','-i',str(ROOT/'assets/narration-en.flac'),'-i',str(OUT/'music.wav'),
                    '-filter_complex',graph,'-map','[a]','-ar','48000','-t','60','-c:a','flac',str(result)],check=True)
    return result


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--stills',action='store_true');args=parser.parse_args()
    OUT.mkdir(exist_ok=True)
    try:
        if args.stills:
            times=[2,8,14,19,24.5,30.5,35,38,42,46,49.5,53,57]
            sheet=Image.new('RGB',(1600,math.ceil(len(times)/3)*330),'#E8EAF0')
            for i,t in enumerate(times):
                im=frame(t);im.save(OUT/f'en-frame-{t:g}.jpg',quality=95)
                im.thumbnail((520,292));sheet.paste(im,((i%3)*535,(i//3)*330))
                ImageDraw.Draw(sheet).text(((i%3)*535+8,(i//3)*330+295),f'{t:g}s',font=v.font(19),fill=v.INK)
            sheet.save(OUT/'en-contact-sheet.jpg',quality=92)
            frame(2).save(OUT/'poster-en.jpg',quality=95)
            print('English stills rendered.');return
        sound=soundtrack()
        command=['ffmpeg','-y','-v','error','-f','rawvideo','-pix_fmt','rgb24','-s','1920x1080','-r','30','-i','-',
                 '-i',str(sound),'-map','0:v','-map','1:a','-c:v','libx264','-preset','medium','-crf','19',
                 '-pix_fmt','yuv420p','-c:a','aac','-b:a','192k','-ar','48000','-t','60','-movflags','+faststart',
                 '-metadata','title=Scriber — Record it. Put it to work.', '-metadata:s:a:0','language=eng',
                 str(OUT/'scriber-intro-en.mp4')]
        encoder=subprocess.Popen(command,stdin=subprocess.PIPE)
        try:
            for i in range(1800):
                encoder.stdin.write(frame(i/30).tobytes())
                if i%150==0:print(f'Rendered {i}/1800 English frames',flush=True)
        except BaseException:
            encoder.kill();encoder.wait();raise
        finally:encoder.stdin.close()
        if encoder.wait()!=0:raise RuntimeError('English video encoding failed')
        print(OUT/'scriber-intro-en.mp4')
    finally:
        for clip in [AUDIO,REGION,VIDEO]:clip.close()

if __name__=='__main__':main()
