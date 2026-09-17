import AppKit
import SwiftUI

extension Notification.Name {
    static let scriberPanelClosing = Notification.Name("scriber.panelClosing")
}

struct RecorderPanel: View {
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var history = RecordingHistoryModel()
    @ObservedObject var playback = RecordingPlaybackModel()
    @State var mode = RecordingMode.audio
    @State private var showsSettings = false
    let onQuit: () -> Void
    var onStartVideo: ((CaptureKind, String?) async -> Void)? = nil
    var onChooseDirectory: ((RecordingMode) async -> Void)? = nil
    var onRefreshHistory: (() -> Void)? = nil
    var onRevealHistory: ((UUID, RecordingFileKind?) -> Void)? = nil
    @State var captureKind = CaptureKind.region
    @State private var showsCaptureKinds = false
    @State private var isSelecting = false
    @State private var pendingTitles: [RecordingMode: String] = [:]
    @State private var isEditingName = false
    @State private var nameDraft = ""
    @State private var nameError: String?
    @FocusState private var nameFocused: Bool
    @State private var showsDestinations = false
    @State private var showsHistory = false
    @State private var detailID: UUID?
    @State private var historyQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            if detailID != nil {
                RecordingDetailPanel(playback: playback, onBack: { detailID = nil; showsHistory = true },
                                     onReveal: { onRevealHistory?($0, $1) })
            } else if showsHistory {
                RecordingHistoryPanel(history: history, recorder: recorder, onBack: { showsHistory = false },
                                      onRefresh: { onRefreshHistory?() }, onOpen: openDetail,
                                      onReveal: { onRevealHistory?($0, nil) }, query: $historyQuery)
            } else if showsDestinations {
                RecordingDestinationsPanel(recorder: recorder, onBack: { showsDestinations = false },
                                           onChoose: onChooseDirectory)
            } else {
                header
                VStack(spacing: 0) {
                    modePicker
                    summary
                    if mode == .video { captureTarget }
                    sources
                    destination
                    if let error = recorder.controlMessage ?? recorder.errorMessage {
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
        }
        .foregroundStyle(PanelPalette.ink)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
        .background(PanelPalette.pearl)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.7)))
        .onReceive(NotificationCenter.default.publisher(for: .scriberPanelClosing)) { _ in
            // A transient NSPopover consumes Escape before the field can receive it.
            isEditingName = false
            nameFocused = false
            nameError = nil
        }
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
                Button { historyQuery = ""; showsHistory = true; onRefreshHistory?() } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(PanelIconButtonStyle())
                    .disabled(!history.isAvailable)
                    .help("查看录制历史")
                    .accessibilityLabel("录制历史")
                Button { showsSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(PanelIconButtonStyle())
                    .help("设置")
                    .accessibilityLabel("设置")
                    .popover(isPresented: $showsSettings) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("设置").font(.headline)
                            Button("保存位置设置") { showsSettings = false; showsDestinations = true }
                                .disabled(onChooseDirectory == nil)
                            Text("快捷键设置暂不可用")
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
                .disabled(recorder.state.active || isSelecting || isEditingName)
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
            if isEditingName {
                HStack(spacing: 8) {
                    TextField("录制文件名", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.center)
                        .focused($nameFocused)
                        .accessibilityLabel("录制文件名")
                        .onSubmit { Task { await applyName() } }
                        .onExitCommand { isEditingName = false; nameError = nil }
                        .onAppear { DispatchQueue.main.async { nameFocused = true } }
                    Button { Task { await applyName() } } label: {
                        Image(systemName: "checkmark").foregroundStyle(PanelPalette.iris)
                    }
                    .buttonStyle(.plain).accessibilityLabel("确认文件名")
                }
                .font(.system(size: 13, weight: .medium))
                .frame(width: 260, height: 27)
                .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
                .disabled(recorder.isBusy)
            } else {
                Button {
                    nameDraft = matchesRecordingMode && !recorder.recordingTitle.isEmpty
                        ? recorder.recordingTitle : pendingTitles[mode] ?? ""
                    nameError = nil
                    nameFocused = false
                    isEditingName = true
                } label: {
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
                .disabled(recorder.isBusy || isSelecting || (matchesRecordingMode && recorder.state == .failed))
                .help("修改文件名，回车确认，Esc 取消；重名会自动编号")
                .accessibilityLabel("修改文件名")
                .accessibilityValue(filename)
            }
            if let nameError {
                Text(nameError).font(.system(size: 10)).foregroundStyle(PanelPalette.record)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 19)
        .padding(.bottom, 16)
    }

    private var captureTarget: some View {
        Button { showsCaptureKinds.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: captureKind.symbol).foregroundStyle(PanelPalette.iris)
                Text(recorder.isRecording ? recorder.captureTargetTitle : captureKind.title)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(recorder.isRecording ? "录制中" : "开始前选择")
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.slate)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .font(.system(size: 11))
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(PanelPalette.iris.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PanelPalette.iris.opacity(0.09)))
        }
        .buttonStyle(.plain)
        .disabled(recorder.state.active || isSelecting)
        .accessibilityLabel("录屏范围：\(captureKind.title)")
        .popover(isPresented: $showsCaptureKinds) {
            VStack(spacing: 2) {
                ForEach(CaptureKind.allCases, id: \.self) { kind in
                    Button { captureKind = kind; showsCaptureKinds = false } label: {
                        HStack(spacing: 10) {
                            Image(systemName: kind.symbol).frame(width: 18)
                            Text(kind.title)
                            Spacer()
                            if captureKind == kind { Image(systemName: "checkmark").foregroundStyle(PanelPalette.iris) }
                        }
                        .font(.system(size: 12)).padding(10).frame(width: 170)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
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
        Button { showsDestinations = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 16))
                    .foregroundStyle(PanelPalette.slate)
                    .frame(width: 29, height: 29)
                    .background(PanelPalette.track, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(destinationCaption).font(.system(size: 10))
                    Text(destinationPath).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    if hasPendingDestination {
                        Text("新位置从下次录制生效").font(.system(size: 9)).foregroundStyle(PanelPalette.iris)
                    }
                }
                .foregroundStyle(PanelPalette.slate)
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Text("更改")
                    Image(systemName: "chevron.right").font(.system(size: 8))
                }
                .font(.system(size: 10)).foregroundStyle(PanelPalette.slate)
            }
            .frame(height: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onChooseDirectory == nil || recorder.isBusy || isSelecting)
        .accessibilityLabel("更改保存位置")
        .accessibilityValue("\(destinationCaption)：\(destinationPath)\(hasPendingDestination ? "，新位置从下次录制生效" : "")")
        .help(destinationURL.path)
    }

    private var primaryAction: some View {
        Button {
            Task {
                if isEditingName, !(await applyName()), !recorder.isRecording { return }
                if recorder.isRecording { await recorder.stop() }
                else {
                    if mode == .video {
                        isSelecting = true
                        defer { isSelecting = false }
                        await onStartVideo?(captureKind, pendingTitles[mode])
                    } else { await recorder.start(title: pendingTitles[mode]) }
                }
            }
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: recorder.isRecording ? 2 : 5)
                    .frame(width: 10, height: 10)
                Text(actionTitle)
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
        .disabled(recorder.isBusy || isSelecting || (mode == .video && onStartVideo == nil && !recorder.isRecording))
        .help(mode == .video ? "选择录制范围，保存视频和独立音频" : "录制已开启的声音来源")
    }

    @discardableResult
    private func applyName() async -> Bool {
        guard !recorder.isBusy else { return false }
        do {
            let title = try RecordingFilename.validated(nameDraft)
            if matchesRecordingMode && recorder.isRecording {
                guard recorder.setRecordingTitle(title) else { return false }
            } else if matchesRecordingMode && recorder.state == .completed {
                guard await recorder.renameSavedRecording(title) else {
                    nameError = recorder.controlMessage
                    return false
                }
            }
            pendingTitles[mode] = title
            isEditingName = false
            nameError = nil
            return true
        } catch {
            nameError = error.localizedDescription + (recorder.isRecording ? " 当前仍使用「\(recorder.recordingTitle)」。" : "")
            return false
        }
    }

    private var actionTitle: String {
        if isSelecting { return "正在选择范围…" }
        return switch recorder.state {
        case .authorizing: "正在准备…"
        case .finishing: "正在保存…"
        case .recording: "停止并保存"
        default: mode == .audio ? "开始录音" : "选择范围并录屏"
        }
    }

    private var recentRecording: some View {
        VStack(spacing: 0) {
            Rectangle().fill(PanelPalette.line).frame(height: 1)
                .padding(.bottom, 13)
            HStack {
                Text("最近录制").fontWeight(.semibold)
                Spacer()
                Button("查看全部 ›") { historyQuery = ""; showsHistory = true; onRefreshHistory?() }
                    .buttonStyle(.plain).disabled(!history.isAvailable)
                    .help("查看录制历史")
            }
            .font(.system(size: 11))
            .foregroundStyle(PanelPalette.slate)
            .padding(.bottom, 9)
            if let entry = history.entries.first(where: { $0.fileStates.values.contains(.available) }) {
                RecordingHistoryRow(entry: entry, recorder: recorder, onOpen: { openDetail(entry.id) }) { onRevealHistory?(entry.id, nil) }
            } else if let url = recorder.lastSavedURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(recorder.lastSavedFiles)
                } label: {
                    HStack(spacing: 10) {
                        recordingIcon
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                            Text(recorder.lastSavedFiles.count == 2 ? "MP4 + M4A · 在 Finder 中显示" :
                                    (url.pathExtension == "mp4" ? "MP4 视频 · 在 Finder 中显示" : "M4A 音频 · 在 Finder 中显示"))
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
                .help("在 Finder 中显示已保存的文件")
            } else {
                HStack(spacing: 10) {
                    recordingIcon
                    Text(history.errorMessage == nil ? "录制完成后，文件会显示在这里" : "历史暂时无法读取，请打开历史查看")
                        .font(.system(size: 11)).foregroundStyle(PanelPalette.slate)
                    Spacer()
                }
                .frame(height: 45)
            }
        }
        .padding(.top, 17)
    }

    private func openDetail(_ id: UUID) {
        if !showsHistory { historyQuery = "" }
        detailID = id
        playback.open(id)
    }

    private var recordingIcon: some View {
        let video = recorder.lastSavedURL?.pathExtension == "mp4"
        let tint = video ? PanelPalette.iris : PanelPalette.jade
        return Image(systemName: video ? "video" : "waveform")
            .font(.system(size: 16)).foregroundStyle(tint.opacity(0.8))
            .frame(width: 31, height: 31)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var matchesRecordingMode: Bool { (mode == .video) == (recorder.videoURL != nil) }
    private var clockText: String { matchesRecordingMode ? recorder.elapsedText : "00:00:00" }
    private var filename: String {
        if matchesRecordingMode, !recorder.recordingTitle.isEmpty { return recorder.recordingTitle }
        return pendingTitles[mode] ?? "开始录制后自动命名"
    }
    private var destinationURL: URL {
        if matchesRecordingMode, recorder.state.active, let url = recorder.recordingDirectory { return url }
        return recorder.destination(for: mode)
    }
    private var destinationPath: String {
        (destinationURL.path as NSString).abbreviatingWithTildeInPath
    }
    private var hasPendingDestination: Bool {
        recorder.state.active && destinationURL != recorder.destination(for: mode)
    }
    private var destinationCaption: String {
        if recorder.state.active { return "本次保存到" }
        if matchesRecordingMode, let previous = recorder.recordingDirectory,
           previous != recorder.destination(for: mode) { return "下次保存到" }
        return "保存到"
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
                              canToggle: recorder.canChangeSources && !isSelecting)
    }
    private var statusColor: Color {
        if recorder.state == .failed { return PanelPalette.record }
        if recorder.isRecording { return PanelPalette.record }
        if matchesRecordingMode, recorder.state == .completed { return PanelPalette.jade }
        return PanelPalette.slate
    }
    private var statusText: String {
        if isSelecting { return "选择录屏范围" }
        if !matchesRecordingMode { return mode == .video ? "准备录屏" : "准备录音" }
        return switch recorder.state {
        case .idle: mode == .video ? "准备录屏" : "准备录音"
        case .authorizing: "等待录制权限"
        case .recording: mode == .video ? "正在录屏" : "正在录音"
        case .finishing: "正在保存"
        case .completed: "已保存"
        case .failed: "录制未完成"
        }
    }
}
