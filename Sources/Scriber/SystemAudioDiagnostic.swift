import AppKit
import CoreMedia
import Foundation
import SwiftUI

@MainActor
final class SystemAudioDiagnostic {
    let recorder = AudioRecorder()
    private let directory: URL
    private let seconds: Double
    private let sources: Set<AudioSource>
    private let microphoneDeviceID: String?
    private let switchSources: Bool
    private let panelSnapshots: Bool
    private var switching: Task<Void, Never>?
    private var sourceEvents: [[String: Any]] = []
    private var trace: [[String: Any]] = []
    private var renderedRecording = false
    private let onStatus: (String) -> Void
    private let onFinished: () -> Void
    private var timer: Task<Void, Never>?
    private var sentCompletion = false
    private let clock = ContinuousClock()
    private var started: ContinuousClock.Instant?

    init(directory: URL, seconds: Double, sources: Set<AudioSource> = [.system],
         microphoneDeviceID: String? = nil, switchSources: Bool = false, panelSnapshots: Bool = false,
         onStatus: @escaping (String) -> Void,
         onFinished: @escaping () -> Void) {
        self.directory = directory
        self.seconds = seconds
        self.sources = sources
        self.microphoneDeviceID = microphoneDeviceID
        self.switchSources = switchSources
        self.panelSnapshots = panelSnapshots
        self.onStatus = onStatus
        self.onFinished = onFinished
    }

    func start() {
        recorder.onUpdate = { [weak self] in self?.publish() }
        timer = Task { [weak self] in
            guard let self else { return }
            await recorder.start(directory: directory, sources: sources, microphoneDeviceID: microphoneDeviceID)
            guard recorder.state == .recording, !Task.isCancelled else { return }
            if switchSources {
                switching = Task { [weak self] in
                    guard let self else { return }
                    for selected: Set<AudioSource> in [[.system], [.microphone], [.system, .microphone], []] {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        guard self.recorder.isRecording else { return }
                        let requested = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                        let success = await self.recorder.setSources(selected)
                        self.sourceEvents.append(["sources": selected.map { $0.rawValue }.sorted(),
                                                  "requestedHostTime": requested, "success": success,
                                                  "appliedHostTime": CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                                                  "message": self.recorder.controlMessage ?? self.recorder.errorMessage ?? ""])
                    }
                }
            }
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            await recorder.stop()
        }
    }

    func stop() async {
        timer?.cancel()
        switching?.cancel()
        await recorder.stop(interrupted: true)
    }

    private func keyed<T>(_ values: [AudioSource: T]) -> [String: T] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key == .system ? "system" : "microphone", $0.value) })
    }

    private func publish() {
        guard !sentCompletion else { return }
        if recorder.state == .recording, started == nil { started = clock.now }
        let wall = started.map { instant in
            let duration = instant.duration(to: clock.now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        } ?? 0
        let finished = recorder.state == .completed || recorder.state == .failed
        let status = recorder.state == .completed && recorder.interrupted ? "interrupted" : recorder.state.rawValue
        if switchSources, trace.count < 512 {
            trace.append(["hostTime": CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                          "sources": recorder.sources.map { $0.rawValue }.sorted(),
                          "receivedFrames": keyed(recorder.captureMetrics.receivedFrames),
                          "discardedPowerDBFS": keyed(recorder.captureMetrics.discardedPowerDBFS),
                          "powerDBFS": keyed(recorder.captureMetrics.powerDBFS)])
        }
        if panelSnapshots {
            if recorder.isRecording, (recorder.summary?.duration ?? 0) > 1, !renderedRecording {
                renderPanel("panel-recording.png")
                renderedRecording = true
            }
            if finished { renderPanel(recorder.state == .completed ? "panel-saved.png" : "panel-failed.png") }
        }
        let result: [String: Any] = [
            "status": status,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "path": recorder.outputURL?.path ?? "",
            "error": recorder.errorMessage ?? "",
            "frames": recorder.summary?.frames ?? 0,
            "durationSeconds": recorder.summary?.duration ?? 0,
            "wallElapsedSeconds": wall,
            "requestedDurationSeconds": seconds,
            "powerDBFS": recorder.summary?.powerDBFS ?? -160,
            "peakDBFS": recorder.summary?.peakDBFS ?? -160,
            "sourceFrames": keyed(recorder.captureMetrics.nativeFrames),
            "sourceRates": keyed(recorder.captureMetrics.nativeRates),
            "sourceFirstTimes": keyed(recorder.captureMetrics.firstTimes),
            "sourceHostDelaySeconds": keyed(recorder.captureMetrics.hostDelaySeconds),
            "sourcePowerDBFS": keyed(recorder.captureMetrics.powerDBFS),
            "sourceMaximumPowerDBFS": keyed(recorder.captureMetrics.maximumPowerDBFS),
            "sourceMaximumClockSkewFrames": keyed(recorder.captureMetrics.maximumClockSkewFrames),
            "clippedSamples": recorder.captureMetrics.clippedSamples,
            "sources": recorder.sources.map { $0.rawValue }.sorted(),
            "sourceEvents": sourceEvents,
            "sourceTrace": trace,
            "microphoneName": recorder.microphoneName
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
            if finished { try data.write(to: directory.appendingPathComponent("result.json"), options: .atomic) }
        } catch {
            NSLog("System-audio diagnostic write failed: %@", error.localizedDescription)
        }
        onStatus(recorder.state.active ? String(format: " 录音 %.0fs", wall) : "")
        if finished {
            sentCompletion = true
            timer?.cancel()
            switching?.cancel()
            timer = nil
            onFinished()
        }
    }

    // Renders our own SwiftUI view from live capture state; not a desktop screenshot.
    private func renderPanel(_ filename: String) {
        let view = RecorderPanel(recorder: recorder, onQuit: {}).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: directory.appendingPathComponent(filename), options: .atomic) }
        catch { NSLog("Panel snapshot failed: %@", error.localizedDescription) }
    }
}
