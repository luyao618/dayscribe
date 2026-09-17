import AVFoundation
import Combine
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class AudioRecorder: NSObject, ObservableObject, SCStreamDelegate {
    enum State: String {
        case idle, authorizing, recording, finishing, completed, failed
        var active: Bool { self == .authorizing || self == .recording || self == .finishing }
        var title: String {
            switch self {
            case .idle: "未录制"
            case .authorizing: "等待录制权限"
            case .recording: "正在录音"
            case .finishing: "正在保存"
            case .completed: "已保存"
            case .failed: "采集未完成"
            }
        }
    }
    @Published private(set) var state = State.idle
    @Published private(set) var summary: AudioWriteSummary?
    @Published private(set) var errorMessage: String?
    @Published private(set) var captureMetrics = AudioCaptureMetrics()
    @Published private(set) var sources: Set<AudioSource> = [.system, .microphone]
    @Published private(set) var isChangingSources = false
    @Published private(set) var controlMessage: String?
    @Published private(set) var lastSavedURL: URL?
    @Published private(set) var lastSavedFiles: [URL] = []
    @Published private(set) var lastSavedDuration = ""
    @Published private(set) var microphoneName = "默认麦克风"
    @Published private(set) var recordingTitle = ""
    private(set) var recordingDirectory: URL?
    private(set) var outputURL: URL?
    private(set) var videoURL: URL?
    private(set) var videoSummary: VideoWriteSummary?
    private(set) var videoEpochHostTime: Double?
    private(set) var captureTargetTitle = ""
    private(set) var videoMetrics = ScreenVideoMetrics()
    private(set) var audioSaved = false
    private(set) var videoSaved = false
    private var videoStream: SCStream?
    private var videoOutput: ScreenVideoOutput?
    private(set) var interrupted = false
    var onUpdate: (() -> Void)?

    private var streams: [AudioSource: SCStream] = [:]
    private var output: MixedAudioOutput?
    private var writer: AudioSampleWriter?
    private var progress: Task<Void, Never>?
    private var generation = UUID()
    private var captureFilter: SCContentFilter?
    private var microphoneDeviceID: String?
    private let defaults: UserDefaults?
    private var sessionFiles: RecordingSessionFiles?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        super.init()
        let mask = (defaults?.object(forKey: "recordingSources") as? Int ?? 3) & 3
        sources = Set(AudioSource.allCases.filter { (mask == 0 ? 3 : mask) & (1 << $0.rawValue) != 0 })
        microphoneName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "默认麦克风"
    }

    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .authorizing || state == .finishing }
    var elapsedText: String {
        let seconds = Int(summary?.duration ?? 0)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    var canChangeSources: Bool { !isBusy && !isChangingSources && (!isRecording || (summary?.frames ?? 0) > 0) }

    func sourcePower(_ source: AudioSource) -> Float? {
        guard isRecording, sources.contains(source),
              let last = captureMetrics.lastTimes[source],
              CMClockGetTime(CMClockGetHostTimeClock()).seconds - last < 1 else { return nil }
        return captureMetrics.powerDBFS[source]
    }

    func sourceStatus(_ source: AudioSource) -> String {
        guard sources.contains(source) else { return "已关闭" }
        if isChangingSources { return "正在切换" }
        if state == .failed { return "录音异常" }
        if isBusy { return state == .authorizing ? "等待授权" : "正在保存" }
        guard isRecording else { return "未录制" }
        guard let power = sourcePower(source) else { return "等待声音数据" }
        return power > -65 ? "已检测到声音" : "等待声音"
    }

    func reportControlMessage(_ message: String?) { controlMessage = message }

    /// Only changes the desired final basename; open encoder URLs never move.
    @discardableResult
    func setRecordingTitle(_ title: String) -> Bool {
        guard isRecording else { controlMessage = "当前无法修改录制名称。"; return false }
        do {
            recordingTitle = try RecordingFilename.validated(title)
            controlMessage = nil
            onUpdate?()
            return true
        } catch {
            controlMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func renameSavedRecording(_ title: String) async -> Bool {
        guard state == .completed, let sessionFiles else { return false }
        do { _ = try RecordingFilename.validated(title) }
        catch { controlMessage = error.localizedDescription; return false }
        let files = RecordingFileSet(urls: Dictionary(uniqueKeysWithValues:
            [(RecordingFileKind.audio, audioSaved ? outputURL : nil), (.video, videoSaved ? videoURL : nil)]
                .compactMap { kind, url in url.map { (kind, $0) } }))
        state = .finishing
        controlMessage = nil
        onUpdate?()
        let result = await Task.detached { sessionFiles.renamePublished(files, title: title) }.value
        applyFileFinalization(result)
        controlMessage = result.errorMessage
        state = .completed
        updateRecentFiles()
        onUpdate?()
        return result.errorMessage == nil
    }

    @discardableResult
    func setSources(_ selected: Set<AudioSource>) async -> Bool {
        controlMessage = nil
        guard !selected.isEmpty else { controlMessage = "至少保留一路声音。"; return false }
        guard canChangeSources else { controlMessage = "声音正在准备，请稍候。"; return false }
        guard selected != sources else { return true }
        if !state.active {
            sources = selected
            saveSourcePreference()
            return true
        }
        guard let output, let captureFilter else { return false }
        let token = generation
        isChangingSources = true
        defer { isChangingSources = false; onUpdate?() }
        if selected.contains(.microphone), !sources.contains(.microphone) {
            let authorized = AVCaptureDevice.authorizationStatus(for: .audio)
            let allowed = authorized == .notDetermined
                ? await AVCaptureDevice.requestAccess(for: .audio) : authorized == .authorized
            guard generation == token, isRecording else { return false }
            guard allowed else { controlMessage = "麦克风权限未开启，当前录音继续。"; return false }
        }
        do {
            try await output.prepareSources(selected, at: CMClockGetTime(CMClockGetHostTimeClock()))
            guard generation == token, isRecording else { return false }
            for source in selected.subtracting(sources) {
                try await startSource(source, output: output, filter: captureFilter)
                guard generation == token, isRecording else { return false }
            }
            for source in sources.subtracting(selected) {
                if let capture = streams.removeValue(forKey: source) { try await capture.stopCapture() }
                guard generation == token, isRecording else { return false }
            }
            try await output.completeSources(selected)
            guard generation == token, isRecording else { return false }
            sources = selected
            captureMetrics = await output.snapshot()
            updateMicrophoneName(microphoneDeviceID)
            saveSourcePreference()
            return true
        } catch {
            guard generation == token, isRecording else { return false }
            await stop(error: "无法切换声音来源：\(error.localizedDescription)")
            return false
        }
    }

    private static func configuration(sources: Set<AudioSource>, microphoneDeviceID: String?) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = sources.contains(.system)
        configuration.captureMicrophone = sources.contains(.microphone)
        configuration.microphoneCaptureDeviceID = sources.contains(.microphone)
            ? (microphoneDeviceID ?? AVCaptureDevice.default(for: .audio)?.uniqueID) : nil
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = false
        // No screen samples are retained or encoded for audio-only capture.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        return configuration
    }

    // Separate streams make microphone off an actual stop. On this macOS,
    // updating captureMicrophone=false alone still delivered live microphone PCM.
    private func startSource(_ source: AudioSource, output: MixedAudioOutput, filter: SCContentFilter) async throws {
        let capture = SCStream(filter: filter,
                               configuration: Self.configuration(sources: [source], microphoneDeviceID: microphoneDeviceID),
                               delegate: self)
        try capture.addStreamOutput(output, type: source == .system ? .audio : .microphone,
                                    sampleHandlerQueue: output.writer.queue)
        streams[source] = capture
        try await capture.startCapture()
        if streams[source] !== capture { try? await capture.stopCapture() }
    }

    private func saveSourcePreference() {
        defaults?.set(sources.reduce(0) { $0 | (1 << $1.rawValue) }, forKey: "recordingSources")
    }

    private func updateMicrophoneName(_ id: String?) {
        microphoneName = id.map { AVCaptureDevice(uniqueID: $0)?.localizedName ?? "所选麦克风" }
            ?? AVCaptureDevice.default(for: .audio)?.localizedName ?? "默认麦克风"
    }

    func start(directory: URL? = nil, sources selection: Set<AudioSource>? = nil, microphoneDeviceID: String? = nil,
               recordScreen recordVideo: Bool = false, captureRequest: CaptureRequest? = nil, title: String? = nil) async {
        let recordScreen = recordVideo || captureRequest != nil
        guard !state.active else { return }
        let sources = selection ?? self.sources
        let token = UUID()
        generation = token
        interrupted = false
        controlMessage = nil
        captureMetrics = AudioCaptureMetrics()
        self.sources = sources
        self.microphoneDeviceID = microphoneDeviceID ?? AVCaptureDevice.default(for: .audio)?.uniqueID
        updateMicrophoneName(self.microphoneDeviceID)
        summary = nil
        errorMessage = nil
        outputURL = nil
        videoURL = nil
        recordingTitle = ""
        recordingDirectory = nil
        sessionFiles = nil
        videoSummary = nil
        videoEpochHostTime = nil
        captureTargetTitle = ""
        videoMetrics = ScreenVideoMetrics()
        audioSaved = false
        videoSaved = false
        state = .authorizing
        onUpdate?()
        do {
            guard !sources.isEmpty else { throw AudioMixError.invalidConfiguration }
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX")
            date.dateFormat = "yyyy-MM-dd HH.mm.ss"
            recordingTitle = try RecordingFilename.validated(title ?? "\(recordScreen ? "录屏" : "录音") \(date.string(from: Date()))")
            if sources.contains(.microphone) {
                let authorized: Bool
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: authorized = true
                case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
                default: authorized = false
                }
                guard generation == token, state == .authorizing else { return }
                guard authorized else {
                    throw AudioWriteError.encoding("请在系统设置 → 隐私与安全性 → 麦克风中允许 Scriber。")
                }
            }
            if !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
                throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard generation == token, state == .authorizing else { return }
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else {
                throw AudioWriteError.encoding("没有可用的显示器。")
            }
            let folder = directory ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Movies/Scriber/\(recordScreen ? "录屏" : "录音")", directoryHint: .isDirectory)
            let desiredTitle = recordingTitle
            let session = try await Task.detached {
                try RecordingSessionFiles.create(directory: folder, title: desiredTitle, video: recordScreen)
            }.value
            guard generation == token, state == .authorizing else { return }
            sessionFiles = session
            recordingDirectory = session.directory
            let url = session.files.urls[.audio]!
            let sink = try AudioSampleWriter(url: url)
            writer = sink
            outputURL = url
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            var screen: ScreenVideoOutput?
            if recordScreen {
                let videoURL = session.files.urls[.video]!
                self.videoURL = videoURL
                let target = try CaptureTarget.resolve(captureRequest ?? .display(display.displayID), content: content)
                captureTargetTitle = target.title
                let configuration = try target.configuration()
                let encoder = try VideoSampleWriter(url: videoURL, width: configuration.width,
                                                     height: configuration.height, queue: sink.queue)
                let captureEpoch = CMClockGetTime(CMClockGetHostTimeClock())
                videoEpochHostTime = captureEpoch.seconds
                let screenOutput = ScreenVideoOutput(writer: encoder, epoch: captureEpoch)
                screen = screenOutput
                videoOutput = screenOutput
                let capture = SCStream(filter: target.filter, configuration: configuration, delegate: self)
                videoStream = capture
                try capture.addStreamOutput(screenOutput, type: .screen, sampleHandlerQueue: sink.queue)
                try await capture.startCapture()
                guard generation == token, state == .authorizing else {
                    try? await capture.stopCapture()
                    return
                }
            }
            let handler = try MixedAudioOutput(writer: sink, sources: sources, epoch: screen?.epoch,
                                               onMixedSample: screen.map { screen in
                { sample in
                    // Video failure must not discard a still-writable standalone audio file.
                    try? screen.writer.appendAudio(sample)
                }
            })
            output = handler
            captureFilter = filter
            for source in AudioSource.allCases where sources.contains(source) {
                try await startSource(source, output: handler, filter: filter)
                guard generation == token, state == .authorizing else { return }
            }
            state = .recording
            onUpdate?()
            progress = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.state == .recording else { return }
                    let (metrics, error) = await sink.snapshot()
                    guard self.state == .recording else { return }
                    self.summary = metrics
                    self.captureMetrics = await handler.snapshot()
                    guard self.state == .recording else { return }
                    if let videoOutput = self.videoOutput {
                        let (videoSummary, videoError) = await videoOutput.writer.snapshot()
                        self.videoSummary = videoSummary
                        self.videoMetrics = await videoOutput.snapshot()
                        guard self.state == .recording else { return }
                        if let message = self.videoMetrics.error ?? videoError?.localizedDescription {
                            await self.stop(error: message); return
                        }
                    }
                    self.onUpdate?()
                    if let message = self.captureMetrics.errorMessage { await self.stop(error: message); return }
                    if let error { await self.stop(error: error.localizedDescription); return }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        } catch {
            guard generation == token else { return }
            await stop(error: Self.captureMessage(error))
        }
    }

    func stop(interrupted: Bool = false, error: String? = nil) async {
        guard state.active, state != .finishing else { return }
        controlMessage = nil
        generation = UUID()
        self.interrupted = interrupted
        errorMessage = error
        state = .finishing
        progress?.cancel()
        progress = nil
        onUpdate?()
        let activeStreams = Array(streams.values)
        streams.removeAll()
        captureFilter = nil
        if let capture = videoStream {
            videoStream = nil
            await videoOutput?.prepareStop()
            do { try await capture.stopCapture() }
            catch { if errorMessage == nil { errorMessage = error.localizedDescription } }
        }
        for capture in activeStreams {
            do { try await capture.stopCapture() }
            catch { if errorMessage == nil { errorMessage = error.localizedDescription } }
        }
        let captureEnd = videoOutput.map { screen in
            screen.epoch + (CMClockGetTime(CMClockGetHostTimeClock()) - screen.epoch)
                .convertScale(48_000, method: .roundTowardZero)
        }
        if let output {
            do { try await output.finish(at: captureEnd) }
            catch { if errorMessage == nil { errorMessage = error.localizedDescription } }
            captureMetrics = await output.snapshot()
        }
        output = nil
        if let writer {
            do { summary = try await writer.finish(); audioSaved = true }
            catch {
                summary = await writer.snapshot().0
                if errorMessage == nil { errorMessage = error.localizedDescription }
            }
        } else if errorMessage == nil {
            errorMessage = "采集在音频开始前结束。"
        }
        writer = nil
        if let videoOutput, let captureEnd {
            do { videoSummary = try await videoOutput.finish(at: captureEnd); videoSaved = true }
            catch {
                videoSummary = await videoOutput.writer.snapshot().0
                if errorMessage == nil { errorMessage = error.localizedDescription }
            }
            videoMetrics = await videoOutput.snapshot()
        }
        videoOutput = nil
        if let sessionFiles {
            let title = recordingTitle
            var closed = Set<RecordingFileKind>()
            if audioSaved { closed.insert(.audio) }
            if videoSaved { closed.insert(.video) }
            let finished = await Task.detached { sessionFiles.finalize(title: title, closed: closed) }.value
            applyFileFinalization(finished)
            if let message = finished.errorMessage {
                errorMessage = [errorMessage, message].compactMap { $0 }.joined(separator: "\n")
            }
        }
        if videoURL != nil, audioSaved != videoSaved {
            let saved = audioSaved ? "音频已保存，视频未完成。" : "视频已保存，音频未完成。"
            errorMessage = saved + (errorMessage ?? "")
        }
        state = errorMessage == nil ? .completed : .failed
        updateRecentFiles()
        onUpdate?()
    }

    private func applyFileFinalization(_ result: RecordingSessionFiles.Finalization) {
        outputURL = result.files.urls[.audio]
        videoURL = result.files.urls[.video]
        recordingTitle = result.title
        audioSaved = result.published.contains(.audio)
        videoSaved = result.published.contains(.video)
        if let summary, let outputURL {
            self.summary = .init(url: outputURL, frames: summary.frames, duration: summary.duration,
                                 powerDBFS: summary.powerDBFS, peakDBFS: summary.peakDBFS)
        }
        if let videoSummary, let videoURL {
            self.videoSummary = .init(url: videoURL, videoFrames: videoSummary.videoFrames,
                                      audioFrames: videoSummary.audioFrames, duration: videoSummary.duration)
        }
    }

    private func updateRecentFiles() {
        if audioSaved || videoSaved {
            lastSavedURL = videoSaved ? videoURL : outputURL
            lastSavedFiles = [(videoSaved ? videoURL : nil), (audioSaved ? outputURL : nil)].compactMap { $0 }
            lastSavedDuration = elapsedText
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let identity = ObjectIdentifier(stream)
        let message = Self.captureMessage(error)
        Task { @MainActor [weak self] in
            guard let self, (self.streams.values.contains(where: { ObjectIdentifier($0) == identity })
                              || self.videoStream.map({ ObjectIdentifier($0) == identity }) == true) else { return }
            await self.stop(error: message)
        }
    }

    private nonisolated static func captureMessage(_ error: any Error) -> String {
        let error = error as NSError
        if error.domain == SCStreamErrorDomain, error.code == SCStreamError.Code.userDeclined.rawValue {
            return "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 Scriber，然后重启应用重试。"
        }
        return error.localizedDescription
    }
}
