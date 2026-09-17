import AppKit
import AVFoundation
import CoreMedia

// A real displayed window and real audio output. Scriber receives both through
// ScreenCaptureKit; this fixture never sends samples to Scriber's encoders.
final class SyncView: NSView {
    var cues: [Double] = []
    var epoch = 0.0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let elapsed = epoch == 0 ? 0 : max(0, now - epoch)
        NSColor(srgbRed: 0.08, green: 0.12, blue: 0.15, alpha: 1).setFill()
        bounds.fill()
        let pulse = cues.contains { now >= $0 && now < $0 + 0.25 }
        (pulse ? NSColor.white : NSColor.black).setFill()
        NSRect(x: 24, y: 24, width: 128, height: 128).fill()
        // The long fixture hit a CoreText exception in repeated NSString font
        // drawing. Use geometric digits: this render loop never creates text,
        // attributed-string dictionaries or fonts.
        drawClock(Int(elapsed), at: CGPoint(x: 185, y: 55))
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let wave = NSBezierPath()
        for index in 0...160 {
            let point = CGPoint(x: 24 + Double(index) * 3, y: 220 + 18 * sin(Double(index) * .pi / 20))
            if index == 0 { wave.move(to: point) } else { wave.line(to: point) }
        }
        wave.lineWidth = 2
        wave.stroke()
        // Keep real picture changes throughout the run, not just at its ends.
        NSColor.systemMint.setFill()
        NSRect(x: 24 + (elapsed.truncatingRemainder(dividingBy: 4) / 4) * (bounds.width - 96),
               y: bounds.height - 72, width: 48, height: 32).fill()
    }

    private func drawClock(_ seconds: Int, at origin: CGPoint) {
        let digits = [seconds / 36_000 % 10, seconds / 3_600 % 10,
                      seconds / 600 % 6, seconds / 60 % 10, seconds / 10 % 6, seconds % 10]
        let masks = [0x3f, 0x06, 0x5b, 0x4f, 0x66, 0x6d, 0x7d, 0x07, 0x7f, 0x6f]
        let segments = [CGRect(x: 4, y: 0, width: 20, height: 4), CGRect(x: 24, y: 4, width: 4, height: 19),
                        CGRect(x: 24, y: 27, width: 4, height: 19), CGRect(x: 4, y: 46, width: 20, height: 4),
                        CGRect(x: 0, y: 27, width: 4, height: 19), CGRect(x: 0, y: 4, width: 4, height: 19),
                        CGRect(x: 4, y: 23, width: 20, height: 4)]
        NSColor.white.setFill()
        for (index, digit) in digits.enumerated() {
            let x = origin.x + CGFloat(index * 42 + index / 2 * 14)
            for (bit, rect) in segments.enumerated() where masks[digit] & (1 << bit) != 0 {
                rect.offsetBy(dx: x, dy: origin.y).fill()
            }
            if index == 1 || index == 3 {
                for y in [14.0, 34.0] {
                    NSBezierPath(ovalIn: CGRect(x: x + 36, y: origin.y + y, width: 4, height: 4)).fill()
                }
            }
        }
    }
}

@MainActor
final class SyncDelegate: NSObject, NSApplicationDelegate {
    let root: URL
    let seconds: Double
    let engine = AVAudioEngine()
    var window: NSWindow?
    var timer: Timer?
    var source: AVAudioSourceNode?
    var metadata: [String: Any] = [:]
    var started = false

    init(root: URL, seconds: Double) { self.root = root; self.seconds = seconds }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }
        let frame = NSRect(x: 40, y: 40, width: 960, height: 540)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.title = "Scriber Video Sync Fixture"
        window.hasShadow = false
        window.isOpaque = true
        window.animationBehavior = .none
        let view = SyncView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        window.orderFrontRegardless()
        window.displayIfNeeded()
        self.window = window
        metadata = ["pid": ProcessInfo.processInfo.processIdentifier, "windowID": window.windowNumber,
                    "width": Int(window.frame.width * window.backingScaleFactor),
                    "height": Int(window.frame.height * window.backingScaleFactor),
                    "actualFrame": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
                    "viewBounds": [view.bounds.width, view.bounds.height],
                    "marker": [Int(40 * window.backingScaleFactor), Int(40 * window.backingScaleFactor),
                               Int(80 * window.backingScaleFactor), Int(80 * window.backingScaleFactor)]]
        writeMetadata()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard let view = window?.contentView as? SyncView else { return }
        if !started, FileManager.default.fileExists(atPath: root.appendingPathComponent("start-cues").path) {
            started = true
            let epoch = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.5
            let cues = [1.0, 2, 3, seconds - 5, seconds - 4, seconds - 3].map { epoch + $0 }
            view.epoch = epoch
            view.cues = cues
            do {
                try startAudio(cues: cues)
                metadata["epochHostTime"] = epoch
                metadata["cueHostTimes"] = cues
                metadata["outputPresentationLatency"] = engine.outputNode.presentationLatency
                writeMetadata()
            } catch {
                metadata["error"] = error.localizedDescription
                writeMetadata()
                NSApp.terminate(nil)
            }
        }
        view.needsDisplay = true
        view.displayIfNeeded()
    }

    private func startAudio(cues: [Double]) throws {
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let source = AVAudioSourceNode(format: format) { _, timestamp, count, buffers in
            let time = AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime)
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for index in 0..<Int(count) {
                    let now = time + Double(index) / rate
                    if let onset = cues.first(where: { now >= $0 && now < $0 + 0.25 }) {
                        let offset = now - onset
                        let fade = min(1, offset / 0.002, (0.25 - offset) / 0.002)
                        data[index] = Float(0.03 * fade * sin(offset * 880 * 2 * .pi))
                    } else { data[index] = 0 }
                }
            }
            return noErr
        }
        self.source = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    private func writeMetadata() {
        do {
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appendingPathComponent("fixture.json"), options: .atomic)
        } catch { NSLog("Cannot write fixture evidence: %@", error.localizedDescription); NSApp.terminate(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); engine.stop() }
}

@main
enum VideoSyncFixture {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count == 3, args[1].hasPrefix("/"), let seconds = Double(args[2]), seconds.isFinite, seconds >= 20 else { return }
        let app = NSApplication.shared
        let delegate = SyncDelegate(root: URL(fileURLWithPath: args[1]), seconds: seconds)
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
