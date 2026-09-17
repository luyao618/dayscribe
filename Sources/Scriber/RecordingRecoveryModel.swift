import Combine
import Foundation

@MainActor
final class RecordingRecoveryModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentTitle = ""
    @Published private(set) var currentID: UUID?
    @Published private(set) var recoveredCount = 0
    @Published private(set) var issueCount = 0
    @Published private(set) var busyCount = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasChecked = false
    var onUpdate: (() -> Void)?
    private let store: RecordingHistoryStore?
    private let recover: @Sendable (URL) async throws -> SessionRecovery.Result
    private var directories = Set<URL>()
    private var task: Task<Void, Never>?
    private var wantsRun = false
    private var shuttingDown = false
    private var recoveredIDs = Set<UUID>()

    init(store: RecordingHistoryStore? = nil,
         recover: @escaping @Sendable (URL) async throws -> SessionRecovery.Result = { try await SessionRecovery.recover(manifestURL: $0) }) {
        self.store = store
        self.recover = recover
    }

    var message: String? {
        if let errorMessage { return errorMessage }
        if isPaused && wantsRun { return "录制期间已暂停恢复检查。" }
        if isRunning { return currentTitle.isEmpty ? "正在检查未完成的录制…" : "正在恢复：\(currentTitle)" }
        if issueCount > 0 { return "已恢复 \(recoveredCount) 条录制，另有 \(issueCount) 条需要查看。" }
        if busyCount > 0 { return "有 \(busyCount) 条录制仍在使用，稍后可重试。" }
        return recoveredCount > 0 ? "已恢复 \(recoveredCount) 条中断的录制。" : nil
    }

    func start(discovering folders: [URL]) {
        guard store != nil, !shuttingDown else { return }
        directories.formUnion(folders)
        wantsRun = true
        launchIfNeeded()
    }

    func pauseForRecording() {
        guard store != nil, !shuttingDown, !isPaused else { return }
        isPaused = true
        if isRunning { wantsRun = true; task?.cancel() }
        onUpdate?()
    }

    func resumeAfterRecording() {
        guard isPaused, !shuttingDown else { return }
        isPaused = false
        launchIfNeeded()
        onUpdate?()
    }

    func deferForAnotherInstance() {
        errorMessage = "另一个 Scriber 正在运行，请关闭后重试恢复。"
        onUpdate?()
    }

    func cancelForQuit() {
        shuttingDown = true
        wantsRun = false
        task?.cancel()
        onUpdate?()
    }

    func waitForCurrentRun() async { await task?.value }

    private func launchIfNeeded() {
        guard let store, task == nil, wantsRun, !isPaused, !shuttingDown else { return }
        wantsRun = false
        isRunning = true
        currentTitle = ""
        errorMessage = nil
        issueCount = 0; busyCount = 0
        onUpdate?()
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil; self.isRunning = false; self.currentTitle = ""; self.currentID = nil
                self.onUpdate?()
                self.launchIfNeeded()
            }
            do {
                try Task.checkCancellation()
                let discoveryIssues = try await store.discover(in: Array(self.directories))
                try Task.checkCancellation()
                self.issueCount = discoveryIssues.count
                let entries = try await store.load()
                try Task.checkCancellation()
                for entry in entries {
                    try Task.checkCancellation()
                    guard let manifest = entry.manifest else { self.issueCount += 1; continue }
                    guard Set(manifest.published) != Set(manifest.paths.keys) else { continue }
                    self.currentTitle = entry.title
                    self.currentID = entry.id
                    self.onUpdate?()
                    do {
                        let result = try await self.recover(entry.reference.manifestURL)
                        if !result.newlyPublished.isEmpty { self.recoveredIDs.insert(entry.id) }
                        self.recoveredCount = self.recoveredIDs.count
                        try Task.checkCancellation()
                        if result.manifest.recovery?.issues.isEmpty == false { self.issueCount += 1 }
                    } catch is CancellationError { throw CancellationError() }
                    catch RecordingSessionLeaseError.inUse { self.busyCount += 1 }
                    catch {
                        if Task.isCancelled { throw CancellationError() }
                        self.issueCount += 1
                        self.errorMessage = "有录制未能恢复：\(error.localizedDescription)"
                    }
                    self.onUpdate?()
                }
                try Task.checkCancellation()
                self.hasChecked = true
            } catch is CancellationError {
                // The transaction retains its durable state for the next run.
            } catch {
                if !Task.isCancelled { self.errorMessage = "无法检查未完成录制：\(error.localizedDescription)" }
            }
        }
    }
}
