import ScreenCaptureKit

struct ScreenVideoMetrics: Sendable {
    var receivedFrames = 0
    var firstHostTime: Double?
    var lastHostTime: Double?
    var idleFrames = 0
    var lastIdleHostTime: Double?
    var repeatedFrames = 0
    var error: String?
}

/// Keeps only the latest screen surface, for holding a static final picture.
/// Screen and audio callbacks share the encoders' serial queue and one host epoch.
final class ScreenVideoOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: VideoSampleWriter
    let epoch: CMTime
    private var lastImage: CVPixelBuffer?
    private var lastTime: CMTime?
    private var metrics = ScreenVideoMetrics()
    private var closed = false
    private var stopping = false
    private var lastCallbackReceipt: Double?

    init(writer: VideoSampleWriter, epoch: CMTime) {
        self.writer = writer
        self.epoch = epoch
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        append(sampleBuffer)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(writer.queue))
        guard !closed, metrics.error == nil, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        switch status {
        case .complete:
            lastCallbackReceipt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            guard let image = sampleBuffer.imageBuffer else { metrics.error = "录屏没有收到有效画面。"; return }
            let time = sampleBuffer.presentationTimeStamp
            do {
                try writer.appendVideo(image, at: time - epoch)
                lastImage = image
                lastTime = time - epoch
                metrics.receivedFrames += 1
                metrics.firstHostTime = metrics.firstHostTime ?? time.seconds
                metrics.lastHostTime = time.seconds
            } catch { metrics.error = error.localizedDescription }
        case .idle:
            lastCallbackReceipt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            metrics.idleFrames += 1
            let time = sampleBuffer.presentationTimeStamp
            metrics.lastIdleHostTime = time.isNumeric && time.seconds.isFinite ? time.seconds : nil
            guard !stopping, let image = lastImage, let lastTime else { return }
            let relative = (time - epoch).seconds
            guard relative.isFinite, relative >= 0, relative < Double(Int64.max) else {
                metrics.error = "静止画面没有有效的时间信息。"; return
            }
            // SCK confirms the scene is unchanged. Repeat the captured surface
            // at most once per second so both movie tracks can checkpoint.
            let checkpointTime = CMTime(value: Int64(relative.rounded(.down)), timescale: 1)
            if checkpointTime > lastTime {
                do {
                    try writer.appendVideo(image, at: checkpointTime)
                    self.lastTime = checkpointTime
                    metrics.repeatedFrames += 1
                } catch { metrics.error = error.localizedDescription }
            }
        case .blank, .suspended, .stopped:
            if !stopping { metrics.error = "屏幕采集已中断，正在保存已有内容。" }
        case .started: break
        @unknown default: metrics.error = "无法识别屏幕采集状态。"
        }
    }

    func prepareStop() async {
        await withCheckedContinuation { continuation in
            writer.queue.async { self.stopping = true; continuation.resume() }
        }
    }

    func snapshot() async -> ScreenVideoMetrics {
        await withCheckedContinuation { continuation in
            writer.queue.async {
                if !self.closed, !self.stopping, self.metrics.receivedFrames == 0,
                   (CMClockGetTime(CMClockGetHostTimeClock()) - self.epoch).seconds > 2 {
                    self.metrics.error = self.metrics.error ?? "屏幕采集未返回画面，正在停止。"
                }
                if !self.closed, !self.stopping, let last = self.lastCallbackReceipt,
                   CMClockGetTime(CMClockGetHostTimeClock()).seconds - last > 2 {
                    self.metrics.error = self.metrics.error ?? "屏幕采集停止返回状态，正在保存已有内容。"
                }
                continuation.resume(returning: self.metrics)
            }
        }
    }

    /// Stop the stream first. Hold the last captured picture to the same endpoint
    /// used by the audio mixer; no synthetic motion or substitute screen is added.
    func finish(at hostTime: CMTime) async throws -> VideoWriteSummary {
        // Host-clock addition/subtraction can round at nanosecond precision.
        // Use the mixer's 48k frame grid for an exactly shared final endpoint.
        let end = (hostTime - epoch).convertScale(48_000, method: .roundHalfAwayFromZero)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writer.queue.async {
                defer { self.closed = true; self.lastImage = nil }
                do {
                    guard !self.closed else { throw VideoWriteError.finished }
                    if self.metrics.error == nil, let image = self.lastImage, let last = self.lastTime {
                        let tailStart = end - CMTime(value: 1, timescale: 30)
                        if tailStart > last {
                            try self.writer.appendVideo(image, at: tailStart)
                            self.metrics.repeatedFrames += 1
                        }
                    }
                    continuation.resume()
                } catch { self.metrics.error = error.localizedDescription; continuation.resume() }
            }
        }
        // Always close the encoder even if ScreenCaptureKit reported an error.
        let summary = try await writer.finish(at: end)
        if let error = await snapshot().error { throw VideoWriteError.encoding(error) }
        return summary
    }
}
