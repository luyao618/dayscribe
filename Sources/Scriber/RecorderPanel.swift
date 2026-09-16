import AppKit
import SwiftUI

struct RecorderPanel: View {
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
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 11))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("录制模式")

            VStack(spacing: 5) {
                Text("未录制")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("00:00:00")
                    .font(.system(size: 40, weight: .regular, design: .monospaced))
                    .monospacedDigit()
            }
            .padding(.vertical, 10)

            Button {} label: {
                Label(mode == .audio ? "开始录音" : "选择范围并录屏",
                      systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(true)
            .help("录制引擎尚未接入")
        }
        .padding(20)
        .frame(width: 390)
    }
}

enum RecordingMode: String, CaseIterable {
    case audio
    case video

    var title: String { self == .audio ? "录音" : "录屏" }
    var symbol: String { self == .audio ? "mic" : "display" }
}
