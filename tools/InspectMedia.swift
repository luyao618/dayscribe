import AVFoundation
import CryptoKit

// Read-only native decoding evidence; this does not play or capture any media.
@main
struct InspectMedia {
    static func timeValue(_ value: Double?) -> Any {
        guard let value, value.isFinite else { return NSNull() }
        return value
    }

    static func main() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--compare-audio" {
            let left = try await PCMReader(path: CommandLine.arguments[2])
            let right = try await PCMReader(path: CommandLine.arguments[3])
            var count = 0
            var maximum = 0.0
            var squares = 0.0
            while let a = try left.next() {
                guard let b = try right.next() else { throw CocoaError(.fileReadCorruptFile) }
                let error = abs(Double(a) - Double(b))
                guard error.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                maximum = max(maximum, error); squares += error * error; count += 1
            }
            guard try right.next() == nil, count > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let result: [String: Any] = ["samples": count, "maxError": maximum, "rmsError": sqrt(squares / Double(count))]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
            return
        }
        var files: [[String: Any]] = []
        for path in CommandLine.arguments.dropFirst() {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            var report: [String: Any] = ["path": path, "duration": timeValue(try await asset.load(.duration).seconds)]
            var streams: [[String: Any]] = []
            for type in [AVMediaType.audio, .video] {
                for track in try await asset.loadTracks(withMediaType: type) {
                    let reader = try AVAssetReader(asset: asset)
                    let settings: [String: Any] = type == .audio ? [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
                    ] : [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                    reader.add(output)
                    guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
                    var frames: Int64 = 0
                    var first: Double?
                    var end = 0.0
                    var hash = SHA256()
                    while let sample = output.copyNextSampleBuffer() {
                        first = first ?? sample.presentationTimeStamp.seconds
                        frames += Int64(sample.numSamples)
                        if type == .audio {
                            guard let description = sample.formatDescription else { throw CocoaError(.fileReadCorruptFile) }
                            let format = AVAudioFormat(cmAudioFormatDescription: description)
                            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(sample.numSamples)) else {
                                throw CocoaError(.fileReadCorruptFile)
                            }
                            pcm.frameLength = UInt32(sample.numSamples)
                            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples),
                                into: pcm.mutableAudioBufferList) == noErr else { throw CocoaError(.fileReadCorruptFile) }
                            for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
                                if let data = buffer.mData { hash.update(data: Data(bytes: data, count: Int(buffer.mDataByteSize))) }
                            }
                            end = sample.presentationTimeStamp.seconds + Double(sample.numSamples) / format.sampleRate
                        } else { end = sample.presentationTimeStamp.seconds + sample.duration.seconds }
                    }
                    guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
                    let range = try await track.load(.timeRange)
                    streams.append(["type": type == .audio ? "audio" : "video", "frames": frames,
                                    "first": timeValue(first), "end": timeValue(end), "trackEnd": timeValue(range.end.seconds),
                                    "pcmSHA256": type == .audio ? hash.finalize().map { String(format: "%02x", $0) }.joined() : ""])
                }
            }
            report["streams"] = streams
            files.append(report)
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: files, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}

/// Bounded chunks let native decoders use their own packet sizes. Float32 AAC
/// decoding can differ by rounding even for identical compressed audio data.
private final class PCMReader {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    private var values: [Float] = []
    private var cursor = 0

    init(path: String) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    }

    func next() throws -> Float? {
        while cursor == values.count {
            guard let sample = output.copyNextSampleBuffer() else {
                guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
                return nil
            }
            guard let description = sample.formatDescription else { throw CocoaError(.fileReadCorruptFile) }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            guard format.isInterleaved, format.commonFormat == .pcmFormatFloat32,
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(sample.numSamples)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            pcm.frameLength = UInt32(sample.numSamples)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples),
                into: pcm.mutableAudioBufferList) == noErr, let data = pcm.floatChannelData?[0] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            values = Array(UnsafeBufferPointer(start: data, count: sample.numSamples * Int(format.channelCount)))
            cursor = 0
        }
        defer { cursor += 1 }
        return values[cursor]
    }
}
