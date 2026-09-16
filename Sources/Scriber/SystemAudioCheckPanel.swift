import SwiftUI

struct SystemAudioCheckPanel: View {
    @ObservedObject var recorder: SystemAudioRecorder
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Scriber · 电脑声音检查", systemImage: "waveform")
                .font(.system(size: 18, weight: .semibold))
            Text(recorder.state.title).foregroundStyle(.secondary)
            Text(String(format: "%.1f 秒", recorder.summary?.duration ?? 0))
                .font(.system(size: 32, design: .monospaced))
            AudioLevelMeter(powerDB: recorder.summary?.powerDBFS ?? -160,
                            tint: Color(red: 0.44, green: 0.40, blue: 0.81),
                            label: "电脑声音真实电平")
            if let error = recorder.errorMessage {
                Text(error).foregroundStyle(.red).font(.system(size: 11))
            }
            Text("本检查只保存电脑声音，不保存屏幕画面。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("停止检查", action: onStop).disabled(!recorder.state.active)
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(width: 390)
    }
}
