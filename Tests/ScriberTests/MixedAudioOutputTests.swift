import AVFoundation
import Testing
@testable import Scriber

struct MixedAudioOutputTests {
    @Test func nativeBufferPipelinePreservesOffsetAndEncodesBothSources() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioSampleWriter(url: url)
        let output = try MixedAudioOutput(writer: writer, sources: [.system, .microphone])
        let epoch: Int64 = 500 * 48_000
        for start in stride(from: 0, to: 48_000, by: 480) {
            for source in AudioSource.allCases where source == .system || start >= 4_800 {
                let frequency = source == .system ? 880.0 : 1_760.0
                let samples = (start..<(start + 480)).flatMap { frame -> [Float] in
                    let value = Float(sin(Double(frame) * frequency * 2 * .pi / 48_000) * 0.125)
                    return [value, value]
                }
                let sample = try MixedAudioOutput.sample(stereo: samples, at: epoch + Int64(start))
                writer.queue.sync { output.append(sample, source: source) }
            }
        }
        try await output.finish()
        let summary = try await writer.finish()
        let metrics = await output.snapshot()
        #expect(metrics.errorMessage == nil)
        #expect(metrics.nativeFrames[.system] == 48_000)
        #expect(metrics.nativeFrames[.microphone] == 43_200)
        let firstSystem = try #require(metrics.firstTimes[.system])
        let firstMic = try #require(metrics.firstTimes[.microphone])
        #expect(abs(firstMic - firstSystem - 0.1) < 0.000001)
        #expect(summary.frames == 48_000)
        #expect(abs(summary.duration - 1) < 0.000001)

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let pcmOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(pcmOutput)
        #expect(reader.startReading())
        var decoded: [Float] = []
        while let sample = pcmOutput.copyNextSampleBuffer() {
            let format = AVAudioFormat(cmAudioFormatDescription: try #require(sample.formatDescription))
            let converter = try AudioPCMConverter(inputFormat: format)
            decoded += try converter.convert(sample)
            decoded += try converter.finish()
        }
        #expect(reader.status == .completed)
        try #require(decoded.count > 90_000)
        for frequency in [880.0, 1_760.0] {
            var real = 0.0, imaginary = 0.0
            let first = 8_000, last = 40_000
            for frame in first..<last {
                let phase = Double(frame) * frequency * 2 * .pi / 48_000
                let value = Double(decoded[frame * 2])
                real += value * cos(phase)
                imaginary += value * sin(phase)
            }
            let amplitude = 2 * hypot(real, imaginary) / Double(last - first)
            #expect(amplitude > 0.1 && amplitude < 0.15)
        }
    }

    @Test func sourceRestartPreservesEpochAndFlushesResamplingTail() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioSampleWriter(url: url)
        let output = try MixedAudioOutput(writer: writer, sources: [.system, .microphone])
        let base: Int64 = 500 * 48_000
        for start in stride(from: 0, to: 48_000, by: 480) {
            if start == 14_400 || start == 28_800 {
                let selected: Set<AudioSource> = start == 14_400 ? [.system] : [.system, .microphone]
                try await output.prepareSources(selected, at: CMTime(value: base + Int64(start), timescale: 48_000))
                try await output.completeSources(selected)
                if start == 14_400 { #expect(await output.snapshot().lastTimes[.microphone] == nil) }
            }
            let system = try MixedAudioOutput.sample(stereo: Array(repeating: 0.1, count: 960), at: base + Int64(start))
            writer.queue.sync { output.append(system, source: .system) }
            if start < 14_400 || start >= 28_800 {
                let microphone = try nativeMicrophone(at: base + Int64(start))
                writer.queue.sync { output.append(microphone, source: .microphone) }
            }
        }
        try await output.finish()
        let summary = try await writer.finish()
        let metrics = await output.snapshot()
        #expect(metrics.errorMessage == nil)
        #expect(metrics.nativeFrames[.microphone] == 11_200)
        #expect(metrics.nativeRates[.microphone] == 16_000)
        #expect(summary.frames == 48_000)
        #expect(abs(summary.duration - 1) < 0.000001)
        #expect(metrics.maximumClockSkewFrames[.microphone] == 0)
    }

    @Test func explicitMediaEpochAndEndpointKeepSharedSamplesAndLeadingSilence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioSampleWriter(url: url)
        let epoch = CMTime(value: 100, timescale: 1)
        var mirroredFrames = 0
        var firstTimestamp: CMTime?
        var lastEnd: CMTime?
        let output = try MixedAudioOutput(writer: writer, sources: [.system], epoch: epoch,
                                         onMixedSample: { sample in
            mirroredFrames += sample.numSamples
            firstTimestamp = firstTimestamp ?? sample.presentationTimeStamp
            lastEnd = sample.presentationTimeStamp + CMTime(value: Int64(sample.numSamples), timescale: 48_000)
        })
        for offset in stride(from: 12_000, to: 24_000, by: 480) {
            let sample = try MixedAudioOutput.sample(stereo: Array(repeating: 0.1, count: 960),
                                                     at: 100 * 48_000 + Int64(offset))
            writer.queue.sync { output.append(sample, source: .system) }
        }
        try await output.finish(at: epoch + CMTime(value: 30_000, timescale: 48_000))
        let summary = try await writer.finish()
        #expect(summary.frames == 30_000 && summary.duration == 0.625)
        writer.queue.sync {
            #expect(mirroredFrames == 30_000)
            #expect(firstTimestamp == .zero)
            #expect(lastEnd == CMTime(value: 30_000, timescale: 48_000))
        }
    }

    private func nativeMicrophone(at frame: Int64) throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        pcm.frameLength = 160
        for i in 0..<160 { pcm.floatChannelData?[0][i] = Float(sin(Double(i) * 2 * .pi * 1_760 / 16_000) * 0.1) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000),
                                       presentationTimeStamp: CMTime(value: frame, timescale: 48_000), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
                                    makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                                    sampleCount: 160, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                    sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr)
        let sample = try #require(result)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                                                              blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                              flags: 0, bufferList: pcm.audioBufferList) == noErr)
        return sample
    }

    @Test func missingSelectedSourceCannotProduceFalseSuccess() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioSampleWriter(url: url)
        let output = try MixedAudioOutput(writer: writer, sources: [.system, .microphone])
        let sample = try MixedAudioOutput.sample(stereo: Array(repeating: 0.1, count: 960), at: 100_000)
        writer.queue.sync { output.append(sample, source: .system) }
        await #expect(throws: AudioWriteError.noSamples) { try await output.finish() }
        await #expect(throws: AudioWriteError.noSamples) { try await writer.finish() }
        #expect(await output.snapshot().errorMessage != nil)
    }
}
