import AVFoundation
import Foundation
import ScreenCaptureKit

// Generated codec/file fixture, paced in real time. This is not screen or microphone capture.

@main
struct CrashWriterFixture {
    static func screenSample(_ image: CVPixelBuffer, time: CMTime, idle: Bool) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescriptionOut: &description) == noErr, let description else { throw VideoWriteError.invalidFormat }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &result) == noErr,
            let result, let attachments = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true) as? [NSMutableDictionary],
            let attachment = attachments.first else { throw VideoWriteError.invalidFormat }
        attachment[SCStreamFrameInfo.status.rawValue] = (idle ? SCFrameStatus.idle : .complete).rawValue
        return result
    }
    static func pixels(_ second: Int) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value) == kCVReturnSuccess,
              let value else { throw AudioWriteError.unexpectedFormat }
        CVPixelBufferLockBaseAddress(value, [])
        defer { CVPixelBufferUnlockBaseAddress(value, []) }
        let data = CVPixelBufferGetBaseAddress(value)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<48 { for x in 0..<64 {
            let i = y * CVPixelBufferGetBytesPerRow(value) + x * 4
            data[i] = second % 2 == 0 ? 0 : 255
            data[i+1] = 0; data[i+2] = second % 2 == 0 ? 255 : 0; data[i+3] = 255
        }}
        return value
    }
    static func main() async throws {
        guard CommandLine.arguments.count >= 3,
              CommandLine.arguments[1].hasPrefix("/"),
              let seconds = Double(CommandLine.arguments[2]), seconds.isFinite, (1...120).contains(seconds) else {
            throw NSError(domain: "CrashWriterFixture", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Usage: CrashWriterFixture /absolute/directory seconds [--sparse-video]"])
        }
        let sparse = CommandLine.arguments.contains("--sparse-video")
        let frameCount = Int(seconds * 48_000)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = try AudioSampleWriter(url: root.appendingPathComponent("audio.m4a"))
        let video = try VideoSampleWriter(url: root.appendingPathComponent("video.mp4"), width: 64, height: 48, queue: audio.queue)
        let screen = ScreenVideoOutput(writer: video, epoch: .zero)
        let clock = ContinuousClock(); let start = clock.now
        for index in 0..<((frameCount + 1599) / 1600) {
            let samples = (0..<min(1600, frameCount - index * 1600)).flatMap { offset -> [Float] in
                let frame = index * 1600 + offset
                let frequency = index / 30 % 2 == 0 ? 880.0 : 1760.0
                let value = Float(sin(Double(frame) * frequency * 2 * .pi / 48_000) * 0.15)
                return [value, value]
            }
            let sample = try MixedAudioOutput.sample(stereo: samples, at: Int64(index * 1600))
            let picture = try pixels(sparse ? 0 : index / 30)
            let screenSample = try screenSample(picture, time: CMTime(value: Int64(index), timescale: 30), idle: sparse && index != 0)
            try audio.queue.sync {
                try audio.appendChecked(sample)
                try video.appendAudio(sample)
                screen.append(screenSample)
            }
            if index % 30 == 0 {
                let metrics = await screen.snapshot()
                guard metrics.error == nil else { throw VideoWriteError.encoding(metrics.error!) }
                let report: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                            "videoFrames": metrics.receivedFrames + metrics.repeatedFrames,
                                            "audioFrames": min(frameCount, (index + 1) * 1600), "mediaSeconds": Double(min(frameCount, (index + 1) * 1600)) / 48_000]
                try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: root.appendingPathComponent("progress.json"), options: .atomic)
            }
            try await clock.sleep(until: start + .nanoseconds(Int64(min(frameCount, (index + 1) * 1600)) * 1_000_000_000 / 48_000))
        }
        let end = CMTime(value: Int64(frameCount), timescale: 48_000)
        _ = try await audio.finish()
        _ = try await screen.finish(at: end)
        print("Finished encoder fixture: \(frameCount) audio frames")
    }
}
