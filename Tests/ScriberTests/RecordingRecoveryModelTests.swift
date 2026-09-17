import Foundation
import Synchronization
import Testing
@testable import Scriber

struct RecordingRecoveryModelTests {
    @Test @MainActor func startupDiscoversAndRecoversWhilePublishedDeletionsRemainMissing() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(indexURL: root.appendingPathComponent("history.json"))
        let unfinished = try await recording(in: root, title: "unfinished")
        let finished = try await recording(in: root, title: "finished")
        let saved = finished.finalize(title: "finished", closed: [.audio])
        try FileManager.default.removeItem(at: saved.files.urls[.audio]!)
        let model = RecordingRecoveryModel(store: store)
        model.start(discovering: [root])
        await model.waitForCurrentRun()
        #expect(model.hasChecked && !model.isRunning && model.recoveredCount == 1 && model.issueCount == 0)
        let entries = try await store.load()
        #expect(entries.count == 2)
        #expect(entries.first(where: { $0.id == unfinished.id })?.fileStates[.audio] == .available)
        #expect(entries.first(where: { $0.id == finished.id })?.fileStates[.audio] == .missing)
        model.start(discovering: [root]); await model.waitForCurrentRun()
        #expect(model.recoveredCount == 1 && !model.isRunning)
    }

    @Test @MainActor func activeSessionIsSkippedAndCanBeRetriedAfterRelease() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await recording(in: root, title: "active")
        let lease = try RecordingSessionLease.acquire(in: session.stagingDirectory)
        let model = RecordingRecoveryModel(store: RecordingHistoryStore(indexURL: root.appendingPathComponent("history.json")))
        model.start(discovering: [root]); await model.waitForCurrentRun()
        #expect(model.busyCount == 1 && model.recoveredCount == 0)
        lease.release()
        model.start(discovering: [root]); await model.waitForCurrentRun()
        #expect(model.busyCount == 0 && model.recoveredCount == 1)
    }

    @Test @MainActor func recordingPausesWorkAndCompletionResumesIt() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await recording(in: root, title: "pause")
        let entered = Mutex(0)
        let model = RecordingRecoveryModel(store: RecordingHistoryStore(indexURL: root.appendingPathComponent("history.json")), recover: { url in
            let attempt = entered.withLock { $0 += 1; return $0 }
            if attempt == 1 { try await Task.sleep(for: .seconds(30)) }
            return try await SessionRecovery.recover(manifestURL: url)
        })
        model.start(discovering: [root])
        for _ in 0..<100 {
            if entered.withLock({ $0 }) > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered.withLock { $0 } == 1)
        model.pauseForRecording()
        await model.waitForCurrentRun()
        #expect(model.isPaused && !model.isRunning && model.recoveredCount == 0)
        model.resumeAfterRecording()
        await model.waitForCurrentRun()
        #expect(!model.isPaused && model.recoveredCount == 1 && entered.withLock { $0 } == 2)
    }

    @Test @MainActor func quitKeepsRunningStateUntilCancellationActuallyFinishes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await recording(in: root, title: "quit")
        let entered = Mutex(false)
        let model = RecordingRecoveryModel(store: RecordingHistoryStore(indexURL: root.appendingPathComponent("history.json")), recover: { _ in
            entered.withLock { $0 = true }
            do { try await Task.sleep(for: .seconds(30)) }
            catch {
                await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
                throw CancellationError()
            }
            throw CancellationError()
        })
        model.start(discovering: [root])
        for _ in 0..<100 {
            if entered.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered.withLock { $0 })
        model.cancelForQuit()
        #expect(model.isRunning)
        await model.waitForCurrentRun()
        #expect(!model.isRunning && model.recoveredCount == 0)
        model.start(discovering: [root])
        #expect(!model.isRunning)
    }

    @Test @MainActor func corruptRegistryIsReportedAndNeverRebuilt() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("history.json")
        try Data("preserve".utf8).write(to: index)
        let model = RecordingRecoveryModel(store: RecordingHistoryStore(indexURL: index))
        model.start(discovering: [root]); await model.waitForCurrentRun()
        #expect(model.errorMessage != nil && !model.hasChecked)
        #expect(try Data(contentsOf: index) == Data("preserve".utf8))
    }

    private func recording(in root: URL, title: String) async throws -> RecordingSessionFiles {
        let session = try RecordingSessionFiles.create(directory: root, title: title, video: false)
        let writer = try AudioSampleWriter(url: session.files.urls[.audio]!)
        for offset in stride(from: 0, to: 24_000, by: 960) {
            let sample = try MixedAudioOutput.sample(stereo: Array(repeating: 0.1, count: 1920), at: Int64(offset))
            try writer.queue.sync { try writer.appendChecked(sample) }
        }
        _ = try await writer.finish()
        return session
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
