import AVKit
import SwiftUI

struct RecordingDetailPanel: View {
    @ObservedObject var playback: RecordingPlaybackModel
    let onBack: () -> Void
    let onReveal: (UUID, RecordingFileKind) -> Void
    var allowsRename = true
    var onRename: ((UUID, String) async -> String?)? = nil
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var nameError: String?
    @State private var savingName = false
    @FocusState private var nameFocused: Bool

    private var canRename: Bool {
        guard allowsRename, onRename != nil, !playback.isLoading, let entry = playback.entry,
              let manifest = entry.manifest, !manifest.published.isEmpty else { return false }
        return manifest.published.allSatisfy { key in
            guard let kind = RecordingFileKind(rawValue: key) else { return false }
            return entry.fileStates[kind] == .available
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button { playback.close(); onBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(PanelIconButtonStyle()).accessibilityLabel("返回录制历史")
                Text("录制详情").font(.system(size: 18, weight: .semibold))
                Spacer()
            }
            if editingName {
                HStack(spacing: 8) {
                    TextField("录制名称", text: $nameDraft).textFieldStyle(.plain).autocorrectionDisabled()
                        .focused($nameFocused).accessibilityLabel("历史录制名称")
                        .onSubmit { Task { await saveName() } }
                        .onExitCommand { editingName = false; nameError = nil }
                        .onAppear { DispatchQueue.main.async { nameFocused = true } }
                    Button { Task { await saveName() } } label: { Image(systemName: "checkmark") }
                        .buttonStyle(.plain).accessibilityLabel("确认历史名称")
                }
                .font(.system(size: 17, weight: .semibold)).padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 7))
            } else {
                Button {
                    playback.pause()
                    nameDraft = playback.entry?.title ?? ""
                    nameError = nil
                    nameFocused = false
                    editingName = true
                } label: {
                    HStack(spacing: 8) {
                        Text(playback.entry?.title ?? (playback.isLoading ? "正在读取录制…" : "录制不可用"))
                            .font(.system(size: 17, weight: .semibold)).lineLimit(2)
                        Spacer(minLength: 0)
                        Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(PanelPalette.slate)
                    }
                }
                .buttonStyle(.plain).disabled(!canRename)
                .accessibilityLabel("修改历史名称").accessibilityValue(playback.entry?.title ?? "")
            }
            if let nameError {
                Text(nameError).font(.system(size: 11)).foregroundStyle(PanelPalette.record)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if savingName { Text("正在改名…").font(.system(size: 11)).foregroundStyle(PanelPalette.slate) }
            if let entry = playback.entry {
                Text(RecordingHistoryModel.dateText(entry.reference.startedAt))
                    .font(.system(size: 11)).foregroundStyle(PanelPalette.slate)
            }
            Group {
                if playback.selectedKind == .video {
                    RecordedVideoView(player: playback.player)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform").font(.system(size: 32)).foregroundStyle(PanelPalette.jade)
                        Text(playback.selectedKind == nil ? "暂无可播放文件" : "音频预览")
                            .font(.system(size: 12)).foregroundStyle(PanelPalette.slate)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(PanelPalette.jade.opacity(0.05))
                }
            }
            .frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 8) {
                Button { Task { await playback.togglePlayback() } } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(PanelIconButtonStyle())
                .disabled(!playback.canPlay || playback.isSeeking)
                .accessibilityLabel(playback.isPlaying ? "暂停播放" : "播放录制")
                Text(RecordingHistoryModel.durationText(playback.position))
                Slider(value: Binding(get: { playback.position }, set: { playback.seek(to: $0) }),
                       in: 0...max(playback.duration, 0.001))
                    .tint(PanelPalette.iris).disabled(!playback.canPlay)
                    .accessibilityLabel("播放进度")
                Text(RecordingHistoryModel.durationText(playback.duration > 0 ? playback.duration : nil))
            }
            .font(.system(size: 9, design: .monospaced)).foregroundStyle(PanelPalette.slate)
            if playback.isLoading {
                Text("正在加载…").font(.system(size: 11)).foregroundStyle(PanelPalette.slate)
            }
            if let error = playback.errorMessage ?? playback.entry?.issue {
                Text(error).font(.system(size: 11)).foregroundStyle(PanelPalette.record)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("文件").font(.system(size: 11, weight: .semibold)).foregroundStyle(PanelPalette.slate)
            if let entry = playback.entry {
                ForEach([RecordingFileKind.video, .audio], id: \.self) { kind in
                    if let url = entry.urls[kind] {
                        HStack(spacing: 9) {
                            Button { playback.open(entry.id, kind: kind) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: kind == .video ? "video" : "waveform")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(kind == .video ? "MP4 视频" : "M4A 音频").fontWeight(.medium)
                                        Text(url.lastPathComponent).font(.system(size: 10))
                                            .foregroundStyle(PanelPalette.slate).lineLimit(1).truncationMode(.middle)
                                        if entry.fileStates[kind] != .available {
                                            Text(fileStatus(entry.fileStates[kind]))
                                                .font(.system(size: 10)).foregroundStyle(PanelPalette.record)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if playback.selectedKind == kind { Image(systemName: "checkmark") }
                                }
                                .foregroundStyle(PanelPalette.ink).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(entry.fileStates[kind] != .available || playback.isLoading)
                            .accessibilityLabel(kind == .video ? "选择视频预览" : "选择音频预览")
                            Button { onReveal(entry.id, kind) } label: { Image(systemName: "folder") }
                                .buttonStyle(PanelIconButtonStyle()).accessibilityLabel(kind == .video ? "定位视频文件" : "定位音频文件")
                                .disabled(entry.fileStates[kind] != .available)
                        }
                        .font(.system(size: 12)).padding(.vertical, 5)
                        .help(url.path)
                    }
                }
            }
        }
        .padding(20)
        .disabled(savingName)
        .onReceive(NotificationCenter.default.publisher(for: .scriberPanelClosing)) { _ in
            editingName = false; nameError = nil; nameFocused = false
        }
    }

    private func saveName() async {
        guard !savingName, let id = playback.entry?.id, let onRename else { return }
        do {
            let title = try RecordingFilename.validated(nameDraft)
            savingName = true
            defer { savingName = false }
            nameError = await onRename(id, title)
            if nameError == nil { editingName = false }
        } catch { nameError = error.localizedDescription }
    }

    private func fileStatus(_ state: RecordingHistoryEntry.FileState?) -> String {
        switch state {
        case .missing: "文件已移动或删除"
        case .unfinished: "尚未完成写入"
        default: "文件无法访问"
        }
    }
}

private struct RecordedVideoView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
