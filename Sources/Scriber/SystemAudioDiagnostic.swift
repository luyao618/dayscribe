import Foundation

@MainActor
final class SystemAudioDiagnostic {
    let recorder = SystemAudioRecorder()
    private let directory: URL
    private let seconds: Double
    private let onStatus: (String) -> Void
    private let onFinished: () -> Void
    private var timer: Task<Void, Never>?
    private var sentCompletion = false
    private let clock = ContinuousClock()
    private var started: ContinuousClock.Instant?

    init(directory: URL, seconds: Double, onStatus: @escaping (String) -> Void,
         onFinished: @escaping () -> Void) {
        self.directory = directory
        self.seconds = seconds
        self.onStatus = onStatus
        self.onFinished = onFinished
    }

    func start() {
        recorder.onUpdate = { [weak self] in self?.publish() }
        timer = Task { [weak self] in
            guard let self else { return }
            await recorder.start(directory: directory)
            guard recorder.state == .recording, !Task.isCancelled else { return }
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            await recorder.stop()
        }
    }

    func stop() async {
        timer?.cancel()
        await recorder.stop(interrupted: true)
    }

    private func publish() {
        guard !sentCompletion else { return }
        if recorder.state == .recording, started == nil { started = clock.now }
        let wall = started.map { instant in
            let duration = instant.duration(to: clock.now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        } ?? 0
        let finished = recorder.state == .completed || recorder.state == .failed
        let status = finished && recorder.interrupted ? "interrupted" : recorder.state.rawValue
        let result: [String: Any] = [
            "status": status,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "path": recorder.outputURL?.path ?? "",
            "error": recorder.errorMessage ?? "",
            "frames": recorder.summary?.frames ?? 0,
            "durationSeconds": recorder.summary?.duration ?? 0,
            "wallElapsedSeconds": wall,
            "requestedDurationSeconds": seconds,
            "powerDBFS": recorder.summary?.powerDBFS ?? -160,
            "peakDBFS": recorder.summary?.peakDBFS ?? -160
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
            if finished { try data.write(to: directory.appendingPathComponent("result.json"), options: .atomic) }
        } catch {
            NSLog("System-audio diagnostic write failed: %@", error.localizedDescription)
        }
        onStatus(recorder.state.active ? String(format: " 电脑声音 %.0fs", wall) : "")
        if finished {
            sentCompletion = true
            timer?.cancel()
            timer = nil
            onFinished()
        }
    }
}
