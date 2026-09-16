import AVFoundation
import Foundation

struct AudioWriteSummary: Sendable {
    let url: URL
    let frames: Int64
    let duration: Double
    let powerDBFS: Float
    let peakDBFS: Float
}

enum AudioWriteError: LocalizedError, Equatable {
    case noSamples, unexpectedFormat, invalidTimestamp, backpressure, alreadyFinished
    case encoding(String)

    var errorDescription: String? {
        switch self {
        case .noSamples: "没有收到音频数据。"
        case .unexpectedFormat: "音频格式与录制配置不一致。"
        case .invalidTimestamp: "音频时间戳无效或发生倒退。"
        case .backpressure: "音频写入速度不足，录制已中止以避免静默丢帧。"
        case .alreadyFinished: "音频写入已结束。"
        case .encoding(let message): "音频编码失败：\(message)"
        }
    }
}

/// All mutable state is confined to queue after initialization. Sample buffers
/// are appended synchronously on that queue; no unbounded buffer backlog is kept.
final class AudioSampleWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "scriber.audio-writer", qos: .userInitiated,
                              autoreleaseFrequency: .workItem)
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let url: URL
    private let sampleRate: Double
    private let channels: UInt32
    private var firstTime: CMTime?
    private var lastTime: CMTime?
    private var lastEnd: CMTime?
    private var frames: Int64 = 0
    private var peakDBFS: Float = -160
    private var powerDBFS: Float = -160
    private var failure: AudioWriteError?
    private var closing = false

    init(url: URL, sampleRate: Double = 48_000, channels: UInt32 = 2) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              sampleRate.rounded() == sampleRate, (1...2).contains(channels) else {
            throw AudioWriteError.unexpectedFormat
        }
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw AudioWriteError.unexpectedFormat }
        writer.add(input)
        guard writer.startWriting() else {
            throw AudioWriteError.encoding(writer.error?.localizedDescription ?? "无法打开输出文件")
        }
    }

    /// Invoke only from queue (also pass queue to SCStream's audio output).
    func append(_ sample: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closing, failure == nil else { return }
        do {
            guard sample.isValid, sample.dataReadiness == .ready,
                  let description = sample.formatDescription,
                  CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else {
                throw AudioWriteError.unexpectedFormat
            }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            guard format.sampleRate == sampleRate, format.channelCount == channels,
                  format.commonFormat == .pcmFormatFloat32 else {
                throw AudioWriteError.unexpectedFormat
            }
            let count = sample.numSamples
            guard count > 0 else { return }
            let time = sample.presentationTimeStamp
            guard time.isNumeric, time.seconds.isFinite,
                  lastTime.map({ CMTimeCompare(time, $0) > 0 }) ?? true else {
                throw AudioWriteError.invalidTimestamp
            }
            if firstTime == nil {
                firstTime = time
                writer.startSession(atSourceTime: time)
            }
            let levels = try Self.levels(sample, format: format)
            guard input.isReadyForMoreMediaData else { throw AudioWriteError.backpressure }
            guard input.append(sample) else {
                throw AudioWriteError.encoding(writer.error?.localizedDescription ?? "无法写入音频数据")
            }
            frames += Int64(count)
            lastTime = time
            lastEnd = time + CMTime(value: CMTimeValue(count), timescale: CMTimeScale(sampleRate))
            powerDBFS = levels.power
            peakDBFS = max(peakDBFS, levels.peak)
        } catch let error as AudioWriteError {
            failure = error
        } catch {
            failure = .encoding(error.localizedDescription)
        }
    }

    func snapshot() async -> (AudioWriteSummary, AudioWriteError?) {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: (self.summary, self.failure)) }
        }
    }

    func finish() async throws -> AudioWriteSummary {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.closing else {
                    continuation.resume(throwing: AudioWriteError.alreadyFinished)
                    return
                }
                self.closing = true
                if self.frames == 0 {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: self.failure ?? .noSamples)
                    return
                }
                guard self.writer.status == .writing else {
                    continuation.resume(throwing: self.failure ?? .encoding(
                        self.writer.error?.localizedDescription ?? "写入已停止"))
                    return
                }
                self.input.markAsFinished()
                self.writer.finishWriting {
                    self.queue.async {
                        if self.writer.status == .completed {
                            if let error = self.failure { continuation.resume(throwing: error) }
                            else { continuation.resume(returning: self.summary) }
                        } else {
                            continuation.resume(throwing: AudioWriteError.encoding(
                                self.writer.error?.localizedDescription ?? "输出文件没有正常完成"))
                        }
                    }
                }
            }
        }
    }

    private var summary: AudioWriteSummary {
        AudioWriteSummary(url: url, frames: frames,
                          duration: firstTime.flatMap { first in lastEnd.map { ($0 - first).seconds } } ?? 0,
                          powerDBFS: powerDBFS,
                          peakDBFS: peakDBFS)
    }

    private static func levels(_ sample: CMSampleBuffer, format: AVAudioFormat) throws -> (power: Float, peak: Float) {
        let count = sample.numSamples
        guard count <= Int(Int32.max),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw AudioWriteError.unexpectedFormat
        }
        pcm.frameLength = AVAudioFrameCount(count)
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList)
        guard result == noErr, let data = pcm.floatChannelData else {
            throw AudioWriteError.unexpectedFormat
        }
        var peak: Float = 0
        var squares: Double = 0
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<count {
                let value = format.isInterleaved
                    ? data[0][frame * Int(format.channelCount) + channel] : data[channel][frame]
                guard value.isFinite else { throw AudioWriteError.unexpectedFormat }
                peak = max(peak, abs(value))
                squares += Double(value) * Double(value)
            }
        }
        let rms = sqrt(squares / Double(count * Int(format.channelCount)))
        return (rms > 0 ? max(-160, Float(20 * log10(rms))) : -160,
                peak > 0 ? max(-160, 20 * log10(peak)) : -160)
    }
}
