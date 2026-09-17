import AVFoundation
import ScreenCaptureKit
import Testing
@testable import Scriber

struct ScreenVideoOutputTests {
    @Test func idleCheckpointsUseTheCapturedPictureAndLimitRepeats() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoSampleWriter(url: url, width: 64, height: 48)
        let epoch = CMTime(value: 100, timescale: 1)
        let output = ScreenVideoOutput(writer: writer, epoch: epoch)
        let real = try sample(red: true, time: epoch + CMTime(value: 125, timescale: 1000), status: .complete)
        writer.queue.sync { output.append(real) }
        for index in 0..<90 {
            let sound = try MixedAudioOutput.sample(stereo: Array(repeating: 0, count: 3200), at: Int64(index * 1600))
            try writer.queue.sync { try writer.appendAudio(sound) }
            if [3, 18, 31, 50, 61, 83].contains(index) {
                // An idle payload is deliberately blue: it must not replace
                // the last real red picture, regardless of any attached buffer.
                let idle = try sample(red: false, time: epoch + CMTime(value: Int64(index), timescale: 30), status: .idle)
                writer.queue.sync { output.append(idle) }
            }
            try await Task.sleep(for: .milliseconds(34))
        }
        let before = await output.snapshot()
        #expect(before.receivedFrames == 1 && before.idleFrames == 6 && before.repeatedFrames == 2)
        let result = try await output.finish(at: epoch + CMTime(value: 3, timescale: 1))
        #expect(result.videoFrames == 4 && result.audioFrames == 144_000)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(frames)
        #expect(reader.startReading())
        var pictureCount = 0
        while let sample = frames.copyNextSampleBuffer() {
            if sample.presentationTimeStamp == .zero { continue } // Leading empty edit.
            let image = try #require(sample.imageBuffer)
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let pixel = try #require(CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self))
            #expect(pixel[2] > 200 && pixel[0] < 10)
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            pictureCount += 1
        }
        #expect(reader.status == .completed && pictureCount == 4)
    }

    @Test func suspendedCaptureCannotGenerateHeldPictures() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoSampleWriter(url: url, width: 64, height: 48)
        let output = ScreenVideoOutput(writer: writer, epoch: .zero)
        for (time, status): (Int64, SCFrameStatus) in [(0, .complete), (1, .suspended), (2, .idle)] {
            let frame = try sample(red: true, time: CMTime(value: time, timescale: 1), status: status)
            writer.queue.sync { output.append(frame) }
        }
        let metrics = await output.snapshot()
        #expect(metrics.error != nil && metrics.receivedFrames == 1 && metrics.repeatedFrames == 0)
        await #expect(throws: (any Error).self) { try await output.finish(at: CMTime(value: 3, timescale: 1)) }
    }

    @Test func lossOfFrameCallbacksDoesNotMasqueradeAsAStaticScreen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try VideoSampleWriter(url: url, width: 64, height: 48)
        let output = ScreenVideoOutput(writer: writer, epoch: .zero)
        let first = try sample(red: true, time: .zero, status: .complete)
        writer.queue.sync { output.append(first) }
        try await Task.sleep(for: .milliseconds(2100))
        let result = await output.snapshot()
        #expect(result.error != nil && result.repeatedFrames == 0)
        await #expect(throws: (any Error).self) { try await output.finish(at: CMTime(value: 3, timescale: 1)) }
    }

    private func sample(red: Bool, time: CMTime, status: SCFrameStatus) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        let image = try #require(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        let data = try #require(CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self))
        for y in 0..<48 { for x in 0..<64 {
            let i = y * CVPixelBufferGetBytesPerRow(image) + x * 4
            data[i] = red ? 0 : 255; data[i+1] = 0; data[i+2] = red ? 255 : 0; data[i+3] = 255
        }}
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                           formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        let result = try #require(sample)
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true) as? [NSMutableDictionary])
        try #require(attachments.first)[SCStreamFrameInfo.status.rawValue] = status.rawValue
        return result
    }
}
