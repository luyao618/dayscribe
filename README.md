# Scriber（暂定名）

一个 macOS 一键录音 / 录屏工具。

目标很简单：需要记录时快速开始，结束后拿到可用的音频或视频文件。

首要场景是自己录下 Teams 等会议，直接获得本地媒体文件，交给 agent 总结、分析和沉淀。

第一版面向自己的 Mac 使用，兼顾超过 6 小时的长录音、通常不超过 2 小时的录屏，以及有线 / 蓝牙声音设备。

```text
选择录音或录屏 → 开始录制 → 停止 → 保存文件
```

- **录视频**：保存带声音的视频，同时保存独立音频。
- **只录音**：电脑声音和麦克风可以分别开关，最终保存一个合成音频文件。

每次从小面板确认设置后开始。录完自动保存，历史列表支持播放、改名和在 Finder 中定位文件。

> 2026-09-16 重新确定方向。Scriber 为候选名称；菜单栏面板已有交互原型，macOS 应用尚未实现。

[实现说明与验收标准](SPEC.md) 已就绪，包含平台默认值、长时录制目标、设备变化处理及建议 Goal 文本。

[Goal Prompt](GOAL.md) 已包含逐步提交小 PR、检查与自审通过后自动合并的交付要求。

## UI 原型

[打开面板原型](design/index.html) · [设计说明](design/DESIGN.md) · [验证记录](design/QA.md)

常驻菜单栏的小面板，支持演示录音、选区录屏、录制中改名、双声音电平、保存路径和历史记录。声音与文件均为演示数据。

本地预览：运行 `python3 -m http.server 8765 --bind 127.0.0.1`，打开 [http://127.0.0.1:8765/design/](http://127.0.0.1:8765/design/)。

![Scriber 录制面板](design/screenshots/panel-preview.png)

第一版聚焦录制入口、录制状态、停止与文件保存。具体交互和录制范围见 [IDEAS.md](IDEAS.md)。

旧 dayscribe 的 AI 手账方案已归档到 [docs/archive/dayscribe/](docs/archive/dayscribe/IDEAS.md)。
旧 ASR 探针保留在 [PR #4](https://github.com/luyao618/dayscribe/pull/4) 和原有分支中，不属于新应用。
