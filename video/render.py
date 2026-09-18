"""Render Scriber product film from real native captures and original graphics.

macOS + Python dependencies in requirements.txt + FFmpeg. No network services.
python3 video/render.py --stills
python3 video/render.py
"""
import argparse
from functools import lru_cache
import json
import math
from pathlib import Path
import subprocess

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from music import make as make_music

ROOT = Path(__file__).resolve().parent
ASSETS, OUT = ROOT / 'assets', ROOT / 'output'
W, H, FPS, SECONDS = 1920, 1080, 30, 60
INK, SLATE = '#262B38', '#717887'
IRIS, JADE, RED = '#7067CF', '#399980', '#DA666A'
PEARL, LINE = '#F4F5F8', '#E3E5EC'
FONT_ROOT = Path('/System/Library/Fonts')
PING = next(Path('/System/Library/AssetsV2').glob('com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc'), None)
if PING is None:
    raise SystemExit('PingFang SC is required. Run on macOS with its system Chinese fonts installed.')

@lru_cache(None)
def font(size, weight='regular', family='text'):
    if family=='brand': return ImageFont.truetype(str(FONT_ROOT/'SFNSRounded.ttf'),size)
    if family=='mono': return ImageFont.truetype(str(FONT_ROOT/'SFNSMono.ttf'),size)
    return ImageFont.truetype(str(PING),size,index={'regular':3,'medium':7,'bold':11}[weight])

def clamp(x):return min(1,max(0,x))
def ease(x):x=clamp(x);return 1-(1-x)**3

def text(im, value, xy, size=32, color=INK, weight='regular', family='text', anchor='lt'):
    d=ImageDraw.Draw(im)
    for i,line in enumerate(value.split('\n')):
        d.text((xy[0],xy[1]+i*(size+14)),line,font=font(size,weight,family),fill=color,anchor=anchor)

@lru_cache(None)
def load(name):return Image.open(ASSETS/name).convert('RGBA')

@lru_cache(None)
def sized(name, width):
    im=load(name)
    return im.resize((width,round(im.height*width/im.width)),Image.Resampling.LANCZOS)

# A quiet, very light lilac field; all movement belongs to the recording story.
y,x=np.mgrid[0:H,0:W]
bg=np.empty((H,W,3),dtype=np.uint8)
glow=np.exp(-(((x-1480)/640)**2+((y-510)/680)**2))
for c,a,b in [(0,248,237),(1,249,239),(2,252,249)]:bg[:,:,c]=a+(b-a)*glow
BASE=Image.fromarray(bg).convert('RGBA')
del x,y,bg,glow

@lru_cache(None)
def shadow(width,height):
    im=Image.new('RGBA',(width+160,height+160))
    ImageDraw.Draw(im).rounded_rectangle((75,69,width+85,height+91),radius=32,fill=(44,48,78,32))
    return im.filter(ImageFilter.GaussianBlur(25))

def panel(im, source, xy=(1192,143), width=490, entry=1):
    pic=sized(source,width) if isinstance(source,str) else source
    x,y=xy;x+=round((1-ease(entry))*55)
    im.alpha_composite(shadow(pic.width,pic.height),(x-80,y-80))
    im.alpha_composite(pic,(x,y))
    return (x,y,pic.width,pic.height)

def mark(im,x,y,size=46,t=0,color=IRIS):
    d=ImageDraw.Draw(im)
    for i,h in enumerate([.25,.62,.94,.48,.77,.35]):
        ht=size*h*(1+.06*math.sin(t*2+i))
        left=x+i*size*.145
        d.rounded_rectangle((left,y+(size-ht)/2,left+size*.065,y+(size+ht)/2),radius=size*.033,fill=color)

def header(im,t,step):
    mark(im,96,54,40,t)
    text(im,'Scriber',(144,52),36,weight='bold',family='brand')
    text(im,'macOS  /  录音与录屏',(1824,63),22,SLATE,anchor='rt')
    d=ImageDraw.Draw(im);d.line((96,1019,1824,1019),fill=LINE,width=2)
    d.line((96,1019,96+1728*t/SECONDS,1019),fill=IRIS,width=3)
    text(im,step,(96,1040),18,SLATE)
    text(im,f'{int(t):02d} / 60',(1824,1040),17,SLATE,family='mono',anchor='rt')

def copy(im,title,body,tag,y=269,enter=1):
    offset=round((1-ease(enter))*25)
    text(im,tag,(112,y-63+offset),23,IRIS,'medium')
    text(im,title,(106,y+offset),86,weight='bold')
    title_lines=title.count('\n')+1
    text(im,body,(112,y+title_lines*110+28+offset),31,SLATE)

def caption(im,value):text(im,value,(960,968),28,SLATE,anchor='mt')

def ring(im,xy,t,color=IRIS):
    x,y=xy;p=t%1.8
    r=18+15*p
    layer=Image.new('RGBA',(W,H));d=ImageDraw.Draw(layer)
    rgb=tuple(bytes.fromhex(color[1:]))
    d.ellipse((x-r,y-r,x+r,y+r),outline=rgb+(round(150*(1-p/1.8)),),width=3)
    im.alpha_composite(layer)

def pill(im,label,x,y,color=IRIS):
    f=font(25,'medium');d=ImageDraw.Draw(im);w=d.textlength(label,font=f)+40
    d.rounded_rectangle((x,y,x+w,y+49),radius=24,fill='white',outline=LINE,width=2)
    text(im,label,(x+20,y+10),25,color,'medium')
    return w

def ribbon(im,t,x=112,y=719,width=820,height=84):
    d=ImageDraw.Draw(im)
    for j,col in enumerate([IRIS,JADE]):
        points=[]
        for i in range(0,width,3):
            env=math.sin(math.pi*i/width)**1.2
            value=math.sin(i*.043-t*2.2+j*1.6)*env*height/2
            points.append((x+i,y+value+j*10))
        d.line(points,fill=col,width=3)

class Clip:
    def __init__(self,name,width):self.name=name;self.width=width;self.proc=None;self.index=-1;self.current=None
    def frame(self,t):
        target=max(0,int(t*FPS))
        if self.proc is None or target<self.index:
            self.close()
            p=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=width,height','-of','json',str(ASSETS/self.name)]))['streams'][0]
            self.height=round(p['height']*self.width/p['width'])
            self.mask=Image.new('L',(self.width,self.height));ImageDraw.Draw(self.mask).rounded_rectangle((0,0,self.width-1,self.height-1),radius=28,fill=255)
            self.proc=subprocess.Popen(['ffmpeg','-v','error','-i',str(ASSETS/self.name),'-vf',f'scale={self.width}:{self.height},fps={FPS}','-f','rawvideo','-pix_fmt','rgb24','-'],stdout=subprocess.PIPE)
            self.index=-1
        while self.index<target:
            raw=self.proc.stdout.read(self.width*self.height*3)
            if len(raw)!=self.width*self.height*3:raise RuntimeError(f'Native clip ended: {self.name} at {target}')
            self.current=Image.frombytes('RGB',(self.width,self.height),raw).convert('RGBA');self.current.putalpha(self.mask);self.index+=1
        return self.current
    def close(self):
        if self.proc is not None:
            if self.proc.poll() is None:self.proc.kill()
            self.proc.wait();self.proc.stdout.close();self.proc=None

AUDIO=Clip('audio-demo.mp4',490)
REGION=Clip('region-demo.mp4',1130)
VIDEO=Clip('video-demo.mp4',460)

SCENES=[(0,6,'随手留下'),(6,12,'打开面板'),(12,22,'开始录音'),(22,29,'看得清楚'),
        (29,40,'选择录屏'),(40,48,'本地文件'),(48,55,'找到内容'),(55,60,'接着使用')]

def document(im,x,y,ext,color,t,title,detail):
    d=ImageDraw.Draw(im);w,h=300,310
    lift=round(14*math.sin(t*.65))
    y+=lift
    im.alpha_composite(shadow(w,h),(x-80,y-80))
    d.rounded_rectangle((x,y,x+w,y+h),radius=27,fill='white',outline=LINE,width=2)
    d.rounded_rectangle((x+34,y+36,x+w-34,y+170),radius=16,fill=PEARL)
    if ext=='MP4':
        d.rounded_rectangle((x+70,y+68,x+213,y+144),radius=10,outline=color,width=4)
        d.polygon([(x+129,y+87),(x+129,y+125),(x+158,y+106)],fill=color)
    else:mark(im,x+109,y+69,74,t,color)
    text(im,ext,(x+34,y+194),48,color,'bold','mono')
    text(im,title,(x+w/2,y+h+30),29,INK,'medium',anchor='mt')
    text(im,detail,(x+w/2,y+h+77),24,SLATE,anchor='mt')

def frame(t):
    im=BASE.copy()
    start,end,name=next(s for s in SCENES if s[0]<=t<s[1])
    q=t-start;enter=ease(q/.8)
    header(im,t,name)
    if start==0:
        copy(im,'值得留下，\n就录下来。','会议、通话、视频里的重要内容。\n随手录成自己的本地文件。','MAC 菜单栏录制工具',y=272,enter=enter)
        panel(im,'audio-ready.png',entry=enter)
        ribbon(im,t,width=810,y=772)
    elif start==6:
        copy(im,'随时开始。\n就在菜单栏。','点击 Scriber 图标，\n或按快捷键呼出面板。','打开面板',y=261,enter=enter)
        panel(im,'audio-ready.png',entry=enter)
        d=ImageDraw.Draw(im)
        for x,label,w in [(112,'⌥',92),(220,'R',92)]:
            d.rounded_rectangle((x,638,x+w,730),radius=18,fill='white',outline=LINE,width=2)
            text(im,label,(x+w/2,652),47,INK,'medium','brand',anchor='mt')
        text(im,'默认快捷键，可修改',(340,667),26,SLATE)
        ring(im,(1632,745),q)
        caption(im,'首次使用，按系统提示授予录音与录屏权限。')
    elif start==12:
        copy(im,'两路声音，\n分别掌握。','电脑声音与麦克风，按需开关。\n点击「开始录音」即可记录。','录音',y=254,enter=enter)
        panel(im,AUDIO.frame(q))
        pill(im,'电脑声音',112,679,IRIS);pill(im,'麦克风',298,679,JADE)
        caption(im,'收起面板，录制仍会继续。')
    elif start==22:
        copy(im,'录到哪里，\n一眼就知道。','时长、声音状态，始终看得见。\n录制中，也能直接修改文件名。','录制状态',y=265,enter=enter)
        panel(im,AUDIO.frame(10+q))
        ribbon(im,t,y=754,width=800,height=48)
    elif start==29:
        if q<3.8:
            copy(im,'声音之外，\n把画面也留下。','选择录屏，再确认要录的范围。','录屏',y=245,enter=enter)
            panel(im,'range-options.png',width=460,xy=(1210,138))
            x=112
            for label in ['自选区域','单个窗口','整块屏幕']:x+=pill(im,label,x,672)+14
        elif q<8.2:
            text(im,'框选这一段。',(110,189),70,INK,'bold')
            text(im,'拖动框选，按回车开始。',(116,286),31,SLATE)
            pic=REGION.frame(min(4.8,q-3.8+.3))
            panel(im,pic,xy=(685,258))
            pill(im,'自选区域',112,389)
            text(im,'只把需要的画面\n留在文件里。',(112,478),36,SLATE)
        else:
            copy(im,'画面和声音，\n一起记录。','录完，点击「停止并保存」。','录屏进行中',y=261,enter=enter)
            panel(im,VIDEO.frame(q-8.2),width=460,xy=(1210,138))
    elif start==40:
        text(im,'一次录屏，两份文件。',(960,177),73,INK,'bold',anchor='mt')
        text(im,'画面留着回看，音频可以单独使用。',(960,283),32,SLATE,anchor='mt')
        document(im,540,399,'MP4',IRIS,q,'方案演示.mp4','视频自带声音')
        document(im,1080,399,'M4A',JADE,q+.5,'方案演示.m4a','同名独立音频')
        text(im,'+',(960,506),72,SLATE,'regular','brand',anchor='mt')
        caption(im,'只选择录音时，输出一个合成的 M4A 文件。')
    elif start==48:
        if q<3.3:
            copy(im,'存在哪里，\n你来定。','录音、录屏分别设置保存目录。\n每次录完，自动存好。','文件管理',y=283,enter=enter)
            panel(im,'destinations.png',width=580,xy=(1150,250))
        else:
            copy(im,'想回看，\n随时找得到。','历史里播放、改名，\n一键在 Finder 中定位。','文件管理',y=283,enter=enter)
            panel(im,'playback.png',width=500,xy=(1195,184))
        caption(im,'所有录制保存在本机，文件可以直接交给其他工具。')
    else:
        mark(im,692,248,88,q)
        text(im,'Scriber',(965,251),103,INK,'bold','brand',anchor='mt')
        text(im,'录下来，接着用。',(960,443),80,INK,'bold',anchor='mt')
        ribbon(im,t,x=555,y=607,width=810,height=52)
        text(im,'回看  /  分享  /  交给你的 Agent',(960,716),34,SLATE,anchor='mt')
        text(im,'macOS 菜单栏录音与录屏',(960,821),27,IRIS,'medium',anchor='mt')
        text(im,'macOS 26+ · Apple Silicon',(960,874),21,SLATE,anchor='mt')
    # Brief white dissolves prevent abrupt changes without hiding any action.
    if start>0 and q<.24:
        im=Image.blend(BASE,im,ease(q/.24))
    if t>59.5:im=Image.blend(im,BASE,clamp((t-59.5)/.5)*.14)
    return im.convert('RGB')

CAPTIONS=[(0,6,'会议、通话、视频里的重要内容，随手录成本地文件。'),
(6,12,'点击菜单栏图标，或按 Option + R 呼出面板。首次使用请授予系统权限。'),
(12,22,'电脑声音和麦克风分别开关。点击开始录音，收起面板也会继续录制。'),
(22,29,'实时查看时长和声音状态，录制中直接修改文件名。'),
(29,33,'选择录屏，支持自选区域、单个窗口或整块屏幕。'),
(33,37,'拖动框选范围，按回车开始录屏。'),
(37,40,'画面与声音一起记录，结束时点击停止并保存。'),
(40,48,'录屏输出带声音的 MP4 视频与同名独立 M4A 音频。只录音则输出一个 M4A。'),
(48,55,'分别设置保存目录。在历史中播放、改名或定位文件。'),
(55,60,'Scriber，录下来，接着用。回看、分享，或交给你的 Agent。')]

def subtitles():
    def stamp(t):return f'00:{int(t)//60:02d}:{int(t)%60:02d},000'
    srt='\n\n'.join(f'{i+1}\n{stamp(a)} --> {stamp(b)}\n{v}' for i,(a,b,v) in enumerate(CAPTIONS))+'\n'
    (ROOT/'scriber-zh.srt').write_text(srt)
    (ROOT/'scriber-zh.vtt').write_text('WEBVTT\n\n'+srt.replace(',000','.000'))

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--stills',action='store_true');args=parser.parse_args()
    OUT.mkdir(exist_ok=True);subtitles()
    try:
        if args.stills:
            times=[3,9,16,24.5,31,35.3,38.4,44,49.5,53,57.5]
            sheet=Image.new('RGB',(1600,math.ceil(len(times)/3)*330),'#E8EAF0')
            for i,t in enumerate(times):
                im=frame(t);im.save(OUT/f'frame-{t:g}.jpg',quality=95)
                im.thumbnail((520,292));sheet.paste(im,((i%3)*535,(i//3)*330))
                ImageDraw.Draw(sheet).text(((i%3)*535+8,(i//3)*330+295),f'{t:g}s',font=font(19),fill=INK)
            sheet.save(OUT/'contact-sheet.jpg',quality=92)
            frame(3).save(OUT/'poster.jpg',quality=95)
            print('Stills rendered.');return
        if not (OUT/'music.wav').exists():make_music(OUT/'music.wav')
        cmd=['ffmpeg','-y','-v','error','-f','rawvideo','-pix_fmt','rgb24','-s',f'{W}x{H}','-r',str(FPS),'-i','-',
             '-i',str(OUT/'music.wav'),'-map','0:v','-map','1:a','-c:v','libx264','-preset','medium','-crf','19',
             '-pix_fmt','yuv420p','-c:a','aac','-b:a','192k','-af','loudnorm=I=-22:TP=-2:LRA=7',
             '-ar','48000','-t',str(SECONDS),'-movflags','+faststart','-metadata','title=Scriber — 录下来，接着用',str(OUT/'scriber-intro-zh.mp4')]
        encoder=subprocess.Popen(cmd,stdin=subprocess.PIPE)
        try:
            for i in range(FPS*SECONDS):
                encoder.stdin.write(frame(i/FPS).tobytes())
                if i%150==0:print(f'Rendered {i}/{FPS*SECONDS} frames',flush=True)
        finally:encoder.stdin.close()
        if encoder.wait()!=0:raise RuntimeError('FFmpeg encode failed')
        print(OUT/'scriber-intro-zh.mp4')
    finally:
        for clip in [AUDIO,REGION,VIDEO]:clip.close()

if __name__=='__main__':main()
