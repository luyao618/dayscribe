import Foundation
import Testing
@testable import Scriber

struct RecordingRenameTests {
    @Test func metadataFailureIsResolvableAndStaleCallerCannotOverwriteNewPaths() async throws {
        let f = try await Fixture(video: true)
        defer { f.remove() }
        let index = try Data(contentsOf: f.store.indexURL)
        var writes = 0
        let failed = f.session.renamePublished(f.saved.files, title: "第一次改名") { manifest, url in
            writes += 1
            if writes == 2 { throw POSIXError(.ENOSPC) }
            try RecordingSessionFiles.writeManifest(manifest, url)
        }
        #expect(failed.errorMessage != nil)
        #expect(try RecordingSessionFiles.Manifest.read(from: f.session.manifestURL).title == "原名称")
        let original = try #require(f.saved.files.urls[.audio])
        try Data("unrelated occupant".utf8).write(to: original, options: .withoutOverwriting)
        var entry = try #require(try await f.store.entry(f.session.id))
        #expect(entry.title == "第一次改名" && entry.urls == failed.files.urls && entry.issue != nil)
        #expect(entry.fileStates == [.audio: .available, .video: .available])
        let repaired = f.session.renamePublished(f.saved.files, title: "第二次改名")
        #expect(repaired.errorMessage == nil)
        entry = try #require(try await f.store.entry(f.session.id))
        #expect(entry.title == "第二次改名" && entry.duration == 7.5 && entry.issue == nil)
        #expect(entry.urls == repaired.files.urls)
        try f.expectMedia(entry.urls)
        #expect(try Data(contentsOf: original) == Data("unrelated occupant".utf8))
        #expect(try Data(contentsOf: f.store.indexURL) == index)
    }

    @Test func simultaneousRenamesShareTheSessionLock() async throws {
        let f = try await Fixture(video: true)
        defer { f.remove() }
        async let first = Task.detached { f.session.renamePublished(f.saved.files, title: "one") }.value
        async let second = Task.detached { f.session.renamePublished(f.saved.files, title: "two") }.value
        let (a, b) = await (first, second)
        #expect(a.errorMessage == nil && b.errorMessage == nil)
        let entry = try #require(try await f.store.entry(f.session.id))
        #expect(["one", "two"].contains(entry.title))
        #expect(Set(entry.urls.values.map { $0.deletingPathExtension().lastPathComponent }).count == 1)
        try f.expectMedia(entry.urls)
    }

    @Test func identityAmbiguityAndReplacementRefuseRenameWithoutChangingMetadata() async throws {
        let f = try await Fixture(video: false)
        defer { f.remove() }
        let original = try #require(f.saved.files.urls[.audio])
        let first = f.session.directory.appendingPathComponent("first.m4a")
        let second = f.session.directory.appendingPathComponent("second.m4a")
        try RecordingFileSet.moveExclusively(original, first)
        try FileManager.default.linkItem(at: first, to: second)
        let metadata = try Data(contentsOf: f.session.manifestURL)
        #expect(f.session.renamePublished(f.saved.files, title: "ambiguous").errorMessage != nil)
        #expect(try Data(contentsOf: f.session.manifestURL) == metadata)
        try FileManager.default.removeItem(at: second)
        let outside = f.root.appendingPathComponent("outside.m4a")
        try RecordingFileSet.moveExclusively(first, outside)
        try Data("replacement".utf8).write(to: original)
        #expect(f.session.renamePublished(f.saved.files, title: "replacement").errorMessage != nil)
        let entry = try #require(try await f.store.entry(f.session.id))
        #expect(entry.fileStates[.audio] == .unavailable)
        #expect(try Data(contentsOf: f.session.manifestURL) == metadata)
        #expect(try Data(contentsOf: original) == Data("replacement".utf8))
        #expect(try Data(contentsOf: outside) == Data("m4a".utf8))
    }

    @Test func partialRecordingRenameRetainsUnfinishedMediaAndFailureReason() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSessionFiles.create(directory: root, title: "partial", video: true)
        for (kind, url) in session.files.urls { try Data(kind.rawValue.utf8).write(to: url) }
        let saved = session.finalize(title: "partial", closed: [.audio], duration: 3, captureError: "视频采集中止")
        let renamed = session.renamePublished(saved.files, title: "partial renamed")
        #expect(renamed.errorMessage == nil && renamed.published == [.audio])
        #expect(renamed.files.urls[.video] == session.files.urls[.video])
        let manifest = try RecordingSessionFiles.Manifest.read(from: session.manifestURL)
        #expect(manifest.paths.count == 2 && manifest.closed == ["m4a"] && manifest.published == ["m4a"])
        #expect(manifest.duration == 3 && manifest.captureError == "视频采集中止")
        #expect(try Data(contentsOf: #require(renamed.files.urls[.video])) == Data("mp4".utf8))
    }

    private struct Fixture: Sendable {
        let root: URL
        let session: RecordingSessionFiles
        let saved: RecordingSessionFiles.Finalization
        let store: RecordingHistoryStore
        init(video: Bool) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            session = try RecordingSessionFiles.create(directory: root.appendingPathComponent("media"), title: "原名称", video: video)
            for (kind, url) in session.files.urls { try Data(kind.rawValue.utf8).write(to: url) }
            saved = session.finalize(title: "原名称", closed: Set(session.files.urls.keys), duration: 7.5)
            store = RecordingHistoryStore(indexURL: root.appendingPathComponent("history.json"))
            try await store.register(.init(session: session, title: "原名称"))
        }
        func expectMedia(_ urls: [RecordingFileKind: URL]) throws {
            for (kind, url) in urls { #expect(try Data(contentsOf: url) == Data(kind.rawValue.utf8)) }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
