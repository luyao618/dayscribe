# 项目介绍素材

- `scriber-mark.svg`：沿用应用的紫色波形标识，以可编辑 SVG 绘制；不修改原生应用图标。
- `scriber-preview.gif`：从已交付的中文短片抽取五段画面，约 10 秒、880×495、8 fps，用于 GitHub 首页直接预览。完整带配乐版本仍为 `video/scriber-intro-zh.mp4`。

在仓库根目录重新生成动图：

```sh
ffmpeg -y -i video/scriber-intro-zh.mp4 -filter_complex "[0:v]select='between(t,1,3)+between(t,13,15)+between(t,33,35)+between(t,42,44)+between(t,56,58)',setpts=N/30/TB,fps=8,scale=880:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" -loop 0 docs/media/scriber-preview.gif
```
