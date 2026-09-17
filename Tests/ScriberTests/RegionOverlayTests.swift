import AppKit
import Testing
@testable import Scriber

struct RegionOverlayTests {
    // Direct synthetic events exercise our view logic, not desktop input routing.
    @Test @MainActor func dragConfirmationAndEscapeUseClippedSelection() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let view = RegionOverlayView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), scale: 2)
        var selections: [CGRect] = []
        var cancelled = false
        view.onConfirm = { selections.append($0) }
        view.onCancel = { cancelled = true }
        let button = try #require(view.subviews.compactMap { $0 as? NSButton }.first(where: { $0.title == "开始录屏" }))
        #expect(!button.isEnabled)
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 250, y: 180)))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: -30, y: -20)))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: -30, y: -20)))
        #expect(button.isEnabled)
        view.keyDown(with: try key(36))
        #expect(selections == [CGRect(x: 0, y: 0, width: 250, height: 180)])
        view.clearSelection()
        #expect(!button.isEnabled)
        view.keyDown(with: try key(36))
        #expect(selections.count == 1)
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 20, y: 20)))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 21, y: 21)))
        #expect(!button.isEnabled)
        view.keyDown(with: try key(53))
        #expect(cancelled && selections.count == 1)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: code == 36 ? "\r" : "\u{1b}",
            charactersIgnoringModifiers: code == 36 ? "\r" : "\u{1b}", isARepeat: false, keyCode: code))
    }
}
