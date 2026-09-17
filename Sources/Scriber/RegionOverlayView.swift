import AppKit

@MainActor
final class RegionOverlayView: NSView {
    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: ((CGRect) -> Void)?
    private var anchor: CGPoint?
    private var endpoint: CGPoint?
    private let scale: CGFloat
    private let startButton = NSButton(title: "开始录屏", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    init(frame: CGRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
        startButton.target = self
        startButton.action = #selector(confirm)
        startButton.keyEquivalent = "\r"
        startButton.bezelStyle = .rounded
        startButton.bezelColor = NSColor(srgbRed: 112/255, green: 103/255, blue: 207/255, alpha: 1)
        startButton.contentTintColor = .white
        startButton.isEnabled = false
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded
        for button in [startButton, cancelButton] {
            button.controlSize = .large
            addSubview(button)
        }
        setAccessibilityLabel("框选录屏区域")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        cancelButton.frame = CGRect(x: bounds.midX - 126, y: 35, width: 110, height: 38)
        startButton.frame = CGRect(x: bounds.midX + 4, y: 35, width: 122, height: 38)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        onBegin?()
        anchor = convert(event.locationInWindow, from: nil)
        endpoint = anchor
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        endpoint = convert(event.locationInWindow, from: nil)
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        endpoint = convert(event.locationInWindow, from: nil)
        refresh()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel() }
        else if event.keyCode == 36 || event.keyCode == 76 { confirm() }
        else { super.keyDown(with: event) }
    }

    func clearSelection() { anchor = nil; endpoint = nil; refresh() }

    private var selection: CGRect? {
        guard let anchor, let endpoint else { return nil }
        return CaptureGeometry.drag(from: anchor, to: endpoint, within: bounds)
    }

    private func refresh() {
        startButton.isEnabled = selection != nil
        needsDisplay = true
    }

    @objc private func confirm() { if let selection { onConfirm?(selection) } }
    @objc private func cancel() { onCancel?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill(using: .copy)
        if let selection {
            selection.fill(using: .clear)
            NSColor(srgbRed: 0.57, green: 0.52, blue: 1, alpha: 1).setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 2
            border.stroke()
            let size = try? CaptureGeometry.pixels(size: selection.size, scale: Double(scale))
            let text = size.map { "\($0.width) × \($0.height)" } ?? ""
            drawPill(text, center: CGPoint(x: min(max(selection.midX, 70), bounds.width - 70),
                                           y: min(selection.maxY + 22, bounds.height - 75)), fontSize: 12)
        }
        drawPill("拖动鼠标框选 · 回车开始录屏 · Esc 取消", center: CGPoint(x: bounds.midX, y: bounds.height - 42), fontSize: 14)
    }

    private func drawPill(_ text: String, center: CGPoint, fontSize: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                                                        .foregroundColor: NSColor.white]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        let rect = CGRect(x: center.x - size.width / 2 - 14, y: center.y - size.height / 2 - 9,
                          width: size.width + 28, height: size.height + 18)
        NSColor(srgbRed: 0.15, green: 0.17, blue: 0.22, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        string.draw(at: CGPoint(x: rect.minX + 14, y: rect.minY + 9), withAttributes: attributes)
    }
}
