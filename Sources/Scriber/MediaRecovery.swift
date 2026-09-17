import AVFoundation

struct RecoveredMedia: Sendable {
    let url: URL
    let kind: RecordingFileKind
    let duration: Double
    let audioFrames: Int64
    let videoFrames: Int64
    let prefix: MovieFilePrefix
}

enum MediaRecovery {
    struct Validation: Sendable {
        let duration: Double
        let audioFrames: Int64
        let videoFrames: Int64
    }
    /// Run under the session lease in a fresh private work directory. Originals
    /// are never moved/rewritten; caller owns cleanup of this work directory.
    @concurrent static func recover(source: URL, kind: RecordingFileKind, workDirectory: URL) async throws -> RecoveredMedia {
        let prefixURL = workDirectory.appendingPathComponent("prefix").appendingPathExtension(kind.rawValue)
        let outputURL = workDirectory.appendingPathComponent("recovered").appendingPathExtension(kind.rawValue)
        let copying = Task.detached { try MovieFilePrefix.copy(from: source, to: prefixURL) }
        let prefix = try await withTaskCancellationHandler(operation: { try await copying.value }, onCancel: { copying.cancel() })
        try Task.checkCancellation()
        let asset = AVURLAsset(url: prefixURL)
        _ = try await tracks(asset, kind: kind)
        guard !FileManager.default.fileExists(atPath: outputURL.path),
              let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaRecoveryError.unsafePath
        }
        // Keep all indexed tracks, including a longer valid video tail. Do not
        // fabricate audio or discard valid data merely to equalize durations.
        try await exporter.export(to: outputURL, as: .mp4)
        try Task.checkCancellation()
        let validation = try await validate(url: outputURL, kind: kind)
        return RecoveredMedia(url: outputURL, kind: kind, duration: validation.duration,
                              audioFrames: validation.audioFrames, videoFrames: validation.videoFrames, prefix: prefix)
    }

    @concurrent static func validate(url: URL, kind: RecordingFileKind) async throws -> Validation {
        let result = AVURLAsset(url: url)
        let recoveredTracks = try await tracks(result, kind: kind)
        var audioFrames: Int64 = 0, videoFrames: Int64 = 0
        for track in recoveredTracks {
            let type = track.mediaType
            let reader = try AVAssetReader(asset: result)
            let settings: [String: Any] = type == .audio ? [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
            ] : [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? MediaRecoveryError.invalidMedia }
            var frames: Int64 = 0
            do {
                while let sample = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    guard sample.isValid, sample.dataReadiness == .ready, sample.numSamples > 0,
                          sample.presentationTimeStamp.isNumeric,
                          sample.presentationTimeStamp.seconds.isFinite else { throw MediaRecoveryError.invalidMedia }
                    if type == .video, sample.imageBuffer == nil { throw MediaRecoveryError.invalidMedia }
                    if type == .audio, sample.dataBuffer == nil { throw MediaRecoveryError.invalidMedia }
                    frames += Int64(sample.numSamples)
                }
            } catch { reader.cancelReading(); throw error }
            guard reader.status == .completed, frames > 0 else { throw reader.error ?? MediaRecoveryError.invalidMedia }
            if type == .audio { audioFrames = frames } else { videoFrames = frames }
        }
        let duration = try await result.load(.duration).seconds
        guard duration.isFinite, duration > 0, audioFrames > 0, kind == .audio || videoFrames > 0 else {
            throw MediaRecoveryError.invalidMedia
        }
        return Validation(duration: duration, audioFrames: audioFrames, videoFrames: videoFrames)
    }

    /// Recover the companion audio from a validated video when the independent
    /// audio file has no usable index. Compressed audio is passed through.
    @concurrent static func extractAudio(videoURL: URL, outputURL: URL) async throws -> Validation {
        let asset = AVURLAsset(url: videoURL)
        let source = try await tracks(asset, kind: .video).first { $0.mediaType == .audio }
        guard let source, !FileManager.default.fileExists(atPath: outputURL.path) else { throw MediaRecoveryError.invalidMedia }
        let composition = AVMutableComposition()
        guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaRecoveryError.invalidMedia
        }
        let range = try await source.load(.timeRange)
        try audio.insertTimeRange(range, of: source, at: range.start)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaRecoveryError.invalidMedia
        }
        try await exporter.export(to: outputURL, as: .mp4)
        try Task.checkCancellation()
        return try await validate(url: outputURL, kind: .audio)
    }

    private static func tracks(_ asset: AVURLAsset, kind: RecordingFileKind) async throws -> [AVAssetTrack] {
        let all = try await asset.load(.tracks)
        var audio = 0, video = 0
        for track in all {
            let type = track.mediaType
            let formats = try await track.load(.formatDescriptions)
            guard !formats.isEmpty else { throw MediaRecoveryError.invalidMedia }
            switch type {
            case .audio:
                audio += 1
                for description in formats {
                    guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
                          CMFormatDescriptionGetMediaSubType(description) == kAudioFormatMPEG4AAC else { throw MediaRecoveryError.invalidMedia }
                    let format = AVAudioFormat(cmAudioFormatDescription: description)
                    guard format.sampleRate.isFinite, (8_000...192_000).contains(format.sampleRate),
                          (1...2).contains(format.channelCount) else { throw MediaRecoveryError.invalidMedia }
                }
            case .video:
                video += 1
                for description in formats {
                    let size = CMVideoFormatDescriptionGetDimensions(description)
                    guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video,
                          CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264,
                          (2...8192).contains(size.width), (2...8192).contains(size.height) else { throw MediaRecoveryError.invalidMedia }
                }
            default: throw MediaRecoveryError.invalidMedia
            }
        }
        guard audio == 1, video == (kind == .video ? 1 : 0) else { throw MediaRecoveryError.invalidMedia }
        return all
    }
}
