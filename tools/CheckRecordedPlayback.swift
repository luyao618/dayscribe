// Link with Sources/Scriber/*.swift except ScriberMain.swift.
// Reads a real session manifest; writes only to a new, caller-owned output directory.
// Native playback-model/AVPlayer evidence, not GUI-click or audible-output evidence.
// Video samples require a moving fixture with at least5 pictures per1.25s section.
import AppKit
import AVFoundation
import CoreImage
import CryptoKit
import Darwin

@MainActor
private final class PlaybackCheckDelegate: NSObject, NSApplicationDelegate {
    let manifestURL: URL
    let outputURL: URL

    init(manifestURL: URL, outputURL: URL) {
        self.manifestURL = manifestURL
        self.outputURL = outputURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                try await run()
                print("PASS: native model load, seek positions, real playback progress, pause and video output; GUI/audio output not tested")
                exit(0)
            } catch {
                let message = String(describing: error)
                try? write(["error": message, "passed": false], name: "failure.json")
                FileHandle.standardError.write(Data((message + "\n").utf8))
                exit(1)
            }
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "RecordedPlaybackCheck", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private func write(_ value: [String: Any], name: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputURL.appendingPathComponent(name), options: .withoutOverwriting)
    }

    private func wait(_ model: RecordingPlaybackModel, stage: String,
                      until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            try require(model.errorMessage == nil, "\(stage): \(model.errorMessage ?? "")")
            try require(ContinuousClock.now < deadline, "\(stage): timed out")
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(model.errorMessage == nil, "\(stage): \(model.errorMessage ?? "")")
    }

    private func run() async throws {
        let originalManifest = try Data(contentsOf: manifestURL)
        let manifest = try RecordingSessionFiles.Manifest.read(from: manifestURL)
        let store = RecordingHistoryStore(indexURL: outputURL.appendingPathComponent("history.json"))
        try await store.register(RecordingHistoryReference(manifestURL: manifestURL, manifest: manifest))
        guard let entry = try await store.entry(manifest.id) else { throw RecordingHistoryError.invalidManifest }
        let kinds = RecordingFileKind.allCases.filter { entry.fileStates[$0] == .available }
        try require(!kinds.isEmpty, "No published media is available")
        let model = RecordingPlaybackModel(store: store)
        defer { model.close() }
        model.player.isMuted = true
        let context = CIContext()
        var tracks: [[String: Any]] = []
        for kind in kinds {
            await model.open(manifest.id, kind: kind).value
            try await wait(model, stage: "load \(kind.rawValue)") { model.canPlay && !model.isLoading }
            try require(model.duration >= 12, "Use a completed recording of at least12 seconds")
            guard let item = model.player.currentItem else { throw RecordingHistoryError.invalidManifest }
            let videoOutput = kind == .video ? AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]) : nil
            if let videoOutput { item.add(videoOutput) }
            let duration = model.duration
            var sections: [[String: Any]] = []
            for (index, target) in [6.0, duration - 3].enumerated() {
                model.seek(to: target)
                try await wait(model, stage: "seek \(kind.rawValue) to \(target)") {
                    !model.isSeeking && abs(model.position - target) < 0.05
                }
                let seekPosition = model.position
                await model.togglePlayback()
                let clock = ContinuousClock()
                let started = clock.now
                let deadline = started + .seconds(15)
                var frames: [Double] = []
                var dimensions: [Int] = []
                var firstPictureHash = ""
                while model.position < target + 1.25 {
                    try require(model.errorMessage == nil && item.status != .failed,
                                model.errorMessage ?? item.error?.localizedDescription ?? "Playback failed")
                    try require(clock.now < deadline, "Playback clock did not advance")
                    if let videoOutput {
                        let time = model.player.currentTime()
                        if videoOutput.hasNewPixelBuffer(forItemTime: time) {
                            var displayTime = CMTime.invalid
                            if let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime) {
                                try require(displayTime.isNumeric && displayTime.seconds.isFinite, "Invalid rendered-picture time")
                                try require(displayTime.seconds >= target - 0.1, "Stale video picture after seeking")
                                if frames.last != displayTime.seconds { frames.append(displayTime.seconds) }
                                if firstPictureHash.isEmpty {
                                    dimensions = [CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)]
                                    guard let png = context.pngRepresentation(of: CIImage(cvPixelBuffer: buffer), format: .RGBA8,
                                        colorSpace: CGColorSpaceCreateDeviceRGB()) else { throw CocoaError(.fileWriteUnknown) }
                                    try png.write(to: outputURL.appendingPathComponent("\(kind.rawValue)-section-\(index).png"),
                                                  options: .withoutOverwriting)
                                    firstPictureHash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
                                }
                            }
                        }
                    }
                    try await Task.sleep(for: .milliseconds(30))
                }
                try require(model.player.timeControlStatus == .playing && model.player.rate > 0,
                            "Player was not actively playing")
                if videoOutput != nil {
                    try require(frames.count >= 5 && !firstPictureHash.isEmpty, "Video output did not produce advancing pictures")
                    try require(zip(frames, frames.dropFirst()).allSatisfy { $0 < $1 }, "Video picture times moved backward")
                }
                let components = started.duration(to: clock.now).components
                let wall = Double(components.seconds) + Double(components.attoseconds) / 1e18
                let playedPosition = model.position
                model.pause()
                try require(!model.isPlaying && model.player.rate == 0, "Pause did not stop playback")
                sections.append(["requestedSeek": target, "completedSeek": seekPosition,
                    "playedPosition": playedPosition, "observedWallSeconds": wall, "sampledVideoTimes": frames,
                    "pixelDimensions": dimensions, "firstPictureSHA256": firstPictureHash])
            }
            tracks.append(["kind": kind.rawValue, "duration": duration, "sections": sections])
            if let videoOutput { item.remove(videoOutput) }
            model.close()
            try require(model.player.currentItem == nil && model.entry == nil && !model.isPlaying, "Close left playback active")
        }
        try require(try Data(contentsOf: manifestURL) == originalManifest, "Source manifest changed")
        try write(["passed": true, "manifestPath": manifestURL.path, "sessionID": manifest.id.uuidString,
                   "tracks": tracks, "muted": true, "GUIInteractionVerified": false,
                   "scope": "Production playback model with AVPlayer, actual seek/play/pause and native video buffers; not a full-file decode or audible-output test"],
                  name: "verified.json")
    }
}

@main
private enum CheckRecordedPlayback {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count == 3, args[1].hasPrefix("/"), args[2].hasPrefix("/") else {
            FileHandle.standardError.write(Data("Usage: CheckRecordedPlayback /absolute/session.json /absolute/NEW-output-directory\n".utf8))
            exit(2)
        }
        let manifest = URL(fileURLWithPath: args[1]).standardizedFileURL
        let output = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL
        guard mkdir(output.path, 0o700) == 0 else {
            FileHandle.standardError.write(Data("Output directory must be new and its parent must exist\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = PlaybackCheckDelegate(manifestURL: manifest, outputURL: output)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
