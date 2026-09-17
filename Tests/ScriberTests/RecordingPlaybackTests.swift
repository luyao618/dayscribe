import AVFoundation
import Testing
@testable import Scriber

struct RecordingPlaybackTests {
    @Test @MainActor func loadsPausedAndUsesRealPlayerTimeForSeekPlayAndPause() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = RecordingPlaybackModel(store: fixture.store)
        model.player.isMuted = true // Component check only; native playback is checked separately.
        defer { model.close() }
        await model.open(fixture.session.id).value
        try await wait { model.canPlay }
        #expect(!model.isPlaying && model.position == 0 && abs(model.duration - 4) < 0.1)
        model.seek(to: 1.2)
        try await wait { !model.isSeeking && abs(model.position - 1.2) < 0.05 }
        await model.togglePlayback()
        try await wait { model.position > 1.5 && model.isPlaying }
        model.pause()
        let stopped = model.player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(200))
        #expect(!model.isPlaying && abs(model.player.currentTime().seconds - stopped) < 0.05)
        model.suspend()
        await model.togglePlayback()
        #expect(!model.isPlaying)
        model.resume()
        await model.togglePlayback()
        try await wait { model.isPlaying }
        model.close()
        #expect(model.player.currentItem == nil && model.entry == nil && !model.isPlaying)
    }

    @Test @MainActor func missingMediaAndUnfinishedFilesCannotStartPlayback() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = RecordingPlaybackModel(store: fixture.store)
        model.player.isMuted = true
        defer { model.close() }
        await model.open(fixture.session.id).value
        try await wait { model.canPlay }
        try FileManager.default.removeItem(at: fixture.url)
        await model.togglePlayback()
        #expect(!model.isPlaying && model.errorMessage != nil)
        let unfinished = try await Fixture(finish: false)
        defer { unfinished.remove() }
        let second = RecordingPlaybackModel(store: unfinished.store)
        defer { second.close() }
        await second.open(unfinished.session.id).value
        #expect(!second.isLoading && second.errorMessage != nil && second.player.currentItem == nil)
    }

    @Test @MainActor func closingDuringLoadCannotResurrectAnItemAndCorruptMediaFails() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let model = RecordingPlaybackModel(store: fixture.store)
        model.player.isMuted = true
        defer { model.close() }
        let pending = model.open(fixture.session.id)
        model.close()
        await pending.value
        #expect(model.player.currentItem == nil && model.entry == nil && !model.isLoading)
        try Data("not an audio file".utf8).write(to: fixture.url)
        await model.open(fixture.session.id).value
        #expect(model.errorMessage != nil && !model.isPlaying && !model.isLoading)
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("AVPlayer did not reach the expected state")
        throw CocoaError(.fileReadUnknown)
    }

    private struct Fixture {
        let root: URL
        let session: RecordingSessionFiles
        let store: RecordingHistoryStore
        let url: URL
        init(finish: Bool = true) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            session = try RecordingSessionFiles.create(directory: root.appendingPathComponent("media"), title: "播放检查", video: false)
            let input = session.files.urls[.audio]!
            try Self.writeAudio(input)
            url = finish ? session.finalize(title: "播放检查", closed: [.audio], duration: 4).files.urls[.audio]! : input
            store = RecordingHistoryStore(indexURL: root.appendingPathComponent("history.json"))
            try await store.register(.init(session: session, title: "播放检查"))
        }
        private static func writeAudio(_ url: URL) throws {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 192_000)!
            buffer.frameLength = buffer.frameCapacity
            for index in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![0][index] = Float(0.02 * sin(Double(index) * 880 * 2 * .pi / 48_000))
            }
            try file.write(from: buffer)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
