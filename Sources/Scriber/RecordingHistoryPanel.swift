import SwiftUI

struct RecordingHistoryPanel: View {
    @ObservedObject var history: RecordingHistoryModel
    @ObservedObject var recorder: AudioRecorder
    let onBack: () -> Void
    let onRefresh: () -> Void
    let onOpen: (UUID) -> Void
    let onReveal: (UUID) -> Void
    @Binding var query: String

    private var filtered: [RecordingHistoryEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return history.entries.filter { text.isEmpty || $0.title.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .buttonStyle(PanelIconButtonStyle()).accessibilityLabel("返回录制面板")
                Text("录制历史").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text("\(history.entries.count) 条").font(.system(size: 11)).foregroundStyle(PanelPalette.slate)
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(PanelIconButtonStyle()).disabled(history.isLoading).accessibilityLabel("刷新历史")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(PanelPalette.slate)
                TextField("搜索录制名称", text: $query)
                    .textFieldStyle(.plain).autocorrectionDisabled().accessibilityLabel("搜索录制名称")
            }
            .font(.system(size: 12)).padding(11)
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
            if let message = history.errorMessage ?? history.discoveryMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(PanelPalette.record)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if history.isLoading {
                Text("正在读取…").font(.system(size: 11)).foregroundStyle(PanelPalette.slate)
            }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(filtered) { entry in
                        RecordingHistoryRow(entry: entry, recorder: recorder, onOpen: { onOpen(entry.id) }) { onReveal(entry.id) }
                        Rectangle().fill(PanelPalette.line).frame(height: 1)
                    }
                    if filtered.isEmpty, !history.isLoading, history.errorMessage == nil {
                        Text(history.entries.isEmpty ? "还没有录制，完成后会显示在这里。" : "没有找到匹配的录制")
                            .font(.system(size: 12)).foregroundStyle(PanelPalette.slate)
                            .padding(.vertical, 35)
                    }
                }
            }
            .frame(height: 365)
        }
        .padding(20)
    }
}

struct RecordingHistoryRow: View {
    let entry: RecordingHistoryEntry
    @ObservedObject var recorder: AudioRecorder
    var onOpen: (() -> Void)? = nil
    let onReveal: () -> Void
    private var live: Bool { recorder.sessionID == entry.id && recorder.state.active }
    private var video: Bool { entry.manifest?.paths["mp4"] != nil }
    private var title: String { live ? recorder.recordingTitle : entry.title }
    private var canReveal: Bool { entry.fileStates.values.contains(.available) || entry.fileStates.values.contains(.unfinished) }
    private var status: String {
        if live {
            return switch recorder.state {
            case .authorizing: "准备录制"
            case .finishing: "正在保存"
            default: "录制中"
            }
        }
        if entry.manifest == nil { return "记录无法读取" }
        if entry.manifest?.recovery?.completedAt != nil, entry.manifest?.published.isEmpty == false {
            if entry.manifest?.published.count != entry.manifest?.paths.count { return "部分已恢复" }
            if !entry.fileStates.values.contains(.missing) && !entry.fileStates.values.contains(.unavailable) {
                return video ? "已恢复 · MP4 + M4A" : "已恢复 · M4A 音频"
            }
        }
        if entry.manifest?.published.count != entry.manifest?.paths.count { return "未完整保存" }
        if entry.fileStates.values.contains(.missing) || entry.fileStates.values.contains(.unavailable) { return "文件缺失或无法访问" }
        if entry.issue != nil { return "保存时出现问题" }
        return video ? "MP4 + M4A" : "M4A 音频"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { onOpen?() } label: { content }
                .buttonStyle(.plain).disabled(onOpen == nil)
                .accessibilityLabel("查看录制：\(title)")
                .accessibilityValue("\(status)，\(live ? recorder.elapsedText : RecordingHistoryModel.durationText(entry.duration))")
            Button(action: onReveal) { Image(systemName: "folder") }
                .buttonStyle(PanelIconButtonStyle()).disabled(!canReveal)
                .accessibilityLabel("定位录制：\(title)")
                .help("在 Finder 中显示这次录制的文件")
        }
        .frame(minHeight: 53)
        .help(entry.issue ?? status)
    }

    private var content: some View {
        HStack(spacing: 10) {
            let tint = video ? PanelPalette.iris : PanelPalette.jade
            Image(systemName: entry.manifest == nil ? "doc.questionmark" : (video ? "video" : "waveform"))
                .font(.system(size: 16)).foregroundStyle(tint.opacity(0.8))
                .frame(width: 31, height: 31)
                .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text("\(RecordingHistoryModel.dateText(entry.reference.startedAt)) · \(status)")
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.slate).lineLimit(1)
            }
            Spacer(minLength: 2)
            Text(live ? recorder.elapsedText : RecordingHistoryModel.durationText(entry.duration))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(PanelPalette.slate)
            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(PanelPalette.muted)
        }
        .contentShape(Rectangle())
    }
}
