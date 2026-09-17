import AVFoundation
import ScreenCaptureKit

struct AudioCaptureMetrics: Sendable {
    var nativeFrames: [AudioSource: Int64] = [:]
    var receivedFrames: [AudioSource: Int64] = [:]
    var discardedPowerDBFS: [AudioSource: Float] = [:]
    var nativeRates: [AudioSource: Double] = [:]
    var firstTimes: [AudioSource: Double] = [:]
    var lastTimes: [AudioSource: Double] = [:]
    var hostDelaySeconds: [AudioSource: Double] = [:]
    var powerDBFS: [AudioSource: Float] = [:]
    var maximumPowerDBFS: [AudioSource: Float] = [:]
    var maximumClockSkewFrames: [AudioSource: Double] = [:]
    var clippedSamples: Int64 = 0
    var errorMessage: String?
}

/// SCStream callbacks, converter state, mixer and encoder all share writer.queue.
/// Startup buffering is capped by both bytes and timestamp span, then replayed
/// in capture-time order once each selected source has delivered its first data.
final class MixedAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: AudioSampleWriter
    private var sources: Set<AudioSource>
    private let mixer: AudioTimelineMixer
    private var epoch: CMTime?
    private let requestedEpoch: CMTime?
    private let onMixedSample: ((CMSampleBuffer) -> Void)?
    private var startup: [(source: AudioSource, sample: CMSampleBuffer)] = []
    private var startupBytes = 0
    private var segments: [AudioSource: ConvertedSegment] = [:]
    private var metrics = AudioCaptureMetrics()
    private var closed = false

    init(writer: AudioSampleWriter, sources: Set<AudioSource>, epoch: CMTime? = nil,
         onMixedSample: ((CMSampleBuffer) -> Void)? = nil) throws {
        guard epoch.map({ $0.isNumeric && $0.seconds.isFinite }) ?? true else { throw AudioMixError.invalidTimeline }
        self.requestedEpoch = epoch
        self.onMixedSample = onMixedSample
        self.writer = writer
        self.sources = sources
        self.mixer = try AudioTimelineMixer(sources: sources)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if type == .audio { append(sampleBuffer, source: .system) }
        if type == .microphone { append(sampleBuffer, source: .microphone) }
    }

    func append(_ sample: CMSampleBuffer, source: AudioSource) {
        dispatchPrecondition(condition: .onQueue(writer.queue))
        guard !closed, metrics.errorMessage == nil else { return }
        guard sample.isValid, sample.dataReadiness == .ready, sample.numSamples > 0 else { return }
        metrics.receivedFrames[source, default: 0] += Int64(sample.numSamples)
        guard sources.contains(source) else {
            if let description = sample.formatDescription,
               CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
               let level = try? AudioSampleWriter.levels(sample, format: AVAudioFormat(cmAudioFormatDescription: description)) {
                metrics.discardedPowerDBFS[source] = level.power
            }
            return
        }
        do {
            let time = sample.presentationTimeStamp
            guard time.isNumeric, time.seconds.isFinite, let description = sample.formatDescription,
                  CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else {
                throw AudioMixError.invalidTimeline
            }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            guard format.sampleRate.isFinite, (8_000...192_000).contains(format.sampleRate),
                  sample.numSamples <= Int(format.sampleRate) else { throw AudioMixError.invalidSamples }
            metrics.nativeFrames[source, default: 0] += Int64(sample.numSamples)
            metrics.nativeRates[source] = format.sampleRate
            if metrics.firstTimes[source] == nil { metrics.firstTimes[source] = time.seconds }
            metrics.lastTimes[source] = time.seconds
            metrics.hostDelaySeconds[source] = (CMClockGetTime(CMClockGetHostTimeClock()) - time).seconds
            if epoch == nil {
                startupBytes += CMSampleBufferGetTotalSampleSize(sample)
                startup.append((source, sample))
                let first = startup.map(\.sample.presentationTimeStamp).min { CMTimeCompare($0, $1) < 0 } ?? time
                guard startupBytes <= 8 * 1_024 * 1_024, startup.count <= 256,
                      (time - first).seconds <= 2 else { throw AudioMixError.bufferOverflow }
                guard sources.allSatisfy({ metrics.firstTimes[$0] != nil }) else { return }
                epoch = requestedEpoch ?? first
                let ordered = startup.sorted { CMTimeCompare($0.sample.presentationTimeStamp, $1.sample.presentationTimeStamp) < 0 }
                startup.removeAll()
                startupBytes = 0
                for item in ordered { try process(item.sample, source: item.source) }
            } else {
                try process(sample, source: source)
            }
        } catch { metrics.errorMessage = error.localizedDescription }
    }

    /// Gate the mix at the user's action time while in-flight capture callbacks
    /// can still deliver samples from before that time. Hardware follows next.
    func prepareSources(_ selected: Set<AudioSource>, at time: CMTime) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writer.queue.async {
                do {
                    guard !self.closed, self.metrics.errorMessage == nil else { throw AudioMixError.finished }
                    try self.mixer.setSources(selected, at: self.frame(time))
                    self.sources.formUnion(selected)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Called after disabled streams stop, behind queued callbacks.
    /// Flush disabled converters now so re-enabling starts a fresh timed segment.
    func completeSources(_ selected: Set<AudioSource>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writer.queue.async {
                do {
                    guard !self.closed, self.metrics.errorMessage == nil else { throw AudioMixError.finished }
                    for source in self.sources.subtracting(selected) {
                        if let segment = self.segments[source] {
                            try self.push(try segment.converter.finish(), segment: segment, source: source)
                        }
                        self.segments[source] = nil
                        self.metrics.powerDBFS[source] = -160
                        self.metrics.lastTimes[source] = nil
                    }
                    self.sources = selected
                    continuation.resume()
                } catch {
                    self.metrics.errorMessage = error.localizedDescription
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func snapshot() async -> AudioCaptureMetrics {
        await withCheckedContinuation { continuation in
            writer.queue.async { continuation.resume(returning: self.metrics) }
        }
    }

    /// Stop SCStream first, then finish converters and mixer before the encoder.
    func finish(at hostTime: CMTime? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writer.queue.async {
                defer { self.closed = true; self.startup.removeAll(); self.segments.removeAll() }
                do {
                    guard !self.closed else { throw AudioMixError.finished }
                    if let message = self.metrics.errorMessage { throw AudioWriteError.encoding(message) }
                    guard self.epoch != nil else { throw AudioWriteError.noSamples }
                    for source in AudioSource.allCases {
                        if let segment = self.segments[source] {
                            try self.push(try segment.converter.finish(), segment: segment, source: source)
                        }
                    }
                    try self.mixer.finish(at: try hostTime.map { try self.frame($0) }, emit: self.emit)
                    continuation.resume()
                } catch {
                    if self.metrics.errorMessage == nil { self.metrics.errorMessage = error.localizedDescription }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func process(_ sample: CMSampleBuffer, source: AudioSource) throws {
        guard let description = sample.formatDescription else { throw AudioMixError.invalidSamples }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let time = sample.presentationTimeStamp
        if let previous = segments[source] {
            let gap = (time - previous.lastInputEnd).seconds
            if !previous.converter.inputFormat.isEqual(format) || abs(gap) > 2 / format.sampleRate {
                try push(try previous.converter.finish(), segment: previous, source: source)
                segments[source] = nil
            }
        }
        if segments[source] == nil {
            segments[source] = try ConvertedSegment(format: format, time: time, firstFrame: frame(time))
        }
        guard let segment = segments[source] else { throw AudioMixError.invalidTimeline }
        let predicted = Double(segment.firstFrame) + Double(segment.inputFrames) * 48_000 / format.sampleRate
        let skew = abs(Double(try frame(time)) - predicted)
        metrics.maximumClockSkewFrames[source] = max(metrics.maximumClockSkewFrames[source, default: 0], skew)
        let converted = try segment.converter.convert(sample)
        segment.inputFrames += Int64(sample.numSamples)
        segment.lastInputEnd = time + CMTime(value: Int64(sample.numSamples), timescale: Int32(format.sampleRate))
        try push(converted, segment: segment, source: source)
    }

    private func push(_ stereo: [Float], segment: ConvertedSegment, source: AudioSource) throws {
        guard !stereo.isEmpty else { return }
        try mixer.append(source, stereo: stereo, at: segment.firstFrame + segment.outputFrames, emit: emit)
        segment.outputFrames += Int64(stereo.count / 2)
    }

    private func frame(_ time: CMTime) throws -> Int64 {
        guard let epoch else { throw AudioMixError.invalidTimeline }
        let offset = (time - epoch).convertScale(48_000, method: .roundHalfAwayFromZero)
        guard offset.isNumeric else { throw AudioMixError.invalidTimeline }
        return offset.value
    }

    private func emit(_ block: MixedAudioBlock) throws {
        let sample = try Self.sample(stereo: block.stereo, at: block.startFrame)
        try writer.appendChecked(sample)
        onMixedSample?(sample)
        metrics.powerDBFS[.system] = block.systemPowerDBFS
        metrics.powerDBFS[.microphone] = block.microphonePowerDBFS
        for source in AudioSource.allCases {
            metrics.maximumPowerDBFS[source] = max(metrics.maximumPowerDBFS[source, default: -160],
                                                   metrics.powerDBFS[source, default: -160])
        }
        metrics.clippedSamples += Int64(block.clippedSamples)
    }

    static func sample(stereo: [Float], at frame: Int64) throws -> CMSampleBuffer {
        guard !stereo.isEmpty, stereo.count % 2 == 0, stereo.count <= 96_000,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                         channels: 2, interleaved: true),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(stereo.count / 2)),
              let data = pcm.floatChannelData?[0] else { throw AudioMixError.invalidSamples }
        pcm.frameLength = UInt32(stereo.count / 2)
        stereo.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { data.update(from: base, count: stereo.count) }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                       presentationTimeStamp: CMTime(value: frame, timescale: 48_000),
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                                   sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
              let sample, CMSampleBufferSetDataBufferFromAudioBufferList(sample,
                  blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                  flags: 0, bufferList: pcm.audioBufferList) == noErr else { throw AudioMixError.invalidSamples }
        return sample
    }
}

private final class ConvertedSegment {
    let converter: AudioPCMConverter
    let firstFrame: Int64
    var lastInputEnd: CMTime
    var inputFrames: Int64 = 0
    var outputFrames: Int64 = 0
    init(format: AVAudioFormat, time: CMTime, firstFrame: Int64) throws {
        converter = try AudioPCMConverter(inputFormat: format)
        self.firstFrame = firstFrame
        self.lastInputEnd = time
    }
}
