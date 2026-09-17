import Foundation
import Testing
@testable import Scriber

struct AudioRecorderPreferencesTests {
    @Test @MainActor func remembersSelectionButNeverPersistsAnEmptySourceSet() async throws {
        let name = "scriber-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AudioRecorder(defaults: defaults)
        #expect(first.sources == [.system, .microphone])
        #expect(await first.setSources([.microphone]))
        let restored = AudioRecorder(defaults: defaults)
        #expect(restored.sources == [.microphone])
        #expect(!(await restored.setSources([])))
        #expect(restored.controlMessage == "至少保留一路声音。")
        #expect(restored.state == .idle)
        #expect(AudioRecorder(defaults: defaults).sources == [.microphone])
        defaults.set(0, forKey: "recordingSources")
        #expect(AudioRecorder(defaults: defaults).sources == [.system, .microphone])
    }

    @Test @MainActor func destinationsPersistIndependentlyAndRejectInvalidChanges() async throws {
        let name = "scriber-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let audio = root.appendingPathComponent("音频", isDirectory: true)
        let video = root.appendingPathComponent("视频", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = AudioRecorder(defaults: defaults)
        #expect(recorder.destination(for: .audio) == RecordingDestination.defaultURL(for: .audio))
        try await recorder.setDestination(audio, for: .audio)
        #expect(recorder.destination(for: .video) == RecordingDestination.defaultURL(for: .video))
        try await recorder.setDestination(video, for: .video)
        let restored = AudioRecorder(defaults: defaults)
        #expect(restored.destination(for: .audio) == audio && restored.destination(for: .video) == video)
        let file = root.appendingPathComponent("file")
        try Data("keep".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await restored.setDestination(file, for: .audio) }
        await #expect(throws: (any Error).self) { try await restored.setDestination(root.appendingPathComponent("absent"), for: .audio) }
        #expect(AudioRecorder(defaults: defaults).destination(for: .audio) == audio)
        // Early title rejection avoids requesting capture permissions in a unit test.
        await recorder.start(title: "../invalid")
        try await recorder.setDestination(video, for: .audio)
        #expect(recorder.recordingDirectory == audio && recorder.destination(for: .audio) == video)
        #expect(recorder.outputURL == nil)
    }

    @Test @MainActor func unavailableStoredDirectoryIsNotSilentlyReplaced() throws {
        let name = "scriber-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defaults.set(missing.path, forKey: RecordingMode.video.directoryPreferenceKey)
        #expect(AudioRecorder(defaults: defaults).destination(for: .video) == missing)
        defaults.set("relative/path", forKey: RecordingMode.audio.directoryPreferenceKey)
        #expect(AudioRecorder(defaults: defaults).destination(for: .audio) == RecordingDestination.defaultURL(for: .audio))
    }
}
