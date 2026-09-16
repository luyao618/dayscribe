import AppKit
import SwiftUI

struct RecorderPanel: View {
    @ObservedObject var microphone: MicrophoneRecorder
    @State private var mode = RecordingMode.audio
    private let accent = Color(red: 0.44, green: 0.40, blue: 0.81)

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(accent)
                Text("Scriber")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Spacer()
                Button("退出 Scriber", systemImage: "power") { NSApp.terminate(nil) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("退出 Scriber")
            }

            HStack(spacing: 3) {
                ForEach(RecordingMode.allCases, id: \.self) { choice in
                    Button {
                        mode = choice
                    } label: {
                        Label(choice.title, systemImage: choice.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(mode == choice ? Color(nsColor: .windowBackgroundColor) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(mode == choice ? Color.primary : Color.secondary)
                    .accessibilityAddTraits(mode == choice ? .isSelected : [])
                    .disabled(microphone.isRecording || microphone.isBusy)
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 11))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("录制模式")

            VStack(spacing: 5) {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(microphone.elapsedText)
                    .font(.system(size: 40, weight: .regular, design: .monospaced))
                    .monospacedDigit()
            }
            .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("麦克风", systemImage: "mic")
                    Spacer()
                    Text(microphone.isRecording
                         ? (microphone.powerDB > -65 ? "正在收音" : "等待声音") : "未录制")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                AudioLevelMeter(powerDB: microphone.powerDB)
            }

            if let url = microphone.outputURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label(url.lastPathComponent, systemImage: "folder")
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .disabled(microphone.phase != .saved)
            }

            if let error = microphone.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                if microphone.isRecording { microphone.stop() }
                else { Task { await microphone.start() } }
            } label: {
                Label(microphone.isRecording ? "停止并保存" : (mode == .audio ? "开始录音" : "选择范围并录屏"),
                      systemImage: microphone.isRecording ? "stop.fill" : "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(mode == .video || microphone.isBusy)
            .help(mode == .video ? "录屏引擎尚未接入" : "当前阶段录制麦克风声音")
        }
        .padding(20)
        .frame(width: 390)
    }

    private var statusText: String {
        if mode == .video { return "录屏暂不可用" }
        return switch microphone.phase {
        case .idle: "准备录音 · 麦克风"
        case .authorizing: "等待麦克风授权"
        case .recording: "正在录音 · 麦克风"
        case .finishing: "正在保存"
        case .saved: "已保存"
        case .failed: "录制未完成"
        }
    }
}

enum RecordingMode: String, CaseIterable {
    case audio
    case video

    var title: String { self == .audio ? "录音" : "录屏" }
    var symbol: String { self == .audio ? "mic" : "display" }
}
