import Foundation
import Testing
@testable import Scriber

struct RecordingSessionFilesTests {
    @Test func finalTitleAndCollisionSuffixPreserveDestinationAndManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSessionFiles.create(directory: root, title: "开始前", video: true)
        let initial = try read(session)
        #expect(initial.title == "开始前" && initial.published.isEmpty && initial.closed.isEmpty)
        #expect(session.stagingDirectory.deletingLastPathComponent().path == root.path)
        try Data("audio".utf8).write(to: #require(session.files.urls[.audio]))
        try Data("video".utf8).write(to: #require(session.files.urls[.video]))
        let occupied = root.appendingPathComponent("最后的名称.mp4")
        try Data("keep".utf8).write(to: occupied)
        let saved = session.finalize(title: "最后的名称", closed: [.audio, .video])
        #expect(saved.errorMessage == nil && saved.title == "最后的名称 (2)")
        #expect(saved.published == [.audio, .video])
        for (kind, content) in [(RecordingFileKind.audio, "audio"), (.video, "video")] {
            let url = try #require(saved.files.urls[kind])
            #expect(url.deletingLastPathComponent() == session.directory)
            #expect(try Data(contentsOf: url) == Data(content.utf8))
            #expect(try !FileManager.default.fileExists(atPath: #require(session.files.urls[kind]).path))
        }
        let manifest = try read(session)
        #expect(manifest.id == initial.id && manifest.startedAt == initial.startedAt)
        #expect(manifest.title == saved.title && manifest.published == ["m4a", "mp4"])
        #expect(manifest.paths["m4a"] == saved.files.urls[.audio]?.path)
        #expect(try Data(contentsOf: occupied) == Data("keep".utf8))
    }

    @Test func publishesOnlyClosedOutputsAndRetainsFailedMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSessionFiles.create(directory: root, title: "部分完成", video: true)
        try Data("closed audio".utf8).write(to: #require(session.files.urls[.audio]))
        try Data("incomplete video".utf8).write(to: #require(session.files.urls[.video]))
        let result = session.finalize(title: "部分完成", closed: [.audio])
        #expect(result.published == [.audio] && result.errorMessage != nil)
        #expect(result.files.urls[.video] == session.files.urls[.video])
        #expect(try Data(contentsOf: #require(result.files.urls[.video])) == Data("incomplete video".utf8))
        #expect(try read(session).published == ["m4a"])
    }

    @Test func manifestWriteFailureKeepsClosedFilesInStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSessionFiles.create(directory: root, title: "保留", video: false)
        try Data("audio".utf8).write(to: #require(session.files.urls[.audio]))
        try FileManager.default.removeItem(at: session.manifestURL)
        try FileManager.default.createDirectory(at: session.manifestURL, withIntermediateDirectories: false)
        let result = session.finalize(title: "保留", closed: [.audio])
        #expect(result.errorMessage != nil && result.published.isEmpty)
        #expect(result.files.urls == session.files.urls)
        #expect(try Data(contentsOf: #require(result.files.urls[.audio])) == Data("audio".utf8))
    }

    @Test @MainActor func invalidInitialNameFailsBeforeCaptureOrCreatingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = AudioRecorder()
        await recorder.start(directory: root, sources: [.system], title: "../outside")
        #expect(recorder.state == .failed && recorder.errorMessage != nil)
        #expect(!recorder.audioSaved && recorder.outputURL == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private func read(_ session: RecordingSessionFiles) throws -> RecordingSessionFiles.Manifest {
        try JSONDecoder().decode(RecordingSessionFiles.Manifest.self, from: Data(contentsOf: session.manifestURL))
    }
}
