import AVFoundation

struct VideoWriteSummary: Sendable {
    let url: URL
    let videoFrames: Int64
    let audioFrames: Int64
    let duration: Double
}

enum VideoWriteError: LocalizedError, Equatable {
    case invalidFormat, invalidTimestamp, backpressure, missingTrack, finished
    case encoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat: "视频或音轨格式与录制配置不一致。"
        case .invalidTimestamp: "音视频时间戳无效或发生倒退。"
        case .backpressure: "视频写入速度不足，录制已中止以避免静默丢帧。"
        case .missingTrack: "录屏没有收到完整的画面和声音数据。"
        case .finished: "视频写入已结束。"
        case .encoding(let message): "视频编码失败：\(message)"
        }
    }
}

/// Queue-confined MP4 encoder. Both inputs use the same zero-based timeline;
/// the capture adapter must subtract a single epoch, never each source's first time.
/// No pending sample arrays are retained; encoder backpressure is an explicit error.
final class VideoSampleWriter: @unchecked Sendable {
    let queue: DispatchQueue
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let url: URL
    private let width: Int
    private let height: Int
    private var videoFrames: Int64 = 0
    private var audioFrames: Int64 = 0
    private var lastVideoTime: CMTime?
    private var videoEnd = CMTime.zero
    private var audioEnd = CMTime.zero
    private var failure: VideoWriteError?
    private var closing = false

    init(url: URL, width: Int, height: Int, queue: DispatchQueue? = nil) throws {
        guard (2...8192).contains(width), (2...8192).contains(height),
              width.isMultiple(of: 2), height.isMultiple(of: 2) else { throw VideoWriteError.invalidFormat }
        self.url = url
        self.width = width
        self.height = height
        self.queue = queue ?? DispatchQueue(label: "scriber.video-writer", qos: .userInitiated,
                                            autoreleaseFrequency: .workItem)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_000_000, min(80_000_000, width * height * 6)),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
        ])
        for input in [video, audio] {
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw VideoWriteError.invalidFormat }
            writer.add(input)
        }
        guard writer.startWriting() else { throw VideoWriteError.encoding(writer.error?.localizedDescription ?? "无法打开输出文件") }
        writer.startSession(atSourceTime: .zero)
    }

    /// Input is uncompressed BGRA from the screen adapter; only timestamps are rebuilt.
    func appendVideo(_ pixels: CVPixelBuffer, at time: CMTime,
                     duration: CMTime = CMTime(value: 1, timescale: 30)) throws {
        try checked {
            guard CVPixelBufferGetWidth(pixels) == width, CVPixelBufferGetHeight(pixels) == height,
                  CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else {
                throw VideoWriteError.invalidFormat
            }
            guard valid(time), time >= .zero, valid(duration), duration > .zero,
                  duration.seconds <= 1, lastVideoTime.map({ time > $0 }) ?? true else {
                throw VideoWriteError.invalidTimestamp
            }
            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixels, formatDescriptionOut: &format) == noErr, let format else {
                throw VideoWriteError.invalidFormat
            }
            var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixels, formatDescription: format, sampleTiming: &timing,
                sampleBufferOut: &sample) == noErr, let sample else { throw VideoWriteError.invalidFormat }
            try append(sample, to: video)
            videoFrames += 1
            lastVideoTime = time
            videoEnd = time + duration
        }
    }

    /// Feed the exact 48k stereo Float32 mixed sample also sent to the M4A writer.
    func appendAudio(_ sample: CMSampleBuffer) throws {
        try checked {
            guard sample.isValid, sample.dataReadiness == .ready,
                  (1...48_000).contains(sample.numSamples), let description = sample.formatDescription,
                  CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else {
                throw VideoWriteError.invalidFormat
            }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            guard format.sampleRate == 48_000, format.channelCount == 2,
                  format.commonFormat == .pcmFormatFloat32 else { throw VideoWriteError.invalidFormat }
            let time = sample.presentationTimeStamp
            guard valid(time), time >= audioEnd else { throw VideoWriteError.invalidTimestamp }
            _ = try AudioSampleWriter.levels(sample, format: format)
            try append(sample, to: audio)
            audioFrames += Int64(sample.numSamples)
            audioEnd = time + CMTime(value: Int64(sample.numSamples), timescale: 48_000)
        }
    }

    func snapshot() async -> (VideoWriteSummary, VideoWriteError?) {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: (self.summary, self.failure)) }
        }
    }

    /// Finalizes a valid written prefix even after a rejected sample, then surfaces
    /// that failure. Neither an empty file nor a missing track can report success.
    func finish() async throws -> VideoWriteSummary {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.closing else { continuation.resume(throwing: VideoWriteError.finished); return }
                self.closing = true
                if self.videoFrames == 0 || self.audioFrames == 0 {
                    self.failure = self.failure ?? .missingTrack
                }
                guard self.videoFrames > 0 || self.audioFrames > 0 else {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: self.failure ?? .missingTrack)
                    return
                }
                guard self.writer.status == .writing else {
                    continuation.resume(throwing: self.failure ?? .encoding(self.writer.error?.localizedDescription ?? "写入已停止"))
                    return
                }
                self.video.markAsFinished()
                self.audio.markAsFinished()
                self.writer.endSession(atSourceTime: max(self.videoEnd, self.audioEnd))
                self.writer.finishWriting {
                    self.queue.async {
                        if let failure = self.failure { continuation.resume(throwing: failure) }
                        else if self.writer.status == .completed { continuation.resume(returning: self.summary) }
                        else { continuation.resume(throwing: VideoWriteError.encoding(self.writer.error?.localizedDescription ?? "输出文件没有正常完成")) }
                    }
                }
            }
        }
    }

    private var summary: VideoWriteSummary {
        VideoWriteSummary(url: url, videoFrames: videoFrames, audioFrames: audioFrames,
                          duration: max(videoEnd, audioEnd).seconds)
    }

    private func checked(_ action: () throws -> Void) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closing else { throw VideoWriteError.finished }
        if let failure { throw failure }
        do { try action() }
        catch {
            let error = error as? VideoWriteError ?? .encoding(error.localizedDescription)
            failure = error
            throw error
        }
    }

    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput) throws {
        guard input.isReadyForMoreMediaData else { throw VideoWriteError.backpressure }
        guard input.append(sample) else {
            throw VideoWriteError.encoding(writer.error?.localizedDescription ?? "无法写入数据")
        }
    }

    private func valid(_ time: CMTime) -> Bool { time.isNumeric && time.seconds.isFinite }
}
