import AVFoundation
import Testing
@testable import Scriber

struct AudioPCMConverterTests {
    @Test(arguments: [(16_000.0, 1, false, false), (44_100.0, 1, false, false),
                      (48_000.0, 2, true, false), (48_000.0, 2, false, false),
                      (16_000.0, 1, true, true), (96_000.0, 2, false, false)])
    func streamingConversionPreservesDurationToneAndChannels(
        rate: Double, channels: Int, interleaved: Bool, integer: Bool
    ) throws {
        let format = try #require(AVAudioFormat(commonFormat: integer ? .pcmFormatInt16 : .pcmFormatFloat32,
                                               sampleRate: rate, channels: UInt32(channels), interleaved: interleaved))
        let frames = Int(rate / 5)
        let single = try AudioPCMConverter(inputFormat: format)
        var reference = try single.convert(makePCM(format: format, first: 0, count: frames))
        reference += try single.finish()

        let streaming = try AudioPCMConverter(inputFormat: format)
        var actual: [Float] = []
        var position = 0
        let sizes = [127, 257, 63, 511]
        var packet = 0
        while position < frames {
            let count = min(sizes[packet % sizes.count], frames - position)
            actual += try streaming.convert(makePCM(format: format, first: position, count: count))
            position += count
            packet += 1
        }
        actual += try streaming.finish()
        #expect(actual.count == 9_600 * 2)
        #expect(reference.count == actual.count)
        let maximumDifference = zip(actual, reference).map { abs($0 - $1) }.max() ?? 0
        #expect(maximumDifference < 0.00005)
        #expect(amplitude(actual, channel: 0, frequency: 1_000) > 0.23)
        #expect(amplitude(actual, channel: 0, frequency: 3_127) < 0.003)
        if channels == 1 {
            #expect(stride(from: 0, to: actual.count, by: 2).allSatisfy { actual[$0] == actual[$0 + 1] })
        } else {
            #expect(amplitude(actual, channel: 1, frequency: 2_000) > 0.115)
            #expect(amplitude(actual, channel: 1, frequency: 1_000) < 0.003)
        }
    }

    @Test(arguments: [44_100.0, 96_000.0])
    func fractionalLastPacketAndCMSampleBufferCopyPreserveTail(rate: Double) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: rate, channels: 1, interleaved: false))
        let converter = try AudioPCMConverter(inputFormat: format)
        let pcm = try makePCM(format: format, first: 0, count: 1_003)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                       presentationTimeStamp: CMTime(value: 500, timescale: 1),
                                       decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
                                    makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                                    sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                    sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer) == noErr)
        let sample = try #require(buffer)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                                                              blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                              flags: 0, bufferList: pcm.audioBufferList) == noErr)
        var result = try converter.convert(sample)
        result += try converter.finish()
        #expect(result.count / 2 == Int(floor(1_003.0 * 48_000 / rate)))
        let missingDuration = 1_003.0 / rate - Double(result.count / 2) / 48_000
        #expect(missingDuration >= 0 && missingDuration < 1.0 / 48_000)
        #expect(result.suffix(80).contains { abs($0) > 0.05 })
    }

    @Test(arguments: [16_000.0, 44_100.0])
    func resamplingDoesNotShiftKnownImpulseTimes(rate: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let pcm = try makePCM(format: format, first: 0, count: Int(rate / 10))
        let data = try #require(pcm.floatChannelData?[0])
        for i in 0..<Int(pcm.frameLength) { data[i] = 0 }
        data[Int(rate / 100)] = 0.8
        data[Int(rate / 20)] = 0.4
        let converter = try AudioPCMConverter(inputFormat: format)
        var output = try converter.convert(pcm)
        output += try converter.finish()
        for expected in [480, 2_400] {
            let peak = try #require(((expected - 100)...(expected + 100)).max {
                abs(output[$0 * 2]) < abs(output[$1 * 2])
            })
            #expect(abs(peak - expected) <= 1)
            #expect(abs(output[peak * 2]) > 0.2)
        }
    }

    @Test func invalidInputAndLifecycleAreExplicit() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let empty = try AudioPCMConverter(inputFormat: format)
        #expect(try empty.finish().isEmpty)
        #expect(throws: AudioPCMConverter.Failure.finished) { try empty.finish() }
        let malformed = try AudioPCMConverter(inputFormat: format)
        let pcm = try makePCM(format: format, first: 0, count: 480)
        pcm.floatChannelData?[0][42] = .nan
        #expect(throws: AudioPCMConverter.Failure.input) { try malformed.convert(pcm) }
        #expect(throws: AudioPCMConverter.Failure.finished) { try malformed.finish() }
        let oversized = try AudioPCMConverter(inputFormat: format)
        #expect(throws: AudioPCMConverter.Failure.input) {
            try oversized.convert(makePCM(format: format, first: 0, count: 48_001))
        }
        let mismatch = try AudioPCMConverter(inputFormat: format)
        let different = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        #expect(throws: AudioPCMConverter.Failure.input) {
            try mismatch.convert(makePCM(format: different, first: 0, count: 160))
        }
    }

    private func makePCM(format: AVAudioFormat, first: Int, count: Int) throws -> AVAudioPCMBuffer {
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        pcm.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(format.channelCount) {
            for offset in 0..<count {
                let frequency = channel == 0 ? 1_000.0 : 2_000.0
                let amplitude = channel == 0 ? 0.25 : 0.125
                let value = sin(Double(first + offset) * 2 * .pi * frequency / format.sampleRate) * amplitude
                let buffer = format.isInterleaved ? 0 : channel
                let index = format.isInterleaved ? offset * Int(format.channelCount) + channel : offset
                if format.commonFormat == .pcmFormatInt16 { pcm.int16ChannelData?[buffer][index] = Int16(value * 32_767) }
                else { pcm.floatChannelData?[buffer][index] = Float(value) }
            }
        }
        return pcm
    }

    private func amplitude(_ stereo: [Float], channel: Int, frequency: Double) -> Double {
        let first = 300
        let last = stereo.count / 2 - 100
        var sine = 0.0, cosine = 0.0
        for frame in first..<last {
            let phase = Double(frame) * 2 * .pi * frequency / 48_000
            let value = Double(stereo[frame * 2 + channel])
            sine += value * sin(phase)
            cosine += value * cos(phase)
        }
        return 2 * sqrt(sine * sine + cosine * cosine) / Double(last - first)
    }
}
