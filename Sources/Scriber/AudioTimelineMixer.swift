import Foundation

enum AudioSource: Int, CaseIterable, Sendable { case system, microphone }

enum AudioMixError: LocalizedError, Equatable {
    case invalidConfiguration, invalidSamples, invalidTimeline
    case lateInput, overlappingInput, bufferOverflow, invalidSourceChange, finished

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "无法创建混音配置。"
        case .invalidSamples: "收到无法处理的声音数据。"
        case .invalidTimeline: "音频时间信息无效。"
        case .lateInput: "某一路声音到达过晚，无法继续同步。"
        case .overlappingInput: "某一路声音的时间发生重叠。"
        case .bufferOverflow: "声音同步间隔过大，无法继续录制。"
        case .invalidSourceChange: "无法在指定时间更改声音来源。"
        case .finished: "混音已结束。"
        }
    }
}

struct MixedAudioBlock: Sendable {
    let startFrame: Int64
    let stereo: [Float]
    let systemPowerDBFS: Float
    let microphonePowerDBFS: Float
    let clippedSamples: Int
    var frameCount: Int { stereo.count / 2 }
}

/// Queue-confined, 48 kHz stereo mixing. The capture adapter must convert each
/// source's native format and map its capture timestamp to this shared epoch.
/// Emit synchronously into the writer; neither PCM nor output closures accumulate.
final class AudioTimelineMixer {
    static let sampleRate = 48_000
    let capacityFrames: Int
    private let blockFrames: Int
    private let holdbackFrames: Int
    private var rings: [[Float]]
    private var sourceEnds: [Int64?] = [nil, nil]
    private var enabled: Set<AudioSource>
    private var changes: [(frame: Int64, sources: Set<AudioSource>)] = []
    private(set) var cursor: Int64 = 0
    private var latestEnd: Int64 = 0
    private var closed = false
    var bufferedFrames: Int64 { latestEnd - cursor }

    init(sources: Set<AudioSource>, capacityFrames: Int = 96_000,
         blockFrames: Int = 960, holdbackFrames: Int = 12_000) throws {
        guard !sources.isEmpty, capacityFrames > 0, capacityFrames <= 192_000,
              blockFrames > 0, holdbackFrames >= 0,
              blockFrames <= capacityFrames, holdbackFrames <= capacityFrames - blockFrames else {
            throw AudioMixError.invalidConfiguration
        }
        self.enabled = sources
        self.capacityFrames = capacityFrames
        self.blockFrames = blockFrames
        self.holdbackFrames = holdbackFrames
        rings = Array(repeating: Array(repeating: 0, count: capacityFrames * 2), count: 2)
    }

    /// Changes are timestamped so a UI click cannot mute audio retroactively
    /// merely because it is still waiting in the synchronization buffer.
    func setSources(_ sources: Set<AudioSource>, at frame: Int64) throws {
        guard !closed else { throw AudioMixError.finished }
        guard !sources.isEmpty, frame >= cursor, frame - cursor <= Int64(capacityFrames),
              changes.last.map({ frame >= $0.frame }) ?? true else {
            throw AudioMixError.invalidSourceChange
        }
        if changes.last?.frame == frame { changes.removeLast() }
        guard changes.count < 256 else { throw AudioMixError.invalidSourceChange }
        changes.append((frame, sources))
    }

    /// Input is interleaved stereo, normalized to 48 kHz. Different sources may
    /// arrive out of order within holdback; a source itself must be monotonic.
    func append(_ source: AudioSource, stereo: [Float], at startFrame: Int64,
                emit: (MixedAudioBlock) throws -> Void) throws {
        guard !closed else { throw AudioMixError.finished }
        do {
            guard !stereo.isEmpty, stereo.count % 2 == 0,
                  stereo.count / 2 <= capacityFrames, stereo.allSatisfy(\.isFinite) else {
                throw AudioMixError.invalidSamples
            }
            let frames = stereo.count / 2
            let (end, overflow) = startFrame.addingReportingOverflow(Int64(frames))
            guard !overflow else { throw AudioMixError.invalidTimeline }
            // Capture may include a small prefix preceding the requested epoch.
            guard end > 0 else { return }
            let first = max(0, startFrame)
            guard first >= cursor else { throw AudioMixError.lateInput }
            guard sourceEnds[source.rawValue].map({ startFrame >= $0 }) ?? true else {
                throw AudioMixError.overlappingInput
            }
            guard end - cursor <= Int64(capacityFrames) else { throw AudioMixError.bufferOverflow }
            for frame in first..<end {
                let input = Int(frame - startFrame) * 2
                let slot = Int(frame % Int64(capacityFrames)) * 2
                rings[source.rawValue][slot] = stereo[input]
                rings[source.rawValue][slot + 1] = stereo[input + 1]
            }
            sourceEnds[source.rawValue] = end
            latestEnd = max(latestEnd, end)
            let ready = max(0, latestEnd - Int64(holdbackFrames))
            let completeBlocks = ready / Int64(blockFrames) * Int64(blockFrames)
            try drain(until: completeBlocks, emit: emit)
        } catch {
            closed = true
            throw error
        }
    }

    /// Drain the held tail, including any requested trailing silence. Excessive
    /// gaps fail explicitly instead of writing hours of invented silent capture.
    func finish(at endFrame: Int64? = nil, emit: (MixedAudioBlock) throws -> Void) throws {
        guard !closed else { throw AudioMixError.finished }
        closed = true
        let end = endFrame ?? latestEnd
        guard end >= cursor, end - cursor <= Int64(capacityFrames) else {
            throw AudioMixError.invalidTimeline
        }
        try drain(until: end, emit: emit)
        latestEnd = end
    }

    private func drain(until end: Int64, emit: (MixedAudioBlock) throws -> Void) throws {
        while cursor < end {
            let count = Int(min(Int64(blockFrames), end - cursor))
            var output = [Float](repeating: 0, count: count * 2)
            var squares = [Double](repeating: 0, count: 2)
            var clipped = 0
            for offset in 0..<count {
                let frame = cursor + Int64(offset)
                while let change = changes.first, change.frame <= frame {
                    enabled = change.sources
                    changes.removeFirst()
                }
                let slot = Int(frame % Int64(capacityFrames)) * 2
                for channel in 0..<2 {
                    var mixed: Double = 0
                    for source in AudioSource.allCases {
                        let value = enabled.contains(source) ? Double(rings[source.rawValue][slot + channel]) : 0
                        mixed += value
                        squares[source.rawValue] += value * value
                    }
                    if abs(mixed) > 1 { clipped += 1 }
                    output[offset * 2 + channel] = Float(min(1, max(-1, mixed)))
                }
            }
            let divisor = Double(count * 2)
            let levels = squares.map { square in
                square > 0 ? max(-160, Float(10 * log10(square / divisor))) : -160
            }
            try emit(MixedAudioBlock(startFrame: cursor, stereo: output,
                                     systemPowerDBFS: levels[0], microphonePowerDBFS: levels[1],
                                     clippedSamples: clipped))
            // Only reclaim the block after downstream accepted it.
            for offset in 0..<count {
                let slot = Int((cursor + Int64(offset)) % Int64(capacityFrames)) * 2
                for source in AudioSource.allCases {
                    rings[source.rawValue][slot] = 0
                    rings[source.rawValue][slot + 1] = 0
                }
            }
            cursor += Int64(count)
        }
    }
}
