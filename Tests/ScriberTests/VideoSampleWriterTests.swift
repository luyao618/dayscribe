import AVFoundation
import Testing
@testable import Scriber

struct VideoSampleWriterTests {
    @Test(arguments: ["none", "old-frame", "invalid-end"])
    func preservesOffsetAndSharedAudioAndFinalizesRejectedPrefix(rejection: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try AudioSampleWriter(url: root.appendingPathComponent("audio.m4a"))
        let video = try VideoSampleWriter(url: root.appendingPathComponent("video.mp4"), width: 64, height: 48,
                                          queue: audio.queue)
        let red = try pixels(red: true)
        let blue = try pixels(red: false)
        // A common timeline: audio begins at zero, picture arrives 200ms later.
        // The picture turns blue and a tone begins at the same 700ms timestamp.
        for index in 0..<36 {
            let values = (0..<1600).flatMap { frame -> [Float] in
                let t = Double(index * 1600 + frame) / 48_000
                let value = t < 0.7 ? Float.zero : Float(0.3 * sin(t * 880 * 2 * .pi))
                return [value, value]
            }
            let sample = try MixedAudioOutput.sample(stereo: values, at: Int64(index * 1600))
            try audio.queue.sync {
                try audio.appendChecked(sample)
                try video.appendAudio(sample)
                if index >= 6 {
                    try video.appendVideo(index < 21 ? red : blue, at: CMTime(value: Int64(index), timescale: 30))
                }
            }
            try await Task.sleep(for: .milliseconds(34))
        }
        if rejection == "old-frame" {
            #expect(throws: VideoWriteError.invalidTimestamp) {
                try video.queue.sync { try video.appendVideo(red, at: .zero) }
            }
            await #expect(throws: VideoWriteError.invalidTimestamp) { try await video.finish() }
        } else if rejection == "invalid-end" {
            await #expect(throws: VideoWriteError.invalidTimestamp) { try await video.finish(at: .zero) }
        } else {
            let result = try await video.finish(at: CMTime(value: 57_600, timescale: 48_000))
            #expect(result.videoFrames == 30 && result.audioFrames == 57_600)
            #expect(abs(result.duration - 1.2) < 0.000001)
        }
        _ = try await audio.finish()
        let asset = AVURLAsset(url: root.appendingPathComponent("video.mp4"))
        let picture = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let sound = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let videoFormat = try #require(try await picture.load(.formatDescriptions).first)
        let audioFormat = try #require(try await sound.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(videoFormat) == kCMVideoCodecType_H264)
        #expect(CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatMPEG4AAC)
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: picture, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(frames)
        #expect(reader.startReading())
        var times: [Double] = []
        var firstBlue: Double?
        var colors: [[Int]] = []
        while let sample = frames.copyNextSampleBuffer() {
            times.append(sample.presentationTimeStamp.seconds)
            let image = try #require(sample.imageBuffer)
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let data = try #require(CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self))
            colors.append([Int(data[0]), Int(data[1]), Int(data[2])])
            if data[0] > data[2], firstBlue == nil { firstBlue = sample.presentationTimeStamp.seconds }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
        }
        // AVAssetReader materializes the leading empty edit as one black buffer.
        // Check it explicitly, then all 30 actual picture timestamps.
        #expect(reader.status == .completed && times.count == 31)
        #expect(times.first == 0 && colors.first == [0, 0, 0])
        for (time, index) in zip(times.dropFirst(), 6..<36) {
            #expect(abs(time - Double(index) / 30) < 0.001)
        }
        #expect(colors[1][2] > 200 && colors[1][0] < 10)
        #expect(abs(try #require(firstBlue) - 0.7) < 0.001)
        let mp4Tone = try await toneOnset(asset)
        let m4aTone = try await toneOnset(AVURLAsset(url: root.appendingPathComponent("audio.m4a")))
        #expect(abs(mp4Tone - 0.7) < 0.03)
        #expect(abs(mp4Tone - m4aTone) < 1.0 / 48_000)
        #expect(abs(try #require(firstBlue) - mp4Tone) < 0.03)
        await #expect(throws: VideoWriteError.finished) { try await video.finish() }
    }

    @Test func missingTracksAndInvalidDimensionsCannotReportSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: VideoWriteError.invalidFormat) {
            try VideoSampleWriter(url: root.appendingPathComponent("odd.mp4"), width: 63, height: 48)
        }
        let empty = try VideoSampleWriter(url: root.appendingPathComponent("empty.mp4"), width: 64, height: 48)
        await #expect(throws: VideoWriteError.missingTrack) { try await empty.finish() }
        let silent = try VideoSampleWriter(url: root.appendingPathComponent("missing-audio.mp4"), width: 64, height: 48)
        let image = try pixels(red: true)
        try silent.queue.sync { try silent.appendVideo(image, at: .zero) }
        await #expect(throws: VideoWriteError.missingTrack) { try await silent.finish() }
    }

    private func pixels(red: Bool) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
                                   [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess)
        let image = try #require(result)
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self))
        for y in 0..<48 {
            for x in 0..<64 {
                let offset = y * CVPixelBufferGetBytesPerRow(image) + x * 4
                base[offset] = red ? 0 : 255
                base[offset + 1] = 0
                base[offset + 2] = red ? 255 : 0
                base[offset + 3] = 255
            }
        }
        return image
    }

    private func toneOnset(_ asset: AVURLAsset) async throws -> Double {
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        #expect(reader.startReading())
        var onset: Double?
        while let sample = output.copyNextSampleBuffer() {
            let description = try #require(sample.formatDescription)
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(sample.numSamples)))
            pcm.frameLength = UInt32(sample.numSamples)
            #expect(CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples),
                                                                into: pcm.mutableAudioBufferList) == noErr)
            let values = try #require(pcm.floatChannelData?[0])
            for index in 0..<sample.numSamples where onset == nil {
                if abs(values[index * Int(format.channelCount)]) > 0.15 {
                    onset = sample.presentationTimeStamp.seconds + Double(index) / format.sampleRate
                }
            }
        }
        #expect(reader.status == .completed)
        return try #require(onset)
    }
}
