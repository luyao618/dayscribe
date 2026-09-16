import Testing
@testable import Scriber

struct AudioTimelineMixerTests {
    private func stereo(_ frames: Int, left: Float, right: Float) -> [Float] {
        (0..<frames).flatMap { _ in [left, right] }
    }

    @Test func alignsDifferentArrivalOrderWithoutSwappingChannels() throws {
        let mixer = try AudioTimelineMixer(sources: [.system, .microphone],
                                          capacityFrames: 64, blockFrames: 4, holdbackFrames: 16)
        var blocks: [MixedAudioBlock] = []
        try mixer.append(.microphone, stereo: stereo(4, left: 0.25, right: 0.25), at: 4) { blocks.append($0) }
        try mixer.append(.system, stereo: stereo(12, left: 0.125, right: -0.125), at: 0) { blocks.append($0) }
        #expect(blocks.isEmpty)
        try mixer.finish { blocks.append($0) }
        #expect(blocks.map(\.startFrame) == [0, 4, 8])
        #expect(blocks[0].stereo == stereo(4, left: 0.125, right: -0.125))
        #expect(blocks[1].stereo == stereo(4, left: 0.375, right: 0.125))
        #expect(blocks[2].stereo == blocks[0].stereo)
        #expect(blocks[0].microphonePowerDBFS == -160)
        #expect(abs(blocks[1].microphonePowerDBFS + 12.0412) < 0.001)
    }

    @Test func sourceChangesApplyAtCaptureTimeInsideHeldBlock() throws {
        let mixer = try AudioTimelineMixer(sources: [.system, .microphone],
                                          capacityFrames: 64, blockFrames: 12, holdbackFrames: 24)
        var output: [Float] = []
        try mixer.append(.system, stereo: stereo(12, left: 0.125, right: 0.125), at: 0) { output += $0.stereo }
        try mixer.append(.microphone, stereo: stereo(12, left: 0.25, right: 0.25), at: 0) { output += $0.stereo }
        try mixer.setSources([.microphone], at: 4)
        try mixer.setSources([.system], at: 8)
        #expect(throws: AudioMixError.invalidSourceChange) { try mixer.setSources([], at: 9) }
        try mixer.finish { output += $0.stereo }
        let expected = stereo(4, left: 0.375, right: 0.375)
            + stereo(4, left: 0.25, right: 0.25) + stereo(4, left: 0.125, right: 0.125)
        #expect(output == expected)
    }

    @Test func cropsOnlyPreEpochPrefixAndPreservesGapsAndTail() throws {
        let mixer = try AudioTimelineMixer(sources: [.system], capacityFrames: 64,
                                          blockFrames: 4, holdbackFrames: 16)
        var output: [Float] = []
        try mixer.append(.system, stereo: [0.9, 0.9, 0.8, 0.8, 0.2, 0.2, 0.3, 0.3], at: -2) { output += $0.stereo }
        try mixer.append(.system, stereo: stereo(2, left: 0.4, right: 0.4), at: 4) { output += $0.stereo }
        try mixer.finish(at: 8) { output += $0.stereo }
        #expect(output == [0.2, 0.2, 0.3, 0.3, 0, 0, 0, 0, 0.4, 0.4, 0.4, 0.4, 0, 0, 0, 0])
    }

    @Test func boundsClippingAndReportsEachSourceLevel() throws {
        let mixer = try AudioTimelineMixer(sources: [.system, .microphone],
                                          capacityFrames: 64, blockFrames: 4, holdbackFrames: 8)
        var blocks: [MixedAudioBlock] = []
        try mixer.append(.system, stereo: stereo(4, left: 0.75, right: 0.25), at: 0) { blocks.append($0) }
        try mixer.append(.microphone, stereo: stereo(4, left: 0.5, right: -0.5), at: 0) { blocks.append($0) }
        try mixer.finish { blocks.append($0) }
        let block = try #require(blocks.first)
        #expect(block.stereo == stereo(4, left: 1, right: -0.25))
        #expect(block.clippedSamples == 4)
        #expect(abs(block.microphonePowerDBFS + 6.0206) < 0.001)
        #expect(abs(block.systemPowerDBFS + 5.0515) < 0.001)
    }

    @Test func rejectsLateOverlappingAndUnboundedInput() throws {
        let late = try AudioTimelineMixer(sources: [.system, .microphone], capacityFrames: 32,
                                         blockFrames: 4, holdbackFrames: 4)
        try late.append(.system, stereo: stereo(8, left: 0.1, right: 0.1), at: 0) { _ in }
        #expect(throws: AudioMixError.lateInput) {
            try late.append(.microphone, stereo: stereo(8, left: 0.1, right: 0.1), at: 0) { _ in }
        }
        #expect(throws: AudioMixError.finished) { try late.finish { _ in } }
        let overlap = try AudioTimelineMixer(sources: [.system], capacityFrames: 32,
                                            blockFrames: 4, holdbackFrames: 8)
        try overlap.append(.system, stereo: stereo(4, left: 0.1, right: 0.1), at: 0) { _ in }
        #expect(throws: AudioMixError.overlappingInput) {
            try overlap.append(.system, stereo: stereo(4, left: 0.1, right: 0.1), at: 2) { _ in }
        }
        let gap = try AudioTimelineMixer(sources: [.system], capacityFrames: 32,
                                        blockFrames: 4, holdbackFrames: 4)
        #expect(throws: AudioMixError.bufferOverflow) {
            try gap.append(.system, stereo: stereo(4, left: 0.1, right: 0.1), at: 1_000_000) { _ in }
        }
    }

    @Test func ringsWrapWithoutRepeatingOldAudioOrGrowingBufferedDuration() throws {
        let mixer = try AudioTimelineMixer(sources: [.system], capacityFrames: 64,
                                          blockFrames: 8, holdbackFrames: 16)
        var written: Int64 = 0
        var peakBuffered: Int64 = 0
        let emit: (MixedAudioBlock) -> Void = { block in
            #expect(block.startFrame == written)
            for i in 0..<block.frameCount {
                let frame = block.startFrame + Int64(i)
                let expected: Float = frame % 16 < 8 ? 0.25 : 0
                #expect(block.stereo[i * 2] == expected)
                #expect(block.stereo[i * 2 + 1] == -expected)
            }
            written += Int64(block.frameCount)
        }
        for frame in stride(from: Int64(0), to: 32_000, by: 16) {
            try mixer.append(.system, stereo: stereo(8, left: 0.25, right: -0.25), at: frame, emit: emit)
            peakBuffered = max(peakBuffered, mixer.bufferedFrames)
        }
        try mixer.finish(at: 32_000, emit: emit)
        #expect(written == 32_000)
        #expect(peakBuffered <= 16)
        #expect(mixer.bufferedFrames == 0)
    }

    @Test func invalidSamplesAndDownstreamFailureCannotContinueSilently() throws {
        let invalid = try AudioTimelineMixer(sources: [.system])
        #expect(throws: AudioMixError.invalidSamples) {
            try invalid.append(.system, stereo: [Float.nan, 0], at: 0) { _ in }
        }
        let mixer = try AudioTimelineMixer(sources: [.system], capacityFrames: 32,
                                          blockFrames: 4, holdbackFrames: 0)
        enum SinkError: Error { case full }
        #expect(throws: SinkError.full) {
            try mixer.append(.system, stereo: stereo(4, left: 0.1, right: 0.1), at: 0) { _ in throw SinkError.full }
        }
        #expect(mixer.cursor == 0)
        #expect(throws: AudioMixError.finished) {
            try mixer.append(.system, stereo: stereo(4, left: 0.1, right: 0.1), at: 4) { _ in }
        }
    }
}
