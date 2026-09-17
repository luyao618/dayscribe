import Foundation
import Testing
@testable import Scriber

struct RecordingHistoryModelTests {
    @Test func discoversOnlyValidDirectSessionDescriptors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media", isDirectory: true)
        let session = try RecordingSessionFiles.create(directory: media, title: "旧录制", video: false)
        try Data("audio".utf8).write(to: #require(session.files.urls[.audio]))
        _ = session.finalize(title: "旧录制", closed: [.audio], duration: 8)
        try Data("unrelated".utf8).write(to: media.appendingPathComponent("other.m4a"))
        _ = try RecordingSessionFiles.create(directory: media.appendingPathComponent("nested"), title: "nested", video: false)
        let outside = try RecordingSessionFiles.create(directory: root.appendingPathComponent("outside"), title: "outside", video: false)
        try FileManager.default.createSymbolicLink(at: media.appendingPathComponent(outside.stagingDirectory.lastPathComponent),
                                                  withDestinationURL: outside.stagingDirectory)
        let broken = media.appendingPathComponent(".scriber-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        try Data("broken".utf8).write(to: broken.appendingPathComponent("session.json"))
        let store = RecordingHistoryStore(indexURL: root.appendingPathComponent("history.json"))
        let issues = try await store.discover(in: [media, media, root.appendingPathComponent("absent")])
        #expect(issues.count == 1)
        #expect(try await store.load().map(\.id) == [session.id])
        let index = try Data(contentsOf: root.appendingPathComponent("history.json"))
        _ = try await store.discover(in: [media])
        #expect(try Data(contentsOf: root.appendingPathComponent("history.json")) == index)
    }

    @Test func discoveryNeverReplacesAnUnreadableRegistry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSessionFiles.create(directory: root, title: "保留", video: false)
        let index = root.appendingPathComponent("history.json")
        let bytes = Data("damaged index".utf8)
        try bytes.write(to: index)
        let manifest = try Data(contentsOf: session.manifestURL)
        let store = RecordingHistoryStore(indexURL: index)
        await #expect(throws: (any Error).self) { try await store.discover(in: [root]) }
        #expect(try Data(contentsOf: index) == bytes)
        #expect(try Data(contentsOf: session.manifestURL) == manifest)
    }

    @Test @MainActor func preservesLastGoodRowsAndRechecksFilesBeforeReveal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSessionFiles.create(directory: root.appendingPathComponent("media"), title: "保留", video: false)
        try Data("audio".utf8).write(to: #require(session.files.urls[.audio]))
        let saved = session.finalize(title: "保留", closed: [.audio], duration: 3.25)
        let url = try #require(saved.files.urls[.audio])
        let index = root.appendingPathComponent("history.json")
        let store = RecordingHistoryStore(indexURL: index)
        try await store.register(.init(session: session, title: "保留"))
        let model = RecordingHistoryModel(store: store)
        await model.refresh()
        #expect(model.entries.count == 1 && !model.isLoading && model.errorMessage == nil)
        try FileManager.default.removeItem(at: url)
        #expect(await model.filesForReveal(session.id).isEmpty)
        #expect(model.entries.first?.fileStates[.audio] == .missing && model.errorMessage != nil)
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: index)
        await model.refresh()
        #expect(model.entries.count == 1 && model.errorMessage != nil && !model.isLoading)
        #expect(try Data(contentsOf: index) == corrupt)
        #expect(RecordingHistoryModel.durationText(nil) == "—")
        #expect(RecordingHistoryModel.durationText(.greatestFiniteMagnitude) == "—")
        #expect(RecordingHistoryModel.durationText(8 * 3600 + 61) == "08:01:01")
    }
}
