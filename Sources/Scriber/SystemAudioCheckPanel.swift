import SwiftUI

struct SystemAudioCheckPanel: View {
    @ObservedObject var recorder: AudioRecorder
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.text("Scriber · 音频采集检查"), systemImage: "waveform")
                .font(.system(size: 18, weight: .semibold))
            Text(recorder.sources.map { $0 == .system ? L10n.text("电脑声音") : L10n.text("麦克风") }.sorted().joined(separator: " + "))
                .font(.system(size: 11))
            Text(recorder.state.title).foregroundStyle(.secondary)
            Text(String(format: L10n.text("%.1f 秒"), recorder.summary?.duration ?? 0))
                .font(.system(size: 32, design: .monospaced))
            AudioLevelMeter(powerDB: recorder.summary?.powerDBFS ?? -160,
                            tint: Color(red: 0.44, green: 0.40, blue: 0.81),
                            label: L10n.text("混合音频真实电平"))
            if let error = recorder.errorMessage {
                Text(error).foregroundStyle(.red).font(.system(size: 11))
            }
            Text(recorder.videoURL == nil ? L10n.text("本检查保存一份音频，不保存屏幕画面。") : L10n.text("正在检查全屏录制 · MP4 视频 + M4A 音频"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button(L10n.text("停止检查"), action: onStop).disabled(!recorder.state.active)
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(width: 390)
    }
}
