import Foundation
import Testing
@testable import Scriber

struct RecordingHistoryStoreTests {
    @Test func reloadsCustomFoldersAndReadsRenamedPathsWithoutRewritingTheIndex() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session("outside-index", video: true)
        let store = RecordingHistoryStore(indexURL: fixture.index)
        #expect(try await store.load().isEmpty)
        let reference = RecordingHistoryReference(session: session, title: "最初名称")
        try await store.register(reference)
        try await store.register(reference)
        for url in session.files.urls.values { try Data(url.pathExtension.utf8).write(to: url) }
        let saved = session.finalize(title: "已保存", closed: [.audio, .video], duration: 12.5, captureError: "采集提前结束")
        let indexData = try Data(contentsOf: fixture.index)
        let video = try #require(saved.files.urls[.video])
        let away = fixture.root.appendingPathComponent("temporarily-away.mp4")
        try RecordingFileSet.moveExclusively(video, away)
        #expect(session.renamePublished(saved.files, title: "失败的改名").errorMessage != nil)
        try RecordingFileSet.moveExclusively(away, video)
        let renamed = session.renamePublished(saved.files, title: "保存后改名")
        #expect(renamed.errorMessage == nil)
        try await store.register(.init(session: session, title: "再次发现时的新名称"))
        let entry = try #require(try await RecordingHistoryStore(indexURL: fixture.index).load().first)
        #expect(entry.id == session.id && entry.title == "保存后改名" && entry.duration == 12.5)
        #expect(entry.urls == renamed.files.urls && entry.fileStates == [.audio: .available, .video: .available])
        #expect(entry.issue == "采集提前结束")
        #expect(try Data(contentsOf: fixture.index) == indexData)
        #expect(try await store.load().count == 1)
    }

    @Test func distinctStoreInstancesDoNotLoseConcurrentRegistrations() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.session("one")
        let second = try fixture.session("two")
        let a = RecordingHistoryStore(indexURL: fixture.index)
        let b = RecordingHistoryStore(indexURL: fixture.index)
        async let one: Void = a.register(.init(session: first, title: "one"))
        async let two: Void = b.register(.init(session: second, title: "two"))
        _ = try await (one, two)
        let entries = try await a.load()
        #expect(Set(entries.map(\.id)) == [first.id, second.id])
        #expect(entries[0].reference.startedAt >= entries[1].reference.startedAt)
    }

    @Test func corruptAndFutureIndexesArePreservedOnRegistrationFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session("one")
        let store = RecordingHistoryStore(indexURL: fixture.index)
        for bytes in [Data("not json".utf8), Data(#"{"version":99,"recordings":[]}"#.utf8)] {
            try bytes.write(to: fixture.index)
            await #expect(throws: (any Error).self) { try await store.register(.init(session: session, title: "one")) }
            await #expect(throws: (any Error).self) { try await store.load() }
            #expect(try Data(contentsOf: fixture.index) == bytes)
        }
    }

    @Test func reportsMissingAndUnfinishedFilesWithoutDiscardingOtherEntries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session("one", video: true)
        let store = RecordingHistoryStore(indexURL: fixture.index)
        try await store.register(.init(session: session, title: "one"))
        let audio = try #require(session.files.urls[.audio])
        try Data("closed".utf8).write(to: audio)
        try Data("incomplete".utf8).write(to: #require(session.files.urls[.video]))
        let saved = session.finalize(title: "部分完成", closed: [.audio], duration: 3)
        var entry = try #require(try await store.load().first)
        #expect(entry.fileStates == [.audio: .available, .video: .unfinished] && entry.issue != nil)
        try FileManager.default.removeItem(at: #require(saved.files.urls[.audio]))
        entry = try #require(try await store.load().first)
        #expect(entry.fileStates[.audio] == .missing)
        let valid = try fixture.session("two")
        try await store.register(.init(session: valid, title: "two"))
        try FileManager.default.removeItem(at: session.manifestURL)
        let entries = try await store.load()
        #expect(entries.count == 2)
        let missing = try #require(entries.first(where: { $0.id == session.id }))
        #expect(missing.manifest == nil && missing.title == "one" && missing.issue != nil)
    }

    @Test func rejectsUnrelatedMediaPathsAndDuplicateIndexEntries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session("one")
        let store = RecordingHistoryStore(indexURL: fixture.index)
        try await store.register(.init(session: session, title: "one"))
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: session.manifestURL)) as! [String: Any]
        manifest["paths"] = ["m4a": fixture.root.appendingPathComponent("unrelated.m4a").path]
        try JSONSerialization.data(withJSONObject: manifest).write(to: session.manifestURL)
        let entry = try #require(try await store.load().first)
        #expect(entry.manifest == nil && entry.urls.isEmpty && entry.issue != nil)
        var index = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.index)) as! [String: Any]
        let items = index["recordings"] as! [[String: Any]]
        index["recordings"] = items + items
        let duplicate = try JSONSerialization.data(withJSONObject: index)
        try duplicate.write(to: fixture.index)
        await #expect(throws: (any Error).self) { try await store.load() }
        await #expect(throws: (any Error).self) { try await store.register(.init(session: session, title: "one")) }
        #expect(try Data(contentsOf: fixture.index) == duplicate)
    }

    @Test func failedIndexWritesLeaveSessionMetadataAndMediaUntouched() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session("one")
        let marker = fixture.root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: marker)
        let metadata = try Data(contentsOf: session.manifestURL)
        let store = RecordingHistoryStore(indexURL: marker.appendingPathComponent("history.json"))
        await #expect(throws: (any Error).self) { try await store.register(.init(session: session, title: "one")) }
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
        #expect(try Data(contentsOf: session.manifestURL) == metadata)
    }

    @Test func refusesLinkedAndOversizedIndexesWithoutReplacingThem() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session("one")
        let store = RecordingHistoryStore(indexURL: fixture.index)
        let reference = RecordingHistoryReference(session: session, title: "one")
        try await store.register(reference)
        let backing = fixture.root.appendingPathComponent("original.json")
        try FileManager.default.moveItem(at: fixture.index, to: backing)
        let original = try Data(contentsOf: backing)
        try FileManager.default.createSymbolicLink(at: fixture.index, withDestinationURL: backing)
        await #expect(throws: (any Error).self) { try await store.register(reference) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.index.path) == backing.path)
        #expect(try Data(contentsOf: backing) == original)
        try FileManager.default.removeItem(at: fixture.index)
        let oversized = Data(repeating: 0, count: 9 * 1024 * 1024)
        try oversized.write(to: fixture.index)
        await #expect(throws: (any Error).self) { try await store.load() }
        await #expect(throws: (any Error).self) { try await store.register(reference) }
        #expect(try Data(contentsOf: fixture.index) == oversized)
    }

    @Test func failedAtomicUpdatePreservesAnExistingReadableIndex() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.session("one")
        let second = try fixture.session("two")
        let store = RecordingHistoryStore(indexURL: fixture.index)
        try await store.register(.init(session: first, title: "one"))
        let original = try Data(contentsOf: fixture.index)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path) }
        await #expect(throws: (any Error).self) { try await store.register(.init(session: second, title: "two")) }
        #expect(try Data(contentsOf: fixture.index) == original)
        #expect(try await store.load().map(\.id) == [first.id])
    }

    @Test func legacyManifestLoadsAndCorruptMetadataBlocksRenameWithoutMovingMedia() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session("one")
        try Data("audio".utf8).write(to: #require(session.files.urls[.audio]))
        let saved = session.finalize(title: "legacy", closed: [.audio])
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: session.manifestURL)) as! [String: Any]
        for key in ["version", "duration", "captureError", "fileIdentities"] { json.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: json).write(to: session.manifestURL)
        let store = RecordingHistoryStore(indexURL: fixture.index)
        try await store.register(.init(session: session, title: "one"))
        let entry = try #require(try await store.load().first)
        #expect(entry.title == "legacy" && entry.duration == nil && entry.fileStates[.audio] == .available)
        let corrupt = Data("broken metadata".utf8)
        try corrupt.write(to: session.manifestURL)
        let result = session.renamePublished(saved.files, title: "new")
        #expect(result.errorMessage != nil && result.files.urls == saved.files.urls)
        #expect(try Data(contentsOf: session.manifestURL) == corrupt)
        #expect(try Data(contentsOf: #require(saved.files.urls[.audio])) == Data("audio".utf8))
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var index: URL { root.appendingPathComponent("history.json") }
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func session(_ folder: String, video: Bool = false) throws -> RecordingSessionFiles {
            try .create(directory: root.appendingPathComponent(folder, isDirectory: true), title: folder, video: video)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
