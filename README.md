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

> 2026-09-16 重新确定方向。Scriber 为候选名称；主面板已接入双路音频引擎。新的运行中独立启停方案等待解锁后的真实验证，录屏仍在实现中。

## 原生应用开发

当前主面板使用 AudioRecorder，默认选择两路声音并记住后续选择，分别显示真实电平、麦克风设备提示与文件名，停止后显示最近保存的 M4A。运行中声音切换已实现；最终独立采集流启停和 AppKit 退出仍待真实验证。录屏、改名、目录设置和完整历史尚未接入。

需要 macOS 26+、Apple Silicon 和 Xcode 26。运行 `./scripts/build-app.sh` 构建并本地签名，随后双击 `build/Scriber.app`，或运行 `open build/Scriber.app`。菜单栏波形图标用于打开和收起面板，面板右上角设置菜单可退出应用。

脚本默认构建 debug，传入 `release` 可构建优化版本。重新构建前先退出 Scriber，脚本会拒绝覆盖正在运行的应用包。若本机只有一个有效 Apple Development 签名身份，脚本优先使用它以保持更新身份稳定；否则使用本地 ad-hoc 签名。可用 `SCRIBER_SIGN_IDENTITY` 明确指定身份或指定 `-` 使用 ad-hoc，无需创建新证书。

短时真实麦克风检查：先退出普通 Scriber，再运行 `open build/Scriber.app --args --show-panel --microphone-check /absolute/output/directory 5`。该入口现在使用同一双路引擎的麦克风模式，需要麦克风及屏幕与系统音频录制权限，保存 M4A 和 result.json 并退出。中途退出会标记为 interrupted，不算完成请求的时长。测试音频请保留在本地，不提交进仓库。

也可运行 `scripts/check-microphone.py --seconds 5`，或 `scripts/check-microphone.py --seconds 30 --interrupt-after 2` 验证录制中退出。脚本需要 ffmpeg / ffprobe，仅用于检查文件时长和完整解码，不是应用运行依赖。

电脑声音检查：`scripts/check-system-audio.py --seconds 8` 会通过系统播放两段很轻的已知频率测试音，并从实际录制文件检查频率、顺序、时长和完整解码；`--seconds 30 --interrupt-after 5` 可验证异步退出保存。仅写音频，不保存屏幕画面。首次需要在系统设置中允许 Scriber 的屏幕与系统音频录制权限。

双路混音检查：`scripts/check-system-audio.py --sources both --seconds 8`。麦克风声学校准可使用 `--sources microphone --microphone-device BuiltInMicrophoneDevice --playback-device BuiltInSpeakerDevice`，短测试音只通过内置扬声器播放，录制只取麦克风，保持系统默认设备设置。其他设备 UID 可通过`xcrun swift tools/PlayAudioFixture.swift --devices` 查询；使用 `--expected-microphone-rate` 检查实际输入采样率。每次只生成一份 M4A，原始媒体和诊断数据保存在忽略提交的 artifacts/ 下。这些短测不能替代设备切换、蓝牙和 8 小时 / 2 小时验收。

主面板与运行中切换检查：`scripts/check-source-switching.py` 会录制 11 秒并检查声音开关、底层回调、输出信号和最后一路保护；支持 `--sources` 与 `--microphone-device`。AppKit 退出检查可用 `scripts/check-system-audio.py --panel --sources both --seconds 30 --interrupt-after 5 --quit-via-appkit`。这两项最终验证等待 Mac 解锁并亮屏。

只读权限检查：`open build/Scriber.app --args --capture-permission-check /absolute/report.json`。该入口只查询本应用权限，不触发录制或修改系统权限。

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
