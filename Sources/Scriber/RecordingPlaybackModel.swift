import AVFoundation
import Combine

@MainActor
final class RecordingPlaybackModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var entry: RecordingHistoryEntry?
    @Published private(set) var selectedKind: RecordingFileKind?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isSeeking = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?
    var onUpdate: (() -> Void)?
    private let store: RecordingHistoryStore?
    private var generation = UUID()
    private var playRequest = UUID()
    private var seekRequest = UUID()
    private var monitor: Task<Void, Never>?
    private var loadingTask: Task<Void, Never>?
    private var monitoringEnabled = true
    private var loadedURL: URL?
    private var toggling = false

    init(store: RecordingHistoryStore? = nil) { self.store = store }
    deinit { monitor?.cancel(); loadingTask?.cancel() }
    var canPlay: Bool { !isLoading && duration > 0 && player.currentItem?.status == .readyToPlay }

    @discardableResult
    func open(_ id: UUID, kind: RecordingFileKind? = nil) -> Task<Void, Never> {
        close()
        let token = generation
        isLoading = true
        onUpdate?()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.prepare(id, kind: kind, token: token)
        }
        loadingTask = task
        return task
    }

    private func prepare(_ id: UUID, kind: RecordingFileKind?, token: UUID) async {
        do {
            guard let fresh = try await store?.entry(id) else { throw PlaybackError.unavailable }
            guard generation == token else { return }
            entry = fresh
            let selected = kind ?? ([.video, .audio] as [RecordingFileKind]).first { fresh.fileStates[$0] == .available }
            guard let selected, fresh.fileStates[selected] == .available, let url = fresh.urls[selected] else {
                throw PlaybackError.unavailable
            }
            selectedKind = selected
            let asset = AVURLAsset(url: url)
            let (time, playable) = try await asset.load(.duration, .isPlayable)
            guard generation == token else { return }
            guard playable, time.isNumeric, time.seconds.isFinite, time.seconds > 0 else { throw PlaybackError.invalidMedia }
            duration = time.seconds
            loadedURL = url
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            if monitoringEnabled { startMonitor() } else { _ = updateStatus(token) }
        } catch {
            guard generation == token else { return }
            isLoading = false
            errorMessage = error.localizedDescription
            onUpdate?()
        }
    }

    func togglePlayback() async {
        if isPlaying { pause(); return }
        guard !isLoading, !isSeeking, !toggling, monitoringEnabled, player.currentItem?.status == .readyToPlay,
              let id = entry?.id, let kind = selectedKind, loadedURL != nil else { return }
        toggling = true
        let token = generation
        let request = UUID()
        playRequest = request
        defer { if generation == token { toggling = false } }
        do {
            guard let fresh = try await store?.entry(id), fresh.fileStates[kind] == .available,
                  fresh.urls[kind] == loadedURL else { throw PlaybackError.unavailable }
            guard generation == token, playRequest == request, monitoringEnabled else { return }
            entry = fresh
            if position >= duration - 0.02 {
                let completed = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                guard generation == token, playRequest == request, monitoringEnabled else { return }
                guard completed else { throw PlaybackError.seekFailed }
            }
            errorMessage = nil
            player.play()
            isPlaying = true
            onUpdate?()
        } catch {
            guard generation == token, playRequest == request else { return }
            pause()
            errorMessage = error.localizedDescription
            onUpdate?()
        }
    }

    func seek(to seconds: Double) {
        guard !isLoading, duration > 0, seconds.isFinite, player.currentItem?.status == .readyToPlay else { return }
        let requested = min(duration, max(0, seconds))
        let token = generation
        let request = UUID()
        seekRequest = request
        isSeeking = true
        player.seek(to: CMTime(seconds: requested, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.seekRequest == request else { return }
                self.isSeeking = false
                self.errorMessage = completed ? nil : PlaybackError.seekFailed.localizedDescription
                _ = self.updateStatus(token)
            }
        }
    }

    func pause() {
        playRequest = UUID()
        player.pause()
        isPlaying = false
        onUpdate?()
    }

    func suspend() {
        monitoringEnabled = false
        pause()
        monitor?.cancel()
        monitor = nil
    }

    func resume() {
        monitoringEnabled = true
        if player.currentItem != nil { startMonitor() }
    }

    func close() {
        generation = UUID()
        loadingTask?.cancel()
        loadingTask = nil
        pause()
        monitor?.cancel()
        monitor = nil
        player.replaceCurrentItem(with: nil)
        entry = nil
        selectedKind = nil
        loadedURL = nil
        position = 0
        duration = 0
        isLoading = false
        isSeeking = false
        toggling = false
        errorMessage = nil
        onUpdate?()
    }

    private func startMonitor() {
        monitor?.cancel()
        let token = generation
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.updateStatus(token) == true else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private func updateStatus(_ token: UUID) -> Bool {
        guard generation == token, let item = player.currentItem else { return false }
        if item.status == .failed {
            pause()
            isLoading = false
            errorMessage = item.error?.localizedDescription ?? PlaybackError.invalidMedia.localizedDescription
            onUpdate?()
            return false
        }
        isLoading = item.status != .readyToPlay
        let current = player.currentTime().seconds
        if !isSeeking, current.isFinite { position = min(duration, max(0, current)) }
        isPlaying = player.timeControlStatus != .paused
        onUpdate?()
        return true
    }
}

private enum PlaybackError: LocalizedError {
    case unavailable, invalidMedia, seekFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: "文件尚未完成写入、已移动或无法访问，请刷新记录后重试。"
        case .invalidMedia: "无法播放这个文件，文件可能尚未完成或已损坏。"
        case .seekFailed: "无法定位到该播放位置，请重试。"
        }
    }
}
