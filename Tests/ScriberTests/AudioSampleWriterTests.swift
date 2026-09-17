import AVFoundation
import Foundation
import Testing
@testable import Scriber

struct AudioSampleWriterTests {
    @Test(arguments: [(1, false, false), (2, false, false), (2, true, false), (1, false, true)])
    func encodesPCMAndPreservesValidPrefix(channels: Int, interleaved: Bool,
                                          repeatOldTimestamp: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.wav")
        try Self.makeWave(channels: channels).write(to: source)
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: !interleaved
        ])
        reader.add(output)
        #expect(reader.startReading())
        let writer = try AudioSampleWriter(url: directory.appendingPathComponent("output.m4a"),
                                          channels: UInt32(channels))
        var firstSample: CMSampleBuffer?
        while let sample = output.copyNextSampleBuffer() {
            if firstSample == nil { firstSample = sample }
            writer.queue.sync { writer.append(sample) }
        }
        #expect(reader.status == .completed)
        let summary: AudioWriteSummary
        if repeatOldTimestamp {
            let old = try #require(firstSample)
            writer.queue.sync { writer.append(old) }
            await #expect(throws: AudioWriteError.invalidTimestamp) { try await writer.finish() }
            summary = await writer.snapshot().0
        } else {
            summary = try await writer.finish()
        }
        #expect(summary.frames == 48_000)
        #expect(abs(summary.duration - 1) < 0.001)
        #expect(summary.peakDBFS > -13 && summary.peakDBFS < -11)
        let expectedRMS = channels == 1 ? sqrt(0.25 * 0.25 / 2)
            : sqrt((0.25 * 0.25 + 0.125 * 0.125) / 4)
        #expect(abs(Double(summary.powerDBFS) - 20 * log10(expectedRMS)) < 1)
        let moved = RecordingFileSet(urls: [.audio: summary.url]).relocate(to: directory, title: "录音 Café")
        #expect(moved.succeeded)
        let recorded = AVURLAsset(url: try #require(moved.files.urls[.audio]))
        let duration = try await recorded.load(.duration)
        #expect(abs(duration.seconds - summary.duration) < 1.0 / 48_000)
        let recordedTrack = try #require(try await recorded.loadTracks(withMediaType: .audio).first)
        let decoder = try AVAssetReader(asset: recorded)
        let decoded = AVAssetReaderTrackOutput(track: recordedTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM
        ])
        decoder.add(decoded)
        #expect(decoder.startReading())
        var decodedFrames = 0
        while let sample = decoded.copyNextSampleBuffer() { decodedFrames += sample.numSamples }
        #expect(decoder.status == .completed)
        #expect(decodedFrames > 45_000)
    }

    @Test func emptyCaptureCannotReportSuccess() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioSampleWriter(url: url)
        await #expect(throws: AudioWriteError.noSamples) { try await writer.finish() }
    }

    private static func makeWave(channels: Int) -> Data {
        var pcm = Data()
        for frame in 0..<48_000 {
            for channel in 0..<channels {
                let amplitude = channel == 0 ? 8191.0 : 4095.0
                let frequency = Double(880 * (channel + 1))
                var value = Int16(sin(Double(frame) * frequency * 2 * .pi / 48_000) * amplitude).littleEndian
                withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
            }
        }
        var wave = Data("RIFF".utf8)
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) }
        }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) }
        }
        u32(UInt32(36 + pcm.count))
        wave.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(UInt16(channels))
        u32(48_000); u32(UInt32(96_000 * channels)); u16(UInt16(2 * channels)); u16(16)
        wave.append(Data("data".utf8)); u32(UInt32(pcm.count)); wave.append(pcm)
        return wave
    }
}
