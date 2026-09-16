import AppKit
import SwiftUI

// Renders our SwiftUI view offscreen; this does not capture or control the desktop.
@main
enum RenderPanel {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "RenderPanel", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Usage: RenderPanel output.png"
            ])
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let content = RecorderPanel(microphone: MicrophoneRecorder())
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "RenderPanel", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Unable to render native panel"
            ])
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        print("Rendered native SwiftUI panel (\(png.count) bytes).")
    }
}
