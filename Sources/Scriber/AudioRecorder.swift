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
            case .authorizing: "等待屏幕与系统音频权限"
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
    @Published private(set) var sources: Set<AudioSource> = [.system]
    private(set) var outputURL: URL?
    private(set) var interrupted = false
    var onUpdate: (() -> Void)?

    private var stream: SCStream?
    private var output: MixedAudioOutput?
    private var writer: AudioSampleWriter?
    private var progress: Task<Void, Never>?
    private var generation = UUID()

    func start(directory: URL, sources: Set<AudioSource> = [.system], microphoneDeviceID: String? = nil) async {
        guard !state.active else { return }
        let token = UUID()
        generation = token
        interrupted = false
        captureMetrics = AudioCaptureMetrics()
        self.sources = sources
        summary = nil
        errorMessage = nil
        outputURL = nil
        state = .authorizing
        onUpdate?()
        do {
            guard !sources.isEmpty else { throw AudioMixError.invalidConfiguration }
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
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("录音 \(UUID().uuidString).m4a")
            let sink = try AudioSampleWriter(url: url)
            writer = sink
            outputURL = url
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = sources.contains(.system)
            configuration.captureMicrophone = sources.contains(.microphone)
            configuration.microphoneCaptureDeviceID = microphoneDeviceID
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = false
            // No screen samples are retained or encoded for audio-only capture.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3
            let handler = try MixedAudioOutput(writer: sink, sources: sources)
            let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
            if sources.contains(.system) {
                try capture.addStreamOutput(handler, type: .audio, sampleHandlerQueue: sink.queue)
            }
            if sources.contains(.microphone) {
                try capture.addStreamOutput(handler, type: .microphone, sampleHandlerQueue: sink.queue)
            }
            output = handler
            stream = capture
            try await capture.startCapture()
            guard generation == token, state == .authorizing else {
                try? await capture.stopCapture()
                return
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
        generation = UUID()
        self.interrupted = interrupted
        errorMessage = error
        state = .finishing
        progress?.cancel()
        progress = nil
        onUpdate?()
        if let stream {
            do { try await stream.stopCapture() }
            catch { if errorMessage == nil { errorMessage = error.localizedDescription } }
        }
        stream = nil
        if let output {
            do { try await output.finish() }
            catch { if errorMessage == nil { errorMessage = error.localizedDescription } }
            captureMetrics = await output.snapshot()
        }
        output = nil
        if let writer {
            do { summary = try await writer.finish() }
            catch {
                summary = await writer.snapshot().0
                if errorMessage == nil { errorMessage = error.localizedDescription }
            }
        } else if errorMessage == nil {
            errorMessage = "采集在音频开始前结束。"
        }
        writer = nil
        state = errorMessage == nil ? .completed : .failed
        onUpdate?()
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let identity = ObjectIdentifier(stream)
        let message = Self.captureMessage(error)
        Task { @MainActor [weak self] in
            guard let self, let active = self.stream, ObjectIdentifier(active) == identity else { return }
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
