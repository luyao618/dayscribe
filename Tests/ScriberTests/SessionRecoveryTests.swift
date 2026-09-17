import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Scriber

struct SessionRecoveryTests {
    @Test func recoversIntoTheSameRecordWithoutOverwritingOrRepeatingWork() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSessionFiles.create(directory: root, title: "会议", video: false)
        let history = RecordingHistoryStore(indexURL: root.appendingPathComponent("history.json"))
        try await history.register(.init(session: session, title: "会议"))
        try await writeAudio(session.files.urls[.audio]!)
        let bytes = try Data(contentsOf: session.files.urls[.audio]!)
        let sentinel = root.appendingPathComponent("会议.m4a")
        try Data("keep".utf8).write(to: sentinel)
        let result = try await SessionRecovery.recover(manifestURL: session.manifestURL)
        #expect(result.changed && result.manifest.id == session.id && result.manifest.startedAt == session.startedAt)
        #expect(result.manifest.title == "会议 (2)" && result.manifest.published == ["m4a"])
        let entry = try #require(try await history.entry(session.id))
        #expect(entry.title == "会议 (2)" && entry.fileStates[.audio] == .available)
        #expect(try await history.load().count == 1)
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        #expect(try Data(contentsOf: session.files.urls[.audio]!) == bytes)
        let snapshot = try Data(contentsOf: session.manifestURL)
        #expect(try await !SessionRecovery.recover(manifestURL: session.manifestURL).changed)
        #expect(try Data(contentsOf: session.manifestURL) == snapshot)
        let renamed = try await history.rename(session.id, title: "已恢复")
        #expect(renamed.errorMessage == nil)
        #expect(try RecordingSessionFiles.Manifest.read(from: session.manifestURL).recovery?.transactionID == result.manifest.recovery?.transactionID)
    }

    @Test func failedFinalMetadataWriteResumesAfterMovesWithoutDuplicatingFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSessionFiles.create(directory: root, title: "retry", video: false)
        try await writeAudio(session.files.urls[.audio]!)
        let writes = Mutex(0)
        await #expect(throws: (any Error).self) {
            try await SessionRecovery.recover(manifestURL: session.manifestURL, saveManifest: { manifest, url in
                let count = writes.withLock { $0 += 1; return $0 }
                if count == 2 { throw POSIXError(.ENOSPC) }
                try RecordingSessionFiles.writeManifest(manifest, url)
            })
        }
        let published = root.appendingPathComponent("retry.m4a")
        let identity = try #require(RecordingFileIdentity.read(published))
        let retry = try await SessionRecovery.recover(manifestURL: session.manifestURL)
        #expect(retry.changed && retry.manifest.published == ["m4a"])
        #expect(RecordingFileIdentity.read(published) == identity)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("retry (2).m4a").path))
    }

    @Test func partialRecoveryPreservesMissingCompanionAndDoesNotLoop() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSessionFiles.create(directory: root, title: "partial", video: true)
        try await writeAudio(session.files.urls[.audio]!)
        try Data("not a movie".utf8).write(to: session.files.urls[.video]!)
        let result = try await SessionRecovery.recover(manifestURL: session.manifestURL)
        #expect(result.changed && result.manifest.published == ["m4a"])
        #expect(result.manifest.paths["mp4"] == session.files.urls[.video]!.path)
        #expect(result.manifest.recovery?.issues["mp4"] != nil)
        #expect(try Data(contentsOf: session.files.urls[.video]!) == Data("not a movie".utf8))
        #expect(try await !SessionRecovery.recover(manifestURL: session.manifestURL).changed)
        let audioURL = URL(fileURLWithPath: result.manifest.paths["m4a"]!)
        let audioIdentity = try #require(RecordingFileIdentity.read(audioURL))
        let repaired = try RecordingSessionFiles.create(directory: root.appendingPathComponent("fixture"), title: "pair", video: true)
        try await writePair(repaired)
        try FileManager.default.removeItem(at: session.files.urls[.video]!)
        try FileManager.default.copyItem(at: repaired.files.urls[.video]!, to: session.files.urls[.video]!)
        let retry = try await SessionRecovery.recover(manifestURL: session.manifestURL)
        #expect(retry.manifest.published == ["m4a", "mp4"] && retry.manifest.recovery?.issues.isEmpty == true)
        #expect(RecordingFileIdentity.read(audioURL) == audioIdentity)
    }

    @Test func interruptedMoveCanBeFoundByIdentityAndRetried() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSessionFiles.create(directory: root, title: "move", video: false)
        try await writeAudio(session.files.urls[.audio]!)
        let injected = Mutex(false)
        await #expect(throws: (any Error).self) {
            try await SessionRecovery.recover(manifestURL: session.manifestURL, move: { from, to in
                try RecordingFileSet.moveExclusively(from, to)
                if to.deletingLastPathComponent() == root && injected.withLock({ old in
                    if old { return false }; old = true; return true
                }) { throw POSIXError(.EIO) }
            })
        }
        let moved = root.appendingPathComponent("move.m4a")
        let identity = try #require(RecordingFileIdentity.read(moved))
        let result = try await SessionRecovery.recover(manifestURL: session.manifestURL)
        #expect(result.manifest.published == ["m4a"] && RecordingFileIdentity.read(moved) == identity)
        #expect(try await !SessionRecovery.recover(manifestURL: session.manifestURL).changed)
    }

    @Test func corruptJournalDoesNotRewriteTheSessionOrMedia() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSessionFiles.create(directory: root, title: "corrupt", video: false)
        try await writeAudio(session.files.urls[.audio]!)
        let manifest = try Data(contentsOf: session.manifestURL)
        let media = try Data(contentsOf: session.files.urls[.audio]!)
        try Data("broken journal".utf8).write(to: session.stagingDirectory.appendingPathComponent("recovery.json"))
        await #expect(throws: (any Error).self) { try await SessionRecovery.recover(manifestURL: session.manifestURL) }
        #expect(try Data(contentsOf: session.manifestURL) == manifest)
        #expect(try Data(contentsOf: session.files.urls[.audio]!) == media)
    }

    @Test func intactVideoRestoresAnUnusableAudioCompanion() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSessionFiles.create(directory: root, title: "companion", video: true)
        try await writePair(session)
        try Data("damaged audio".utf8).write(to: session.files.urls[.audio]!)
        let result = try await SessionRecovery.recover(manifestURL: session.manifestURL)
        #expect(result.manifest.published == ["m4a", "mp4"] && result.newlyPublished == [.audio, .video])
        #expect(result.manifest.recovery?.issues.isEmpty == true)
        #expect(try Data(contentsOf: session.files.urls[.audio]!) == Data("damaged audio".utf8))
        let audio = try await MediaRecovery.validate(url: URL(fileURLWithPath: result.manifest.paths["m4a"]!), kind: .audio)
        #expect(audio.audioFrames == 19_200)
    }

    @Test func activeCaptureOrRenameCannotBeTakenOver() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = try RecordingSessionFiles.begin(directory: root, title: "active", video: false)
        await #expect(throws: RecordingSessionLeaseError.inUse) { try await SessionRecovery.recover(manifestURL: owned.session.manifestURL) }
        #expect(!FileManager.default.fileExists(atPath: owned.session.stagingDirectory.appendingPathComponent("recovery.json").path))
        owned.lease.release()
        let rename = try RecordingSessionLease.acquire(in: owned.session.stagingDirectory, purpose: .rename)
        defer { rename.release() }
        await #expect(throws: RecordingSessionLeaseError.inUse) { try await SessionRecovery.recover(manifestURL: owned.session.manifestURL) }
    }

    private func writeAudio(_ url: URL) async throws {
        let writer = try AudioSampleWriter(url: url)
        for offset in stride(from: 0, to: 24_000, by: 960) {
            let sample = try MixedAudioOutput.sample(stereo: Array(repeating: 0.1, count: 1920), at: Int64(offset))
            try writer.queue.sync { try writer.appendChecked(sample) }
        }
        _ = try await writer.finish()
    }
    private func writePair(_ session: RecordingSessionFiles) async throws {
        let audio = try AudioSampleWriter(url: session.files.urls[.audio]!)
        let video = try VideoSampleWriter(url: session.files.urls[.video]!, width: 64, height: 48, queue: audio.queue)
        var pixels: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess)
        let image = try #require(pixels)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 0, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        for index in 0..<12 {
            let sample = try MixedAudioOutput.sample(stereo: Array(repeating: 0.1, count: 3200), at: Int64(index * 1600))
            try audio.queue.sync {
                try audio.appendChecked(sample); try video.appendAudio(sample)
                try video.appendVideo(image, at: CMTime(value: Int64(index), timescale: 30))
            }
            try await Task.sleep(for: .milliseconds(34))
        }
        _ = try await audio.finish()
        _ = try await video.finish(at: CMTime(value: 2, timescale: 5))
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
