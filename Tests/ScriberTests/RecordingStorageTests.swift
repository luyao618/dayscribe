import Foundation
import Testing
@testable import Scriber

struct RecordingStorageTests {
    @Test func headroomAndVolumeIdentityAreRequired() throws {
        let audio = RecordingStorage.reserve(video: false)
        let video = RecordingStorage.reserve(video: true)
        #expect(video > audio)
        try RecordingStorage(availableBytes: audio + 1, volumeID: "a").validate(video: false, expectedVolume: "a")
        #expect(throws: StorageError.lowSpace) { try RecordingStorage(availableBytes: audio, volumeID: "a").validate(video: false) }
        #expect(throws: StorageError.lowSpace) { try RecordingStorage(availableBytes: audio + 1, volumeID: "a").validate(video: true) }
        #expect(throws: StorageError.changedVolume) {
            try RecordingStorage(availableBytes: video * 2, volumeID: "b").validate(video: true, expectedVolume: "a")
        }
    }

    @Test func filesystemProbeReturnsActualCapacityAndRejectsMissingLocations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try RecordingStorage.read(root)
        #expect(result.availableBytes > 0 && !result.volumeID.isEmpty)
        #expect(result.volumeID == (try RecordingStorage.read(root.deletingLastPathComponent())).volumeID)
        #expect(throws: StorageError.unavailable) { try RecordingStorage.read(root.appendingPathComponent("missing")) }
    }

    @Test @MainActor func insufficientStorageRefusesCaptureBeforePermissionOrMediaCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = AudioRecorder(readStorage: { _ in RecordingStorage(availableBytes: 0, volumeID: "test") })
        await recorder.start(directory: root, sources: [.system], title: "refuse")
        #expect(recorder.state == .failed && recorder.errorMessage?.contains("空间不足") == true)
        #expect(recorder.sessionID == nil && recorder.outputURL == nil && !recorder.audioSaved)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
