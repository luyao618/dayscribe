import Darwin
import Foundation
import Testing
@testable import Scriber

struct RecordingFileSetTests {
    @Test func validatesBasenamesWithoutSilentlyChangingPaths() throws {
        #expect(try RecordingFilename.validated("  会议 Café 🎙️  ") == "会议 Café 🎙️")
        #expect(try RecordingFilename.validated("Cafe\u{301}") == "Café")
        for invalid in ["", "  ", ".", "..", ".hidden", "../outside", "a/b", "a\\b", "a:b", "a\0b", "a\nb",
                        String(repeating: "会", count: 67)] {
            #expect(throws: (any Error).self) { try RecordingFilename.validated(invalid) }
        }
    }

    @Test func pairSharesSuffixAndNeverOverwritesEvenDanglingSymlinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let occupied = fixture.root.appendingPathComponent("会议.mp4")
        try Data("existing".utf8).write(to: occupied)
        let dangling = fixture.root.appendingPathComponent("会议 (2).m4a")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/missing-scriber-test")
        let result = fixture.files.relocate(to: fixture.root, title: "会议")
        #expect(result.succeeded && result.title == "会议 (3)")
        try expectContents(result.files, audio: "audio", video: "video")
        #expect(try Data(contentsOf: occupied) == Data("existing".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path) == "/missing-scriber-test")
        let noChange = result.files.relocate(to: fixture.root, title: "会议 (3)")
        #expect(noChange.succeeded && noChange.files.urls == result.files.urls)
    }

    @Test func collisionDuringSecondMoveRollsBackAndRetriesTheWholePair() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let raced = fixture.root.appendingPathComponent("会议.mp4")
        var injected = false
        let result = fixture.files.relocate(to: fixture.root, title: "会议") { source, target in
            if target == raced && !injected {
                injected = true
                try Data("racing writer".utf8).write(to: target, options: .withoutOverwriting)
            }
            try RecordingFileSet.moveExclusively(source, target)
        }
        #expect(result.succeeded && result.title == "会议 (2)")
        try expectContents(result.files, audio: "audio", video: "video")
        #expect(try Data(contentsOf: raced) == Data("racing writer".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("会议.m4a").path))
    }

    @Test func failedSecondMovePreservesTheOriginalPair() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = fixture.files.relocate(to: fixture.root, title: "会议") { source, target in
            if target.pathExtension == "mp4" { throw POSIXError(.ENOSPC) }
            try RecordingFileSet.moveExclusively(source, target)
        }
        #expect(!result.succeeded && result.title == nil)
        #expect(result.files.urls == fixture.files.urls)
        try expectContents(result.files, audio: "audio", video: "video")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("会议.m4a").path))
    }

    @Test func rollbackFailureReportsBothRealLocationsAndKeepsEveryFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalAudio = try #require(fixture.files.urls[.audio])
        let result = fixture.files.relocate(to: fixture.root, title: "会议") { source, target in
            if target.pathExtension == "mp4" {
                try Data("new occupant".utf8).write(to: originalAudio, options: .withoutOverwriting)
                throw POSIXError(.EACCES)
            }
            try RecordingFileSet.moveExclusively(source, target)
        }
        #expect(!result.succeeded)
        let message = try #require(result.errorMessage)
        #expect(message.contains(fixture.root.appendingPathComponent("会议.m4a").path))
        #expect(message.contains(POSIXError(.EACCES).localizedDescription))
        #expect(result.files.urls[.audio] == fixture.root.appendingPathComponent("会议.m4a"))
        #expect(result.files.urls[.video] == fixture.files.urls[.video])
        try expectContents(result.files, audio: "audio", video: "video")
        #expect(try Data(contentsOf: originalAudio) == Data("new occupant".utf8))
    }

    @Test func invalidOrMissingInputsAndMissingDestinationDoNotMoveFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(!fixture.files.relocate(to: fixture.root, title: "../outside").succeeded)
        #expect(!fixture.files.relocate(to: fixture.root.appendingPathComponent("absent"), title: "会议").succeeded)
        #expect(!RecordingFileSet(urls: [:]).relocate(to: fixture.root, title: "会议").succeeded)
        let audio = try #require(fixture.files.urls[.audio])
        let alias = fixture.root.appendingPathComponent("alias.m4a")
        try FileManager.default.linkItem(at: audio, to: alias)
        #expect(!RecordingFileSet(urls: [.audio: audio, .video: alias]).relocate(to: fixture.root, title: "会议").succeeded)
        let link = fixture.root.appendingPathComponent("link.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: audio)
        #expect(!RecordingFileSet(urls: [.audio: link]).relocate(to: fixture.root, title: "会议").succeeded)
        try expectContents(fixture.files, audio: "audio", video: "video")
        try FileManager.default.removeItem(at: #require(fixture.files.urls[.video]))
        #expect(!fixture.files.relocate(to: fixture.root, title: "会议").succeeded)
        #expect(try Data(contentsOf: audio) == Data("audio".utf8))
    }

    @Test func concurrentSavesKeepEachPairTogether() async throws {
        let first = try Fixture()
        let second = try Fixture(audio: "other audio", video: "other video")
        defer { first.remove(); second.remove() }
        let a = Task.detached { first.files.relocate(to: first.root, title: "会议") }
        let b = Task.detached { second.files.relocate(to: first.root, title: "会议") }
        let (one, two) = await (a.value, b.value)
        #expect(one.succeeded && two.succeeded && one.title != two.title)
        try expectContents(one.files, audio: "audio", video: "video")
        try expectContents(two.files, audio: "other audio", video: "other video")
    }

    private func expectContents(_ files: RecordingFileSet, audio: String, video: String) throws {
        for (kind, text) in [(RecordingFileKind.audio, audio), (.video, video)] {
            #expect(try Data(contentsOf: #require(files.urls[kind])) == Data(text.utf8))
        }
    }

    private struct Fixture: Sendable {
        let root: URL
        let files: RecordingFileSet
        init(audio: String = "audio", video: String = "video") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let staging = root.appendingPathComponent("staging")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            files = .init(urls: [.audio: staging.appendingPathComponent("capture.m4a"),
                                 .video: staging.appendingPathComponent("capture.mp4")])
            try Data(audio.utf8).write(to: files.urls[.audio]!)
            try Data(video.utf8).write(to: files.urls[.video]!)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
