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
    private let recordScreen: Bool
    private let captureRequest: CaptureRequest?
    private let renameCheck: Bool
    private let interruptSource: AudioSource?
    private let reportSourceFailure: Bool
    private let persistentInterruption: Bool
    private let failedAdditionCheck: Bool
    private var interrupting: Task<Void, Never>?
    private var stoppedDuringRecovery = false
    private var renaming: Task<Void, Never>?
    private var renameEvent: [String: Any] = [:]
    private var switching: Task<Void, Never>?
    private var sourceEvents: [[String: Any]] = []
    private var trace: [[String: Any]] = []
    private var renderedRecording = false
    private var renderedRecovery = false
    private let onStatus: (String) -> Void
    private let onFinished: () -> Void
    private var timer: Task<Void, Never>?
    private var sentCompletion = false
    private let clock = ContinuousClock()
    private var started: ContinuousClock.Instant?
    private var finishingStarted: ContinuousClock.Instant?

    init(directory: URL, seconds: Double, sources: Set<AudioSource> = [.system],
         microphoneDeviceID: String? = nil, switchSources: Bool = false, panelSnapshots: Bool = false,
         recordScreen: Bool = false, captureRequest: CaptureRequest? = nil, renameCheck: Bool = false,
         interruptSource: AudioSource? = nil,
         reportSourceFailure: Bool = true,
         persistentInterruption: Bool = false, failedAdditionCheck: Bool = false,
         onStatus: @escaping (String) -> Void,
         onFinished: @escaping () -> Void) {
        self.directory = directory
        self.seconds = seconds
        self.sources = sources
        self.microphoneDeviceID = microphoneDeviceID
        self.switchSources = switchSources
        self.panelSnapshots = panelSnapshots
        self.recordScreen = recordScreen
        self.captureRequest = captureRequest
        self.renameCheck = renameCheck
        self.interruptSource = interruptSource
        self.reportSourceFailure = reportSourceFailure
        self.persistentInterruption = persistentInterruption
        self.failedAdditionCheck = failedAdditionCheck
        self.onStatus = onStatus
        self.onFinished = onFinished
    }

    func start() {
        recorder.onUpdate = { [weak self] in self?.publish() }
        timer = Task { [weak self] in
            guard let self else { return }
            await recorder.start(directory: directory, sources: sources, microphoneDeviceID: microphoneDeviceID,
                                 recordScreen: recordScreen, captureRequest: captureRequest, title: renameCheck ? "改名前" : nil)
            guard recorder.state == .recording, !Task.isCancelled else { return }
            if let interruptSource {
                interrupting = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
                    repeat {
                        guard !Task.isCancelled, self.recorder.isRecording else { return }
                        await self.recorder.interruptSourceForDiagnostic(interruptSource, reportFailure: self.reportSourceFailure)
                        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    } while self.persistentInterruption
                }
            }
            if failedAdditionCheck {
                switching = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
                    let success = await self.recorder.setSources([.system, .microphone])
                    self.sourceEvents.append(["success": success, "message": self.recorder.controlMessage ?? "",
                                              "sources": self.recorder.sources.map { $0.rawValue }.sorted()])
                }
            }
            if renameCheck {
                renaming = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.recorder.isRecording else { return }
                    let previousPath = self.recorder.outputURL?.path ?? ""
                    let previousTitle = self.recorder.recordingTitle
                    let invalidAccepted = self.recorder.setRecordingTitle("../outside")
                    let applied = self.recorder.setRecordingTitle("录制中改名 Café")
                    self.renameEvent = ["previousPath": previousPath, "pathAfterRename": self.recorder.outputURL?.path ?? "",
                                        "previousTitle": previousTitle, "title": self.recorder.recordingTitle,
                                        "applied": applied, "invalidAccepted": invalidAccepted,
                                        "frames": self.recorder.summary?.frames ?? 0]
                }
            }
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
        stoppedDuringRecovery = stoppedDuringRecovery || !recorder.recoveringSources.isEmpty
        timer?.cancel()
        switching?.cancel()
        renaming?.cancel()
        interrupting?.cancel()
        await recorder.stop(interrupted: true)
    }

    private func keyed<T>(_ values: [AudioSource: T]) -> [String: T] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key == .system ? "system" : "microphone", $0.value) })
    }

    private func publish() {
        guard !sentCompletion else { return }
        if recorder.state == .recording, started == nil { started = clock.now }
        if recorder.state == .finishing, finishingStarted == nil { finishingStarted = clock.now }
        let wall = started.map { instant in
            let duration = instant.duration(to: clock.now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        } ?? 0
        let finished = recorder.state == .completed || recorder.state == .failed
        let finalizationSeconds = finishingStarted.map { instant in
            let duration = instant.duration(to: clock.now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
        let status = recorder.state == .completed && recorder.interrupted ? "interrupted" : recorder.state.rawValue
        if switchSources || interruptSource != nil || failedAdditionCheck, trace.count < 512 {
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
            if recorder.isRecording, !renderedRecovery, !recorder.reconnectCounts.isEmpty,
               (recorder.summary?.duration ?? 0) > 3,
               recorder.sourceFailures.isEmpty, recorder.recoveringSources.isEmpty,
               recorder.recoveryNotice?.contains("已恢复") == true {
                renderPanel("panel-recovered.png")
                renderedRecovery = true
            }
            if finished { renderPanel(recorder.state == .completed ? "panel-saved.png" : "panel-failed.png") }
        }
        let result: [String: Any] = [
            "status": status,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "path": recorder.outputURL?.path ?? "",
            "recordingTitle": recorder.recordingTitle,
            "recordingDirectory": recorder.recordingDirectory?.path ?? "",
            "renameEvent": renameEvent,
            "audioSaved": recorder.audioSaved,
            "availableStorageBytes": recorder.availableStorageBytes ?? 0,
            "powerProtectionActive": recorder.powerProtectionActive,
            "finalizationSeconds": finalizationSeconds.map { $0 as Any } ?? NSNull(),
            "videoSaved": recorder.videoSaved,
            "videoPath": recorder.videoURL?.path ?? "",
            "videoFrames": recorder.videoSummary?.videoFrames ?? 0,
            "videoEpochHostTime": recorder.videoEpochHostTime ?? 0,
            "captureTarget": recorder.captureTargetTitle,
            "videoDurationSeconds": recorder.videoSummary?.duration ?? 0,
            "screenReceivedFrames": recorder.videoMetrics.receivedFrames,
            "screenFirstHostTime": recorder.videoMetrics.firstHostTime ?? 0,
            "screenLastHostTime": recorder.videoMetrics.lastHostTime ?? 0,
            "screenIdleFrames": recorder.videoMetrics.idleFrames,
            "screenLastIdleHostTime": recorder.videoMetrics.lastIdleHostTime ?? 0,
            "screenRepeatedFrames": recorder.videoMetrics.repeatedFrames,
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
            "sourceFailures": keyed(recorder.sourceFailures),
            "reconnectCounts": keyed(recorder.reconnectCounts),
            "recoveringSources": recorder.recoveringSources.map { $0.rawValue }.sorted(),
            "recoveryNotice": recorder.recoveryNotice ?? "",
            "stoppedDuringRecovery": stoppedDuringRecovery,
            "microphoneDeviceID": recorder.microphoneDeviceID ?? "",
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
            renaming?.cancel()
            interrupting?.cancel()
            timer = nil
            onFinished()
        }
    }

    // Renders our own SwiftUI view from live capture state; not a desktop screenshot.
    private func renderPanel(_ filename: String) {
        let view = RecorderPanel(recorder: recorder, mode: recordScreen ? .video : .audio,
                                 onQuit: {}, onStartVideo: { _, _ in },
                                 captureKind: captureRequest?.kind ?? .display).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: directory.appendingPathComponent(filename), options: .atomic) }
        catch { NSLog("Panel snapshot failed: %@", error.localizedDescription) }
    }
}
