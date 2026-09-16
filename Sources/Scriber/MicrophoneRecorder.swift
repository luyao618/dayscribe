import AVFoundation
import Combine
import Foundation

@MainActor
final class MicrophoneRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum Phase { case idle, authorizing, recording, finishing, saved, failed }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var powerDB: Float = -160
    @Published private(set) var peakDB: Float = -160
    @Published private(set) var outputURL: URL?
    @Published private(set) var errorMessage: String?
    var onCompletion: ((String?) -> Void)?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase == .authorizing || phase == .finishing }
    var elapsedText: String {
        let seconds = Int(elapsed)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    func start(directory: URL? = nil, duration: TimeInterval? = nil) async {
        guard !isRecording, !isBusy else { return }
        if let duration, !duration.isFinite || duration <= 0 {
            fail("录音时长必须是大于零的有限数值。")
            return
        }
        phase = .authorizing
        errorMessage = nil
        outputURL = nil
        elapsed = 0
        powerDB = -160
        peakDB = -160

        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
        default: authorized = false
        }
        guard authorized else {
            fail("麦克风权限未开启。请在系统设置 → 隐私与安全性 → 麦克风中允许 Scriber。")
            return
        }

        do {
            let folder = directory ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Movies/Scriber/录音", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX")
            date.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let name = "录音 \(date.string(from: Date())) \(UUID().uuidString.prefix(4)).m4a"
            let url = folder.appendingPathComponent(name)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let audio = try AVAudioRecorder(url: url, settings: settings)
            audio.delegate = self
            audio.isMeteringEnabled = true
            guard audio.prepareToRecord() else { throw CaptureError.startFailed }
            recorder = audio
            outputURL = url
            let started = duration.map { audio.record(forDuration: $0) } ?? audio.record()
            guard started else { throw CaptureError.startFailed }
            phase = .recording
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMeters() }
            }
            meterTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            recorder?.stop()
            recorder = nil
            fail(error.localizedDescription)
        }
    }

    func stop() {
        guard isRecording else { return }
        updateMeters()
        phase = .finishing
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
    }

    private func updateMeters() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        elapsed = max(elapsed, recorder.currentTime)
        powerDB = recorder.averagePower(forChannel: 0)
        peakDB = max(peakDB, recorder.peakPower(forChannel: 0))
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let active = self.recorder, ObjectIdentifier(active) == identity,
                  self.phase == .recording || self.phase == .finishing else { return }
            self.phase = .finishing
            self.meterTimer?.invalidate()
            self.meterTimer = nil
            self.recorder = nil
            self.powerDB = -160
            if flag {
                if let url = self.outputURL,
                   let duration = try? await AVURLAsset(url: url).load(.duration),
                   duration.seconds.isFinite {
                    self.elapsed = duration.seconds
                }
                self.phase = .saved
                self.onCompletion?(nil)
            } else {
                self.fail("录音没有正常完成，请检查已保存的文件。")
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let message = error?.localizedDescription ?? "音频编码失败。"
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let active = self.recorder, ObjectIdentifier(active) == identity else { return }
            self.fail(message)
        }
    }

    private func fail(_ message: String) {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        powerDB = -160
        errorMessage = message
        phase = .failed
        onCompletion?(message)
    }
}

private enum CaptureError: LocalizedError {
    case startFailed
    var errorDescription: String? { "无法开始录音，请检查当前麦克风设备。" }
}
