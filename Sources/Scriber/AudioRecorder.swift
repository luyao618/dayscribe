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
    @Published private(set) var audioDevices: AudioDeviceSnapshot?
    @Published private(set) var deviceReadError: String?
    @Published private(set) var sourceFailures: [AudioSource: String] = [:]
    @Published private(set) var recoveringSources: Set<AudioSource> = []
    @Published private(set) var recoveryNotice: String?
    private(set) var reconnectCounts: [AudioSource: Int] = [:]
    @Published private(set) var recordingTitle = ""
    @Published private(set) var destinationDirectories: [RecordingMode: URL] = [:]
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
    private(set) var microphoneDeviceID: String?
    private var deviceMonitor: AudioDeviceMonitor?
    private var pendingSourceFailures: [AudioSource: (SCStream, String)] = [:]
    private var sourceFailureHistory: [AudioSource: String] = [:]
    private var sourceStartTimes: [AudioSource: Double] = [:]
    private var recoveryPolicy = AudioRecoveryPolicy()
    private var followsDefaultMicrophone = true
    private var observedDevices: AudioDeviceSnapshot?
    private let defaults: UserDefaults?
    private var sessionFiles: RecordingSessionFiles?
    private var sessionLease: RecordingSessionLease?
    private var storageMonitor: Task<Void, Never>?
    private let readStorage: @Sendable (URL) throws -> RecordingStorage
    private(set) var availableStorageBytes: UInt64?
    private let historyStore: RecordingHistoryStore?
    var sessionID: UUID? { sessionFiles?.id }

    init(defaults: UserDefaults? = nil, historyStore: RecordingHistoryStore? = nil,
         readStorage: @escaping @Sendable (URL) throws -> RecordingStorage = { try RecordingStorage.read($0) }) {
        self.defaults = defaults
        self.historyStore = historyStore
        self.readStorage = readStorage
        super.init()
        destinationDirectories = Dictionary(uniqueKeysWithValues: RecordingMode.allCases.map {
            ($0, RecordingDestination.restored(from: defaults, for: $0))
        })
        let mask = (defaults?.object(forKey: "recordingSources") as? Int ?? 3) & 3
        sources = Set(AudioSource.allCases.filter { (mask == 0 ? 3 : mask) & (1 << $0.rawValue) != 0 })
        deviceMonitor = AudioDeviceMonitor { [weak self] reading in
            self?.updateAudioDevices(reading)
        }
    }

    var microphoneName: String { sourceDeviceName(.microphone) }

    func sourceDeviceName(_ source: AudioSource) -> String {
        guard deviceReadError == nil else { return "设备状态未知" }
        guard let audioDevices else { return "正在识别设备" }
        if source == .system { return audioDevices.defaultOutput?.name ?? "无默认输出设备" }
        let uid = state.active ? microphoneDeviceID : nil
        return audioDevices.microphone(uid: uid)?.name ?? (uid == nil ? "无可用麦克风" : "麦克风已断开")
    }

    func sourceDeviceHelp(_ source: AudioSource) -> String {
        if let failure = sourceFailures[source], sources.contains(source) { return failure }
        if let deviceReadError { return deviceReadError }
        let name = sourceDeviceName(source)
        if source == .system { return "系统默认输出：\(name)；电脑声音采集系统播放的声音。" }
        if state.active, let selected = microphoneDeviceID, let next = audioDevices?.defaultInput,
           selected != next.uid {
            return "本次麦克风：\(name)；系统默认已改为 \(next.name)。"
        }
        return "\(state.active ? "本次麦克风" : "系统默认输入")：\(name)"
    }

    private func updateAudioDevices(_ reading: AudioDeviceMonitor.Reading) {
        switch reading {
        case .success(let snapshot): audioDevices = snapshot; deviceReadError = nil
        case .failure(let error): deviceReadError = error.localizedDescription
        }
        onUpdate?()
    }

    var isRecording: Bool { state == .recording }
    var sourceFailureMessage: String? {
        guard isRecording else { return nil }
        if !recoveringSources.isEmpty { return "正在重新连接声音设备…" }
        guard !sourceFailures.isEmpty else { return recoveryNotice }
        if sources.allSatisfy({ sourceFailures[$0] != nil }) { return "声音采集中断，正在尝试恢复。" }
        let failed = AudioSource.allCases.filter { sourceFailures[$0] != nil }
            .map { $0 == .system ? "电脑声音" : "麦克风" }.joined(separator: "、")
        return "\(failed)采集中断，其余声音继续录制。"
    }
    var isBusy: Bool { state == .authorizing || state == .finishing }
    var elapsedText: String {
        let seconds = Int(summary?.duration ?? 0)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    var canChangeSources: Bool { !isBusy && !isChangingSources && (!isRecording || (summary?.frames ?? 0) > 0) }

    func sourcePower(_ source: AudioSource) -> Float? {
        guard isRecording, sources.contains(source),
              sourceFailures[source] == nil,
              !recoveringSources.contains(source),
              let last = captureMetrics.lastTimes[source],
              CMClockGetTime(CMClockGetHostTimeClock()).seconds - last < 1 else { return nil }
        return captureMetrics.powerDBFS[source]
    }

    func sourceStatus(_ source: AudioSource) -> String {
        guard sources.contains(source) else { return "已关闭" }
        if recoveringSources.contains(source) { return "正在重连" }
        if sourceFailures[source] != nil { return "采集中断" }
        if isChangingSources && recoveringSources.isEmpty { return "正在切换" }
        if state == .failed { return "录音异常" }
        if isBusy { return state == .authorizing ? "等待授权" : "正在保存" }
        guard isRecording else { return "未录制" }
        guard let power = sourcePower(source) else { return "等待声音数据" }
        return power > -65 ? "已检测到声音" : "等待声音"
    }

    func reportControlMessage(_ message: String?) { controlMessage = message }

    func destination(for mode: RecordingMode) -> URL {
        destinationDirectories[mode] ?? RecordingDestination.defaultURL(for: mode)
    }

    func setDestination(_ url: URL, for mode: RecordingMode) async throws {
        let checked = try await Task.detached { try RecordingDestination.validate(url) }.value
        destinationDirectories[mode] = checked
        defaults?.set(checked.path, forKey: mode.directoryPreferenceKey)
        onUpdate?()
    }

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
        guard state == .completed || state == .failed, let sessionFiles else { return false }
        let previousState = state
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
        state = previousState
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
            sourceFailures = sourceFailures.filter { selected.contains($0.key) }
            recoveryNotice = nil
            saveSourcePreference()
            return true
        }
        guard let output, let captureFilter else { return false }
        guard selected.contains(where: { sourceFailures[$0] == nil }) else {
            controlMessage = "另一路声音尚未恢复，请保留仍在工作的声音来源。"
            return false
        }
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
        let added = selected.subtracting(sources)
        // Prepare additions while the old mix and streams remain live. Only
        // commit the new selection once each new stream delivers real data.
        do {
            for source in added {
                if source == .microphone, followsDefaultMicrophone {
                    microphoneDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
                }
                try await startSource(source, output: output, filter: captureFilter)
                guard generation == token, isRecording else { return false }
                try await waitForSource(source, output: output, token: token)
            }
        } catch {
            guard generation == token, isRecording else { return false }
            for source in added {
                let capture = streams.removeValue(forKey: source)
                await output.retire(source)
                if let capture { try? await capture.stopCapture() }
                guard generation == token, isRecording else { return false }
            }
            controlMessage = "无法开启新的声音来源，原有录制继续：\(error.localizedDescription)"
            return false
        }
        do {
            try await output.prepareSources(selected, at: CMClockGetTime(CMClockGetHostTimeClock()))
            guard generation == token, isRecording else { return false }
            for source in sources.subtracting(selected) {
                if let capture = streams.removeValue(forKey: source) { try await capture.stopCapture() }
                guard generation == token, isRecording else { return false }
            }
            try await output.completeSources(selected)
            guard generation == token, isRecording else { return false }
            sources = selected
            sourceFailures = sourceFailures.filter { selected.contains($0.key) }
            recoveryNotice = nil
            for source in AudioSource.allCases where !selected.contains(source) || added.contains(source) {
                recoveryPolicy.reset(source)
            }
            captureMetrics = await output.snapshot()
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
        if source == .microphone {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw AudioSourceConnectionError(message: "麦克风权限未开启。")
            }
            guard let uid = microphoneDeviceID, AVCaptureDevice(uniqueID: uid)?.isConnected == true else {
                throw AudioSourceConnectionError(message: "麦克风设备不可用。")
            }
        }
        let capture = SCStream(filter: filter,
                               configuration: Self.configuration(sources: [source], microphoneDeviceID: microphoneDeviceID),
                               delegate: self)
        try capture.addStreamOutput(output, type: source == .system ? .audio : .microphone,
                                    sampleHandlerQueue: output.writer.queue)
        streams[source] = capture
        sourceStartTimes[source] = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        await output.bind(source, to: ObjectIdentifier(capture))
        guard streams[source] === capture else { return }
        try await capture.startCapture()
        if streams[source] !== capture { try? await capture.stopCapture() }
    }

    private func waitForSource(_ source: AudioSource, output: MixedAudioOutput, token: UUID) async throws {
        guard let capture = streams[source] else { throw AudioSourceConnectionError(message: "声音采集未启动。") }
        let deadline = ContinuousClock.now + .milliseconds(750)
        while ContinuousClock.now < deadline {
            let metrics = await output.snapshot()
            guard generation == token, isRecording, streams[source] === capture else { throw CancellationError() }
            if let message = metrics.errorMessage { throw AudioSourceConnectionError(message: message) }
            if let failure = pendingSourceFailures[source], failure.0 === capture {
                throw AudioSourceConnectionError(message: failure.1)
            }
            if let last = metrics.lastTimes[source], last >= sourceStartTimes[source, default: .infinity] - 0.1 {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw AudioSourceConnectionError(message: "重新连接后未收到声音数据。")
    }

    private func saveSourcePreference() {
        defaults?.set(sources.reduce(0) { $0 | (1 << $1.rawValue) }, forKey: "recordingSources")
    }

    func start(directory: URL? = nil, sources selection: Set<AudioSource>? = nil, microphoneDeviceID: String? = nil,
               recordScreen recordVideo: Bool = false, captureRequest: CaptureRequest? = nil, title: String? = nil) async {
        let recordScreen = recordVideo || captureRequest != nil
        guard !state.active else { return }
        let folder = directory ?? destination(for: recordScreen ? .video : .audio)
        let sources = selection ?? self.sources
        let token = UUID()
        generation = token
        interrupted = false
        controlMessage = nil
        captureMetrics = AudioCaptureMetrics()
        sourceFailures = [:]
        sourceFailureHistory = [:]
        pendingSourceFailures = [:]
        sourceStartTimes = [:]
        recoveryPolicy = AudioRecoveryPolicy()
        reconnectCounts = [:]
        recoveringSources = []
        recoveryNotice = nil
        followsDefaultMicrophone = microphoneDeviceID == nil
        observedDevices = audioDevices
        self.sources = sources
        self.microphoneDeviceID = microphoneDeviceID ?? AVCaptureDevice.default(for: .audio)?.uniqueID
        summary = nil
        errorMessage = nil
        outputURL = nil
        videoURL = nil
        recordingTitle = ""
        recordingDirectory = folder
        sessionFiles = nil
        availableStorageBytes = nil
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
            let reading = readStorage
            let initialStorage = try await Task.detached {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let result = try reading(folder)
                try result.validate(video: recordScreen)
                return result
            }.value
            guard generation == token, state == .authorizing else { return }
            availableStorageBytes = initialStorage.availableBytes
            if sources.contains(.microphone) {
                let authorized: Bool
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: authorized = true
                case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
                default: authorized = false
                }
                guard generation == token, state == .authorizing else { return }
                if !authorized {
                    let message = "请在系统设置 → 隐私与安全性 → 麦克风中允许 Scriber。"
                    guard sources.contains(.system) else { throw AudioWriteError.encoding(message) }
                    sourceFailures[.microphone] = message
                    sourceFailureHistory[.microphone] = message
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
            let desiredTitle = recordingTitle
            let owned = try await Task.detached {
                // Authorization can take time; recheck immediately before opening
                // the session, including that the selected volume is unchanged.
                try reading(folder).validate(video: recordScreen, expectedVolume: initialStorage.volumeID)
                return try RecordingSessionFiles.begin(directory: folder, title: desiredTitle, video: recordScreen)
            }.value
            guard generation == token, state == .authorizing else { return }
            let session = owned.session
            sessionLease = owned.lease
            sessionFiles = session
            if let historyStore {
                try await historyStore.register(.init(session: session, title: desiredTitle))
                guard generation == token, state == .authorizing else { return }
            }
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
                if sourceFailures[source] != nil { await handler.retire(source) }
                else {
                    do { try await startSource(source, output: handler, filter: filter) }
                    catch {
                        guard generation == token, state == .authorizing else { return }
                        await isolateSource(source, message: Self.captureMessage(error), output: handler)
                    }
                }
                guard generation == token, state == .authorizing else { return }
            }
            guard !streams.isEmpty else { throw AudioWriteError.encoding("所选声音来源均无法采集。") }
            state = .recording
            monitorStorage(directory: session.stagingDirectory, video: recordScreen, volume: initialStorage.volumeID, token: token)
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
                    await self.checkSourceFailures()
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
        let sourceErrors = AudioSource.allCases.compactMap { sourceFailureHistory[$0] }.joined(separator: "\n")
        let messages = [error, sourceErrors.isEmpty ? nil : "录制期间有声音中断。\n" + sourceErrors].compactMap { $0 }
        errorMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
        state = .finishing
        progress?.cancel()
        progress = nil
        storageMonitor?.cancel()
        storageMonitor = nil
        onUpdate?()
        let activeStreams = Array(streams.values)
        streams.removeAll()
        pendingSourceFailures.removeAll()
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
            let duration = summary?.duration
            let captureError = errorMessage
            let finished = await Task.detached {
                sessionFiles.finalize(title: title, closed: closed, duration: duration, captureError: captureError)
            }.value
            applyFileFinalization(finished)
            if let message = finished.errorMessage {
                errorMessage = [errorMessage, message].compactMap { $0 }.joined(separator: "\n")
            }
        }
        if videoURL != nil, audioSaved != videoSaved {
            let saved = audioSaved ? "音频已保存，视频未完成。" : "视频已保存，音频未完成。"
            errorMessage = saved + (errorMessage ?? "")
        }
        sessionLease?.release()
        sessionLease = nil
        state = errorMessage == nil ? .completed : .failed
        updateRecentFiles()
        onUpdate?()
    }

    private func applyFileFinalization(_ result: RecordingSessionFiles.Finalization) {
        // A failed rename can return only the published subset supplied by the
        // caller; retain the known locations of unfinished companion files.
        outputURL = result.files.urls[.audio] ?? outputURL
        videoURL = result.files.urls[.video] ?? videoURL
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

    private func monitorStorage(directory: URL, video: Bool, volume: String, token: UUID) {
        let reading = readStorage
        storageMonitor = Task { [weak self] in
            while !Task.isCancelled {
                let result = await Task.detached(priority: .utility) { Result { try reading(directory) } }.value
                guard !Task.isCancelled, let self, self.generation == token, self.isRecording else { return }
                do {
                    let storage = try result.get()
                    self.availableStorageBytes = storage.availableBytes
                    try storage.validate(video: video, expectedVolume: volume)
                } catch {
                    await self.stop(error: error.localizedDescription)
                    return
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
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
        let message = Self.captureMessage(error)
        let reference = CaptureStreamReference(stream)
        Task { @MainActor [weak self, reference] in
            // Retain the callback's stream until it is compared, so a new
            // stream cannot reuse the old object's address in the meantime.
            let stream = reference.stream
            guard let self else { return }
            if self.videoStream === stream {
                await self.stop(error: message)
            } else if let source = self.streams.first(where: { $0.value === stream })?.key {
                self.pendingSourceFailures[source] = (stream, message)
            }
        }
    }

    /// Stop a real stream through the diagnostic entry point, exercising the
    /// same isolation path as a stream failure without changing system devices.
    func interruptSourceForDiagnostic(_ source: AudioSource, reportFailure: Bool = true) async {
        guard isRecording, let capture = streams[source] else { return }
        try? await capture.stopCapture()
        guard isRecording, streams[source] === capture else { return }
        if reportFailure { pendingSourceFailures[source] = (capture, "诊断中停止了采集流。") }
    }

    private func checkSourceFailures() async {
        guard isRecording, !isChangingSources, let output else { return }
        let token = generation
        checkDeviceChanges()
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        for (source, capture) in streams {
            let last = captureMetrics.lastTimes[source] ?? sourceStartTimes[source] ?? now
            if now - last > 1 {
                pendingSourceFailures[source] = (capture, "超过 1 秒未收到声音数据。")
            } else if captureMetrics.lastTimes[source] != nil, pendingSourceFailures[source] == nil {
                recoveryPolicy.received(source, at: last)
            }
        }
        let missing = sources.filter { streams[$0] == nil && sourceFailures[$0] != nil }
        guard !pendingSourceFailures.isEmpty || missing.contains(where: { recoveryPolicy.canAttempt($0, at: now) })
                || streams.isEmpty else { return }
        isChangingSources = true
        defer { isChangingSources = false; recoveringSources = []; onUpdate?() }
        let failures = pendingSourceFailures
        pendingSourceFailures.removeAll()
        for (source, (capture, message)) in failures {
            guard streams[source] === capture else { continue }
            await isolateSource(source, message: message, output: output)
            guard generation == token, isRecording else { return }
        }
        for source in AudioSource.allCases where sources.contains(source) && streams[source] == nil {
            guard recoveryPolicy.beginAttempt(source, at: CMClockGetTime(CMClockGetHostTimeClock()).seconds),
                  let captureFilter else { continue }
            recoveringSources.insert(source)
            reconnectCounts[source, default: 0] += 1
            onUpdate?()
            do {
                if source == .microphone {
                    microphoneDeviceID = audioDevices.map {
                        AudioRecoveryPolicy.microphoneTarget(snapshot: $0, selected: microphoneDeviceID,
                                                             followsDefault: followsDefaultMicrophone)
                    } ?? AVCaptureDevice.default(for: .audio)?.uniqueID
                }
                try await startSource(source, output: output, filter: captureFilter)
                guard generation == token, isRecording else { return }
                try await waitForSource(source, output: output, token: token)
                guard generation == token, isRecording else { return }
                sourceFailures[source] = nil
                if let previous = sourceFailureHistory[source] { sourceFailureHistory[source] = previous + "（已恢复）" }
                recoveryNotice = source == .microphone ? "麦克风已恢复：\(microphoneName)" : "电脑声音已恢复。"
            } catch {
                guard generation == token, isRecording else { return }
                await isolateSource(source, message: "重连失败：\(error.localizedDescription)", output: output)
                guard generation == token, isRecording else { return }
            }
            recoveringSources.remove(source)
        }
        captureMetrics = await output.snapshot()
        guard generation == token, isRecording else { return }
        if streams.isEmpty, sources.allSatisfy({ recoveryPolicy.exhausted($0) }) {
            await stop(error: "所有声音来源均无法恢复，录制已结束。")
        }
    }

    private func checkDeviceChanges() {
        guard deviceReadError == nil, let current = audioDevices, current != observedDevices else { return }
        let previous = observedDevices
        observedDevices = current
        if let previous {
            if current.defaultOutput?.uid != previous.defaultOutput?.uid || current.defaultOutput?.id != previous.defaultOutput?.id {
                recoveryPolicy.reset(.system)
                recoveryNotice = "系统输出已改为：\(current.defaultOutput?.name ?? "无可用设备")"
            }
            if current.defaultInput?.uid != previous.defaultInput?.uid || current.defaultInput?.id != previous.defaultInput?.id ||
                current.microphone(uid: microphoneDeviceID)?.id != previous.microphone(uid: microphoneDeviceID)?.id {
                recoveryPolicy.reset(.microphone)
            }
        }
        guard sources.contains(.microphone), let capture = streams[.microphone] else { return }
        let target = AudioRecoveryPolicy.microphoneTarget(snapshot: current, selected: microphoneDeviceID,
                                                          followsDefault: followsDefaultMicrophone)
        if current.microphone(uid: microphoneDeviceID) == nil || (target != nil && target != microphoneDeviceID) {
            pendingSourceFailures[.microphone] = (capture, "系统输入设备已变化。")
        }
    }

    private func isolateSource(_ source: AudioSource, message: String, output: MixedAudioOutput) async {
        let name = source == .system ? "电脑声音" : "麦克风"
        sourceFailures[source] = "\(name)：\(message)"
        sourceFailureHistory[source] = sourceFailures[source]
        sourceStartTimes[source] = nil
        let capture = streams.removeValue(forKey: source)
        await output.retire(source)
        if let capture { try? await capture.stopCapture() }
        onUpdate?()
    }

    private nonisolated static func captureMessage(_ error: any Error) -> String {
        let error = error as NSError
        if error.domain == SCStreamErrorDomain, error.code == SCStreamError.Code.userDeclined.rawValue {
            return "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 Scriber，然后重启应用重试。"
        }
        return error.localizedDescription
    }
}

// Transfer only a retained reference from the SCK callback for identity checks.
// All stream operations stay on AudioRecorder's main actor.
private final class CaptureStreamReference: @unchecked Sendable {
    let stream: SCStream
    init(_ stream: SCStream) { self.stream = stream }
}
