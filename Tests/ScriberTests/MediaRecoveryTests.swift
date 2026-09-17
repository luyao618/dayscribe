import Foundation
import Testing
@testable import Scriber

struct MediaRecoveryTests {
    @Test func nativeRecoveryPreservesSourceAndReturnsAClosedDecodableAudioFile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await audio(in: root)
        let original = try Data(contentsOf: source)
        let work = try directory(in: root)
        let recovered = try await MediaRecovery.recover(source: source, kind: .audio, workDirectory: work)
        #expect(recovered.url == work.appendingPathComponent("recovered.m4a"))
        #expect(recovered.audioFrames == 48_000 && recovered.videoFrames == 0)
        #expect(abs(recovered.duration - 1) < 1.0 / 48_000)
        #expect(try Data(contentsOf: source) == original)
        #expect(recovered.prefix.sourceBytes == original.count)
    }

    @Test func wrongMediaKindAndExistingOutputCannotBecomeRecoverySuccess() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await audio(in: root)
        let original = try Data(contentsOf: source)
        let wrong = try directory(in: root)
        await #expect(throws: (any Error).self) { try await MediaRecovery.recover(source: source, kind: .video, workDirectory: wrong) }
        #expect(!FileManager.default.fileExists(atPath: wrong.appendingPathComponent("recovered.mp4").path))
        let occupied = try directory(in: root)
        let target = occupied.appendingPathComponent("recovered.m4a")
        try Data("keep".utf8).write(to: target)
        await #expect(throws: (any Error).self) { try await MediaRecovery.recover(source: source, kind: .audio, workDirectory: occupied) }
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
        #expect(try Data(contentsOf: source) == original)
        let fake = root.appendingPathComponent("fake.m4a")
        let badMovie = Data([0, 0, 0, 16]) + Data("ftypmp42".utf8) + Data([0, 0, 0, 0])
            + Data([0, 0, 0, 12]) + Data("mdatbad!".utf8)
            + Data([0, 0, 0, 12]) + Data("moovbad!".utf8)
        try badMovie.write(to: fake)
        let invalid = try directory(in: root)
        await #expect(throws: (any Error).self) { try await MediaRecovery.recover(source: fake, kind: .audio, workDirectory: invalid) }
        #expect(try Data(contentsOf: fake) == badMovie)
        #expect(!FileManager.default.fileExists(atPath: invalid.appendingPathComponent("recovered.m4a").path))
    }

    @Test func canceledRecoveryDoesNotChangeOriginalMedia() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await audio(in: root)
        let original = try Data(contentsOf: source)
        let work = try directory(in: root)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MediaRecovery.recover(source: source, kind: .audio, workDirectory: work)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("recovered.m4a").path))
    }

    private func audio(in root: URL) async throws -> URL {
        let source = root.appendingPathComponent("source.m4a")
        let writer = try AudioSampleWriter(url: source)
        for offset in stride(from: 0, to: 48_000, by: 960) {
            let sample = try MixedAudioOutput.sample(stereo: Array(repeating: 0.1, count: 1920), at: Int64(offset))
            try writer.queue.sync { try writer.appendChecked(sample) }
        }
        _ = try await writer.finish()
        return source
    }
    private func directory(in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
