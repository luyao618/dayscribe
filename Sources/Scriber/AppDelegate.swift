import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        popover.contentViewController = NSHostingController(rootView: RecorderPanel())
        popover.contentSize = NSSize(width: 390, height: 290)

        if CommandLine.arguments.contains("--show-panel") {
            showPanel()
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
