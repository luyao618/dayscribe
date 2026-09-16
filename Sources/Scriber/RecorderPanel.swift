import AppKit
import SwiftUI

struct RecorderPanel: View {
    @ObservedObject var recorder: AudioRecorder
    @State var mode = RecordingMode.audio
    @State private var showsSettings = false
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 0) {
                modePicker
                summary
                if mode == .video { captureTarget }
                sources
                destination
                if let error = recorder.errorMessage ?? recorder.controlMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(PanelPalette.record)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                }
                primaryAction
                Text(mode == .audio ? "保存为 M4A 音频" : "同时保存 MP4 视频和 M4A 音频")
                    .font(.system(size: 10))
                    .foregroundStyle(PanelPalette.slate)
                    .frame(height: 24, alignment: .bottom)
                recentRecording
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .foregroundStyle(PanelPalette.ink)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
        .background(PanelPalette.pearl)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.7)))
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(PanelPalette.iris)
                .frame(width: 26)
            Text("Scriber")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .tracking(-0.5)
            Spacer()
            HStack(spacing: 6) {
                Button {} label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(PanelIconButtonStyle())
                    .disabled(true)
                    .help("历史列表暂不可用；下方可查看最近一次录音")
                    .accessibilityLabel("历史列表，暂不可用")
                Button { showsSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(PanelIconButtonStyle())
                    .help("设置")
                    .accessibilityLabel("设置")
                    .popover(isPresented: $showsSettings) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("设置").font(.headline)
                            Text("保存位置与快捷键设置暂不可用")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Button("退出 Scriber") { onQuit() }
                        }
                        .padding(20)
                    }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 65)
    }

    private var modePicker: some View {
        HStack(spacing: 3) {
            ForEach(RecordingMode.allCases, id: \.self) { choice in
                Button { mode = choice } label: {
                    Label(choice.title, systemImage: choice.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(mode == choice ? PanelPalette.ink : PanelPalette.slate)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(mode == choice ? .white : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(mode == choice ? 0.04 : 0), radius: 2, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == choice ? .isSelected : [])
                .disabled(recorder.isRecording || recorder.isBusy)
            }
        }
        .padding(3)
        .background(PanelPalette.track, in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("录制模式")
    }

    private var summary: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 5, height: 5)
                Text(statusText).font(.system(size: 11)).foregroundStyle(statusColor)
            }
            .frame(height: 18)
            let hoursMinutes = Text(String(clockText.dropLast(3))).foregroundStyle(PanelPalette.ink)
            let seconds = Text(String(clockText.suffix(3))).foregroundStyle(PanelPalette.muted)
            Text("\(hoursMinutes)\(seconds)")
                .font(.system(size: 41, weight: .regular, design: .monospaced))
                .tracking(-2.2)
                .monospacedDigit()
                .frame(height: 61)
                .accessibilityLabel("录制时长")
                .accessibilityValue(clockText)
            Button {} label: {
                HStack(spacing: 8) {
                    Text(filename)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                    Image(systemName: "pencil")
                        .font(.system(size: 11)).foregroundStyle(PanelPalette.muted)
                }
                .frame(width: 260, height: 27)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .help("文件名自动生成；修改文件名暂不可用")
            .accessibilityLabel("文件名：\(filename)，改名暂不可用")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 19)
        .padding(.bottom, 16)
    }

    private var captureTarget: some View {
        HStack(spacing: 8) {
            Image(systemName: "viewfinder").foregroundStyle(PanelPalette.iris)
            Text("自选区域")
            Spacer()
            Text("范围选择暂不可用").font(.system(size: 10)).foregroundStyle(PanelPalette.slate)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(PanelPalette.iris.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PanelPalette.iris.opacity(0.09)))
        .padding(.top, -4)
        .padding(.bottom, 17)
    }

    private var sources: some View {
        VStack(spacing: 0) {
            HStack {
                Text("声音来源").fontWeight(.semibold)
                Spacer()
                Text("\(recorder.sources.count) 路已开启").font(.system(size: 10))
            }
            .font(.system(size: 11))
            .foregroundStyle(PanelPalette.slate)
            .padding(.bottom, 9)
            .frame(height: 27, alignment: .top)
            VStack(spacing: 0) {
                sourceRow(.system)
                Rectangle().fill(PanelPalette.line).frame(height: 1)
                sourceRow(.microphone)
            }
            .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white))
        }
    }

    private var destination: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 16))
                .foregroundStyle(PanelPalette.slate)
                .frame(width: 29, height: 29)
                .background(PanelPalette.track, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text("保存到").font(.system(size: 10))
                Text(destinationPath).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(PanelPalette.slate)
            Spacer(minLength: 4)
            Button {} label: {
                HStack(spacing: 3) {
                    Text("更改")
                    Image(systemName: "chevron.right").font(.system(size: 8))
                }
                .font(.system(size: 10)).foregroundStyle(PanelPalette.slate)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .help("修改保存位置暂不可用")
        }
        .frame(height: 60)
        .help(destinationURL.path)
    }

    private var primaryAction: some View {
        Button {
            if recorder.isRecording { Task { await recorder.stop() } }
            else { Task { await recorder.start() } }
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: recorder.isRecording ? 2 : 5)
                    .frame(width: 10, height: 10)
                Text(recorder.state == .finishing ? "正在保存…" : (recorder.state == .authorizing ? "正在准备…"
                     : (recorder.isRecording ? "停止并保存" : (mode == .audio ? "开始录音" : "选择范围并录屏"))))
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .foregroundStyle(recorder.isRecording ? PanelPalette.stopInk : .white)
            .background(recorder.isRecording ? PanelPalette.stopBackground : PanelPalette.iris,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(mode == .video || recorder.isBusy)
        .help(mode == .video ? "录屏暂不可用" : "录制已开启的声音来源")
    }

    private var recentRecording: some View {
        VStack(spacing: 0) {
            Rectangle().fill(PanelPalette.line).frame(height: 1)
                .padding(.bottom, 13)
            HStack {
                Text("最近录制").fontWeight(.semibold)
                Spacer()
                Button("查看全部 ›") {}
                    .buttonStyle(.plain).disabled(true)
                    .help("完整历史列表暂不可用")
            }
            .font(.system(size: 11))
            .foregroundStyle(PanelPalette.slate)
            .padding(.bottom, 9)
            if let url = recorder.lastSavedURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    HStack(spacing: 10) {
                        recordingIcon
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                            Text("M4A 音频 · 在 Finder 中显示")
                                .font(.system(size: 10)).foregroundStyle(PanelPalette.slate)
                        }
                        Spacer(minLength: 2)
                        Text(recorder.lastSavedDuration).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(PanelPalette.slate)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9)).foregroundStyle(PanelPalette.muted)
                    }
                    .frame(height: 45)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("在 Finder 中显示已保存的录音")
            } else {
                HStack(spacing: 10) {
                    recordingIcon
                    Text("录制完成后，文件会显示在这里")
                        .font(.system(size: 11)).foregroundStyle(PanelPalette.slate)
                    Spacer()
                }
                .frame(height: 45)
            }
        }
        .padding(.top, 17)
    }

    private var recordingIcon: some View {
        Image(systemName: "waveform")
            .font(.system(size: 16)).foregroundStyle(PanelPalette.jade.opacity(0.8))
            .frame(width: 31, height: 31)
            .background(PanelPalette.jade.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var clockText: String { mode == .audio ? recorder.elapsedText : "00:00:00" }
    private var filename: String {
        if mode == .audio, let url = recorder.outputURL { return url.deletingPathExtension().lastPathComponent }
        return "开始录制后自动命名"
    }
    private var destinationURL: URL {
        if mode == .audio, let url = recorder.outputURL { return url.deletingLastPathComponent() }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Movies/Scriber/\(mode == .audio ? "录音" : "录屏")", directoryHint: .isDirectory)
    }
    private var destinationPath: String {
        (destinationURL.path as NSString).abbreviatingWithTildeInPath
    }
    private func sourceRow(_ source: AudioSource) -> some View {
        let name = source == .system ? "电脑声音" : "麦克风"
        return PanelSourceRow(name: name, symbol: source == .system ? "display" : "mic",
                              tint: source == .system ? PanelPalette.iris : PanelPalette.jade,
                              enabled: Binding(get: { recorder.sources.contains(source) }, set: { enabled in
                                  var selected = recorder.sources
                                  if enabled { selected.insert(source) } else { selected.remove(source) }
                                  Task { await recorder.setSources(selected) }
                              }), status: recorder.sourceStatus(source),
                              powerDB: recorder.sourcePower(source),
                              toggleHelp: source == .microphone ? "切换麦克风 · \(recorder.microphoneName)" : "切换电脑声音",
                              canToggle: recorder.canChangeSources)
    }
    private var statusColor: Color {
        if recorder.state == .failed { return PanelPalette.record }
        if recorder.isRecording { return PanelPalette.record }
        if mode == .audio, recorder.state == .completed { return PanelPalette.jade }
        return PanelPalette.slate
    }
    private var statusText: String {
        if mode == .video { return "录屏暂不可用" }
        return switch recorder.state {
        case .idle: "准备录音"
        case .authorizing: "等待录制权限"
        case .recording: "正在录音"
        case .finishing: "正在保存"
        case .completed: "已保存"
        case .failed: "录制未完成"
        }
    }
}

enum RecordingMode: String, CaseIterable {
    case audio, video
    var title: String { self == .audio ? "录音" : "录屏" }
    var symbol: String { self == .audio ? "mic" : "display" }
}
