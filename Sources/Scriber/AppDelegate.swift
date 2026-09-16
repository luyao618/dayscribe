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
    private let microphone = MicrophoneRecorder()
    private var subscriptions = Set<AnyCancellable>()
    private var terminationSignal: DispatchSourceSignal?
    private var wantsToQuit = false
    private var checkDirectory: URL?
    private var checkDuration: TimeInterval = 0
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

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: RecorderPanel(microphone: microphone))
        popover.contentSize = NSSize(width: 390, height: 400)
        microphone.onCompletion = { [weak self] error in
            guard let self else { return }
            let wasCheck = self.checkDirectory != nil
            if wasCheck { self.completeCheck(error: error) }
            if wasCheck { NSApp.terminate(nil) }
        }
        microphone.$elapsed.combineLatest(microphone.$phase)
            .sink { [weak self] elapsed, phase in
                guard let self else { return }
                let seconds = Int(elapsed)
                self.statusItem?.button?.title = phase == .recording
                    ? String(format: " %02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : ""
            }
            .store(in: &subscriptions)
        signal(SIGTERM, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Enter AppKit's quit path from the native main queue, not a Swift task.
        signalSource.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.requestQuit() }
        }
        signalSource.resume()
        terminationSignal = signalSource

        startCheckIfRequested()
        if CommandLine.arguments.contains("--show-panel") {
            showPanel()
        }
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
        if let systemCheck, systemCheck.recorder.state.active {
            terminationDeferred = true
            Task { await systemCheck.stop() }
            return .terminateLater
        }
        // AVAudioRecorder.stop() synchronously closes its output file. Do not
        // wait here for our asynchronous duration/metadata callback: AppKit's
        // termination loop can prevent that main-actor callback from executing.
        if microphone.isRecording {
            microphone.stop()
        }
        if checkDirectory != nil {
            wantsToQuit = true
            completeCheck(error: microphone.errorMessage)
        }
        return .terminateNow
    }

    private func startCheckIfRequested() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--system-audio-check") {
            guard arguments.count > index + 2, arguments[index + 1].hasPrefix("/"),
                  let seconds = Double(arguments[index + 2]), seconds.isFinite, seconds > 0 else {
                NSLog("Usage: --system-audio-check /absolute/output/directory seconds")
                NSApp.terminate(nil)
                return
            }
            let check = SystemAudioDiagnostic(
                directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true),
                seconds: seconds,
                onStatus: { [weak self] title in self?.statusItem?.button?.title = title },
                onFinished: { [weak self] in
                    if self?.terminationDeferred == true {
                        NSApp.reply(toApplicationShouldTerminate: true)
                    } else {
                        NSApp.terminate(nil)
                    }
                })
            systemCheck = check
            popover.contentViewController = NSHostingController(rootView: SystemAudioCheckPanel(
                recorder: check.recorder, onStop: { [weak self] in self?.requestQuit() }))
            check.start()
            return
        }
        guard let index = arguments.firstIndex(of: "--microphone-check") else { return }
        guard arguments.count > index + 2, arguments[index + 1].hasPrefix("/"),
              let duration = Double(arguments[index + 2]),
              duration.isFinite, duration > 0 else {
            NSLog("Usage: --microphone-check /absolute/output/directory seconds")
            NSApp.terminate(nil)
            return
        }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        checkDirectory = directory
        checkDuration = duration
        Task { await microphone.start(directory: directory, duration: duration) }
    }

    private func requestQuit() {
        if let systemCheck, systemCheck.recorder.state.active {
            Task { await systemCheck.stop() }
        } else {
            NSApp.terminate(nil)
        }
    }

    private func completeCheck(error: String?) {
        guard let directory = checkDirectory else { return }
        checkDirectory = nil
        let result: [String: Any] = [
            "status": error == nil ? (wantsToQuit ? "interrupted" : "completed") : "failed",
            "error": error ?? "",
            "path": microphone.outputURL?.path ?? "",
            "durationSeconds": microphone.elapsed,
            "requestedDurationSeconds": checkDuration,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "peakDBFS": microphone.peakDB,
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        } catch {
            NSLog("Unable to save microphone diagnostic: %@", error.localizedDescription)
        }
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
