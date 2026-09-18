# Scriber · 录下来，接着用

一分钟中文产品介绍：为什么用 Scriber、怎样录音／录屏，以及如何拿到本地文件。1920×1080，30 fps，中文字幕与原创轻音乐；静音观看也能理解。

[下载 MP4](https://raw.githubusercontent.com/luyao618/dayscribe/main/video/scriber-intro-zh.mp4) · [分镜与文案](STORYBOARD.md) · [字幕](scriber-zh.srt) · [素材来源](assets/provenance.json)

## 内容与来源

- 面板、声音开关、录制中改名、区域选择和视频播放来自当前签名 Scriber.app 的真实原生操作。界面录像去掉了音轨，仅保留独立制作的配乐。
- 使用隔离历史与专门准备的演示画布，内容为「产品讨论」「方案演示」。没有使用真实会议、聊天、个人历史或第三方品牌素材。
- 说明文字、声音线条和 MP4／M4A 文件动画由本项目原创绘制；它们是视频包装，不是新增的应用界面。
- 参考 [hermes-on-herdr 产品短片](https://github.com/nocoo/hermes-on-herdr/tree/main/video) 的简洁叙事与留白，没有复用其代码、配乐、品牌或画面。
- `music.py` 通过确定的音符合成原创器乐，不使用采样或第三方音频。字体来自 macOS 的 PingFang SC 与 SF 系列，仅在本机渲染，不分发字体文件。
- Agent 总结由用户选择的其他工具完成，Scriber 提供本地文件，不内置 AI 或转录。现有验收限制见 [验收记录](../docs/ACCEPTANCE.md)。

## 本地观看

运行 `python3 video/serve.py`，打开 <http://127.0.0.1:8877/video/>。支持播放、暂停、拖动进度、章节跳转、全屏与下载。服务仅监听本机，并支持视频跳转所需的 HTTP 字节范围请求。

## 重新生成

需要 macOS（系统 PingFang SC 和 SF 字体）、Python 3.11+ 及 FFmpeg。应用本身不依赖这些视频制作工具。

```sh
python3 -m venv video/.venv
video/.venv/bin/pip install -r video/requirements.txt
video/.venv/bin/python video/music.py
video/.venv/bin/python video/render.py --stills
video/.venv/bin/python video/render.py
cp video/output/scriber-intro-zh.mp4 video/scriber-intro-zh.mp4
cp video/output/poster.jpg video/poster.jpg
video/.venv/bin/python video/verify.py
```

输出在 `video/output/`：成片 `scriber-intro-zh.mp4`、配乐 `music.wav`、封面与分镜检查图。`assets/` 中提交了已检查的原生截屏和静音片段，重新生成不需要驱动桌面或再次录音。原始采集及诊断仍仅保留在本机忽略目录。

使用不同版本的字体、编码器或 Python 库重新渲染，字形和压缩结果可能略有差异；交付版本和检查结果记录在 `VERIFICATION.md`。
