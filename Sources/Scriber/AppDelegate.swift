import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Darwin
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let recorder = AudioRecorder(defaults: .standard)
    private let capturePicker = NativeCapturePicker()
    private var subscriptions = Set<AnyCancellable>()
    private var terminationSignal: DispatchSourceSignal?
    private var systemCheck: SystemAudioDiagnostic?
    private var terminationDeferred = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if writePermissionCheckIfRequested() { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Scriber")
        button.image?.isTemplate = true
        button.toolTip = "Scriber"
        button.setAccessibilityLabel("Scriber")
        button.setAccessibilityIdentifier("scriber.status")
        button.target = self
        button.action = #selector(togglePanel)
        statusItem = item

        capturePicker.onChange = { [weak self] in self?.writeUIReport() }
        popover.behavior = .transient
        installPanel(RecorderPanel(recorder: recorder, onQuit: { [weak self] in self?.requestQuit() },
                                   onStartVideo: { [weak self] kind in await self?.startVideo(kind) }))
        recorder.onUpdate = { [weak self] in
            guard let self else { return }
            self.writeUIReport()
            guard self.systemCheck == nil, self.terminationDeferred, !self.recorder.state.active else { return }
            self.terminationDeferred = false
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        recorder.$summary.combineLatest(recorder.$state)
            .sink { [weak self] summary, state in
                guard let self, self.systemCheck == nil else { return }
                let seconds = Int(summary?.duration ?? 0)
                self.statusItem?.button?.title = state == .recording
                    ? String(format: " %02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : ""
            }
            .store(in: &subscriptions)
        signal(SIGTERM, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // AppKit runs a nested loop for terminateLater. Enter from a run-loop
        // callback, so neither a Swift task nor a dispatch drain holds the main queue.
        signalSource.setEventHandler { [weak self] in
            RunLoop.main.perform { [weak self] in
                MainActor.assumeIsolated {
                    if CommandLine.arguments.contains("--quit-via-appkit") { NSApp.terminate(nil) }
                    else { self?.requestQuit() }
                }
            }
        }
        signalSource.resume()
        terminationSignal = signalSource

        writeUIReport()
        startCheckIfRequested()
        if CommandLine.arguments.contains("--show-panel") {
            showPanel()
        }
    }

    /// Optional local evidence for manual GUI validation; never enabled in normal launches.
    private func writeUIReport() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--ui-validation-report"), args.indices.contains(index + 1),
              args[index + 1].hasPrefix("/") else { return }
        let report: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "state": capturePicker.isChoosing ? "selecting" : recorder.state.rawValue,
            "selectionKind": capturePicker.kind.rawValue,
            "selectionOutcome": capturePicker.lastOutcome,
            "audioPath": recorder.outputURL?.path ?? "",
            "videoPath": recorder.videoURL?.path ?? "",
            "recordingTitle": recorder.recordingTitle,
            "recordingDirectory": recorder.recordingDirectory?.path ?? "",
            "audioSaved": recorder.audioSaved, "videoSaved": recorder.videoSaved,
            "frames": recorder.summary?.frames ?? 0,
            "duration": recorder.summary?.duration ?? 0,
            "sources": recorder.sources.map { $0.rawValue }.sorted(),
            "error": recorder.controlMessage ?? recorder.errorMessage ?? ""
        ]
        do {
            let url = URL(fileURLWithPath: args[index + 1])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: url, options: .atomic)
        } catch { NSLog("UI validation report failed: %@", error.localizedDescription) }
    }

    private func writePermissionCheckIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--capture-permission-check") else { return false }
        defer { NSApp.terminate(nil) }
        guard arguments.count > index + 1, arguments[index + 1].hasPrefix("/") else { return true }
        let result: [String: Any] = [
            "screenAuthorized": CGPreflightScreenCaptureAccess(),
            "microphoneAuthorized": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "pid": ProcessInfo.processInfo.processIdentifier
        ]
        do {
            let url = URL(fileURLWithPath: arguments[index + 1])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: url, options: .atomic)
        } catch { NSLog("Permission preflight report failed: %@", error.localizedDescription) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        capturePicker.cancel()
        if let systemCheck, systemCheck.recorder.state.active {
            terminationDeferred = true
            Task { await systemCheck.stop() }
            return .terminateLater
        }
        if recorder.state.active {
            terminationDeferred = true
            Task { await recorder.stop(interrupted: true) }
            return .terminateLater
        }
        return .terminateNow
    }

    private func startCheckIfRequested() {
        let arguments = CommandLine.arguments
        if let index = ["--system-audio-check", "--mixed-audio-check", "--microphone-check", "--panel-audio-check", "--display-video-check"]
            .compactMap({ arguments.firstIndex(of: $0) }).first {
            guard arguments.count > index + 2, arguments[index + 1].hasPrefix("/"),
                  let seconds = Double(arguments[index + 2]), seconds.isFinite, seconds > 0 else {
                NSLog("Usage: --system-audio-check /absolute/output/directory seconds")
                NSApp.terminate(nil)
                return
            }
            let modeIndex = arguments.firstIndex(of: "--audio-sources")
            let mode = modeIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
                ?? (arguments.contains("--microphone-check") ? "microphone" : (arguments.contains("--system-audio-check") ? "system" : "both"))
            let sourceModes: [String: Set<AudioSource>] = ["system": [.system], "microphone": [.microphone], "both": [.system, .microphone]]
            guard let sources = sourceModes[mode] else { NSApp.terminate(nil); return }
            let deviceIndex = arguments.firstIndex(of: "--microphone-device")
            let device = deviceIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            let captureRequest: CaptureRequest?
            do { captureRequest = try CaptureRequest.diagnostic(arguments: arguments) }
            catch { NSLog("Invalid capture target: %@", error.localizedDescription); NSApp.terminate(nil); return }
            let check = SystemAudioDiagnostic(
                directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true),
                seconds: seconds, sources: sources, microphoneDeviceID: device,
                switchSources: arguments.contains("--switch-sources"),
                panelSnapshots: arguments.contains("--panel-snapshots"),
                recordScreen: arguments.contains("--display-video-check"), captureRequest: captureRequest,
                renameCheck: arguments.contains("--rename-check"),
                onStatus: { [weak self] title in self?.statusItem?.button?.title = title },
                onFinished: { [weak self] in
                    if self?.terminationDeferred == true {
                        self?.terminationDeferred = false
                        DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
                    } else {
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                    }
                })
            systemCheck = check
            if arguments.contains("--panel-audio-check") || arguments.contains("--microphone-check") || arguments.contains("--panel-snapshots") {
                installPanel(RecorderPanel(recorder: check.recorder,
                    mode: arguments.contains("--display-video-check") ? .video : .audio,
                    onQuit: { [weak self] in self?.requestQuit() }, captureKind: captureRequest?.kind ?? .display))
            } else {
                installPanel(SystemAudioCheckPanel(recorder: check.recorder, onStop: { [weak self] in self?.requestQuit() }))
            }
            check.start()
            return
        }
    }

    private func startVideo(_ kind: CaptureKind) async {
        guard !recorder.state.active else { return }
        recorder.reportControlMessage(nil)
        popover.performClose(nil)
        do {
            if let request = try await capturePicker.choose(kind) {
                await recorder.start(captureRequest: request)
            }
        } catch { recorder.reportControlMessage(error.localizedDescription) }
        writeUIReport()
        showPanel()
    }

    private func requestQuit() {
        if let systemCheck, systemCheck.recorder.state.active {
            Task { await systemCheck.stop() }
        } else if recorder.state.active {
            Task {
                await recorder.stop(interrupted: true)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    private func installPanel<Content: View>(_ content: Content) {
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        controller.view.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
