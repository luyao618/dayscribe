import AppKit

// Displays only this test's four-quadrant window. Scriber must capture it through
// ScreenCaptureKit; fixture pixels are never supplied to the recording encoder.
final class FixtureView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor] = [.red, .green, .blue, .yellow]
        for index in 0..<4 {
            colors[index].setFill()
            NSRect(x: CGFloat(index % 2) * bounds.width / 2, y: CGFloat(index / 2) * bounds.height / 2,
                   width: bounds.width / 2, height: bounds.height / 2).fill()
        }
        let title = "Scriber Capture Fixture" as NSString
        title.draw(at: NSPoint(x: 130, y: 140), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 18),
                                                              .foregroundColor: NSColor.white])
    }
}

@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let displayID = CommandLine.arguments.count > 2 ? UInt32(CommandLine.arguments[2]) ?? 0 : CGMainDisplayID()
        guard (2...3).contains(CommandLine.arguments.count), CommandLine.arguments[1].hasPrefix("/"),
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
              }) else { NSApp.terminate(nil); return }
        let frame = NSRect(x: screen.frame.minX + 60, y: screen.frame.minY + 80, width: 480, height: 300)
        // This initializer takes an origin relative to its explicit screen.
        let localFrame = NSRect(x: 60, y: 80, width: frame.width, height: frame.height)
        let window = NSWindow(contentRect: localFrame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.title = "Scriber Capture Fixture"
        window.hasShadow = false
        window.isOpaque = true
        window.level = .floating
        window.contentView = FixtureView(frame: NSRect(origin: .zero, size: frame.size))
        window.orderFrontRegardless()
        self.window = window
        let metadata: [String: Any] = [
            "windowID": window.windowNumber, "displayID": displayID,
            "actualFrame": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
            "requestedFrame": [frame.minX, frame.minY, frame.width, frame.height],
            "region": [window.frame.minX - screen.frame.minX, screen.frame.maxY - window.frame.maxY, window.frame.width, window.frame.height],
            "width": Int(window.frame.width * window.backingScaleFactor),
            "height": Int(window.frame.height * window.backingScaleFactor),
            "pid": ProcessInfo.processInfo.processIdentifier
        ]
        do {
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        } catch { NSLog("Fixture metadata failed: %@", error.localizedDescription); NSApp.terminate(nil) }
    }
}

@main enum CaptureTargetFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
