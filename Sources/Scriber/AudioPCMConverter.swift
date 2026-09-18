import AVFoundation

/// One instance per continuous source format, confined to the capture queue.
/// Preserves converter state between callbacks; resetting for each packet would
/// repeat filter priming and lose samples. The adapter handles capture timestamps
/// and must finish/recreate this converter when a source format or timeline changes.
final class AudioPCMConverter {
    enum Failure: LocalizedError, Equatable {
        case format, input, conversion, finished
        case duration(expectedFrames: Int64, availableFrames: Int64)
        var errorDescription: String? {
            switch self {
            case .format: L10n.text("无法处理当前声音设备的音频格式。")
            case .input: L10n.text("声音数据无效或单次数据过大。")
            case .conversion: L10n.text("声音格式转换失败。")
            case .duration: L10n.text("转换后的声音时长不一致。")
            case .finished: L10n.text("声音格式转换已结束。")
            }
        }
    }

    let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var inputFrames: Int64 = 0
    private var outputFrames: Int64 = 0
    private var closed = false

    init(inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate.isFinite, (8_000...192_000).contains(inputFormat.sampleRate),
              inputFormat.sampleRate.rounded() == inputFormat.sampleRate,
              (1...2).contains(inputFormat.channelCount), inputFormat.commonFormat != .otherFormat,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                         channels: 2, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: output) else {
            throw Failure.format
        }
        self.inputFormat = inputFormat
        self.outputFormat = output
        self.converter = converter
        // Normal mode reads ahead without shifting the output timeline. The
        // alternative .none adds filter latency (verified by impulse tests).
        converter.primeMethod = .normal
        converter.channelMap = inputFormat.channelCount == 1 ? [0, 0] : [0, 1]
    }

    func convert(_ sample: CMSampleBuffer) throws -> [Float] {
        guard !closed else { throw Failure.finished }
        guard sample.isValid, sample.dataReadiness == .ready,
              let description = sample.formatDescription,
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              inputFormat.isEqual(AVAudioFormat(cmAudioFormatDescription: description)),
              sample.numSamples > 0, sample.numSamples <= Int(inputFormat.sampleRate),
              let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                        frameCapacity: AVAudioFrameCount(sample.numSamples)) else {
            throw Failure.input
        }
        pcm.frameLength = AVAudioFrameCount(sample.numSamples)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(sample.numSamples), into: pcm.mutableAudioBufferList) == noErr else {
            throw Failure.input
        }
        return try convert(pcm)
    }

    func convert(_ pcm: AVAudioPCMBuffer) throws -> [Float] {
        guard !closed else { throw Failure.finished }
        do {
            guard pcm.format.isEqual(inputFormat), pcm.frameLength > 0,
                  pcm.frameLength <= AVAudioFrameCount(inputFormat.sampleRate) else { throw Failure.input }
            let output = try drain(PCMInputSupply(pcm: pcm))
            inputFrames += Int64(pcm.frameLength)
            outputFrames += Int64(output.count / 2)
            return output
        } catch {
            closed = true
            throw error
        }
    }

    /// End-of-stream releases the resampler's delayed tail. Discard only filter
    /// padding beyond the last complete 48 kHz frame. Round once for the whole
    /// stream, never per packet, to avoid accumulating fractional-frame losses.
    func finish() throws -> [Float] {
        guard !closed else { throw Failure.finished }
        closed = true
        guard inputFrames > 0 else { return [] }
        let tail = try drain(PCMInputSupply(pcm: nil))
        let target = Int64(floor(Double(inputFrames) * 48_000 / inputFormat.sampleRate))
        let needed = target - outputFrames
        guard needed >= 0, needed <= Int64(tail.count / 2) else {
            throw Failure.duration(expectedFrames: target, availableFrames: outputFrames + Int64(tail.count / 2))
        }
        outputFrames += needed
        return Array(tail.prefix(Int(needed) * 2))
    }

    private func drain(_ supply: PCMInputSupply) throws -> [Float] {
        var result: [Float] = []
        // One input callback is limited to one second. Extra room is solely for
        // the resampling filter's tail; enforce a hard output/memory ceiling.
        let maximumFrames = 48_000 + 8_192
        while true {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else {
                throw Failure.conversion
            }
            var error: NSError?
            let status = converter.convert(to: pcm, error: &error) { _, status in supply.take(status) }
            guard status != .error, error == nil, let samples = pcm.floatChannelData?[0] else {
                throw Failure.conversion
            }
            let count = Int(pcm.frameLength) * 2
            guard result.count + count <= maximumFrames * 2 else { throw Failure.conversion }
            let values = UnsafeBufferPointer(start: samples, count: count)
            guard values.allSatisfy(\.isFinite) else { throw Failure.input }
            result.append(contentsOf: values)
            switch status {
            case .inputRanDry, .endOfStream: return result
            case .haveData:
                guard count > 0 else { throw Failure.conversion }
            case .error: throw Failure.conversion
            @unknown default: throw Failure.conversion
            }
        }
    }
}

/// AVAudioConverter invokes its Sendable input block synchronously during convert.
/// This single-use box is never shared between concurrent converter calls.
private final class PCMInputSupply: @unchecked Sendable {
    let pcm: AVAudioPCMBuffer?
    private var supplied = false
    init(pcm: AVAudioPCMBuffer?) { self.pcm = pcm }

    func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let pcm else { status.pointee = .endOfStream; return nil }
        guard !supplied else { status.pointee = .noDataNow; return nil }
        supplied = true
        status.pointee = .haveData
        return pcm
    }
}
