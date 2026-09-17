import SwiftUI

struct RecordingDestinationsPanel: View {
    @ObservedObject var recorder: AudioRecorder
    let onBack: () -> Void
    let onChoose: ((RecordingMode) async -> Void)?
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .buttonStyle(PanelIconButtonStyle()).accessibilityLabel("返回录制面板")
                Text("保存位置").font(.system(size: 18, weight: .semibold))
                Spacer()
            }
            Text("选好位置，每次录完自动保存。")
                .font(.system(size: 12)).foregroundStyle(PanelPalette.slate)
            ForEach(RecordingMode.allCases, id: \.self) { mode in
                Button {
                    Task {
                        choosing = true
                        defer { choosing = false }
                        await onChoose?(mode)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: mode.symbol).foregroundStyle(mode == .audio ? PanelPalette.jade : PanelPalette.iris)
                            Text("\(mode.title)文件").fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "folder").foregroundStyle(PanelPalette.slate)
                        }
                        .font(.system(size: 13))
                        Text((recorder.destination(for: mode).path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11)).lineLimit(2).truncationMode(.middle)
                            .foregroundStyle(PanelPalette.ink)
                        Text(mode == .audio ? "一份包含所选声音的音频文件" : "视频和独立音频会放在一起")
                            .font(.system(size: 10)).foregroundStyle(PanelPalette.slate)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(choosing || onChoose == nil || recorder.isBusy)
                .accessibilityLabel("更改\(mode.title)保存位置")
                .accessibilityValue(recorder.destination(for: mode).path)
                .help(recorder.destination(for: mode).path)
            }
            if recorder.state.active {
                Text("当前录制仍保存在原位置，新位置从下次开始使用。")
                    .font(.system(size: 11)).foregroundStyle(PanelPalette.iris)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = recorder.controlMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(PanelPalette.record)
            }
            Button(action: onBack) {
                Text("完成").font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 42)
                    .foregroundStyle(.white)
                    .background(PanelPalette.iris, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            Label("选择文件夹后自动记住，随时可以从 Finder 打开。", systemImage: "folder")
                .font(.system(size: 10)).foregroundStyle(PanelPalette.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}
