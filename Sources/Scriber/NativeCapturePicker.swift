import AppKit
import ScreenCaptureKit

@MainActor
final class NativeCapturePicker: NSObject, SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<CaptureRequest?, any Error>?
    private var overlays: [NSWindow] = []
    private(set) var kind = CaptureKind.region
    private(set) var lastOutcome = ""
    var onChange: (() -> Void)?
    var isChoosing: Bool { continuation != nil }

    func choose(_ kind: CaptureKind) async throws -> CaptureRequest? {
        guard continuation == nil else { throw CaptureTargetError.unavailable }
        self.kind = kind
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.lastOutcome = ""
            self.onChange?()
            if kind == .region { showRegions() }
            else {
                let picker = SCContentSharingPicker.shared
                var configuration = SCContentSharingPickerConfiguration()
                configuration.allowedPickerModes = kind == .window ? .singleWindow : .singleDisplay
                configuration.allowsChangingSelectedContent = false
                picker.defaultConfiguration = configuration
                picker.add(self)
                picker.isActive = true
                picker.present(using: kind == .window ? .window : .display)
            }
        }
    }

    func cancel() { finish(.success(nil)) }

    private func showRegions() {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            // With an explicit screen, NSWindow's initializer expects a local origin.
            let window = RegionOverlayWindow(contentRect: NSRect(origin: .zero, size: screen.frame.size),
                                              styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = RegionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), scale: screen.backingScaleFactor)
            view.onBegin = { [weak self, weak view] in
                self?.overlays.compactMap { $0.contentView as? RegionOverlayView }
                    .filter { $0 !== view }.forEach { $0.clearSelection() }
            }
            view.onCancel = { [weak self] in self?.cancel() }
            view.onConfirm = { [weak self] local in
                do {
                    let global = local.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                    let region = try CaptureGeometry.fromAppKit(global, screen: screen.frame)
                    self?.finish(.success(.region(display: number.uint32Value, rect: region)))
                } catch { self?.finish(.failure(error)) }
            }
            window.contentView = view
            overlays.append(window)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
        if overlays.isEmpty { finish(.failure(CaptureTargetError.unavailable)) }
        else { NSApp.activate() }
    }

    private func finish(_ result: Result<CaptureRequest?, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success(let selection): lastOutcome = selection == nil ? "cancelled" : "confirmed"
        case .failure: lastOutcome = "failed"
        }
        for window in overlays { window.orderOut(nil); window.close() }
        overlays.removeAll()
        if kind != .region {
            SCContentSharingPicker.shared.remove(self)
            SCContentSharingPicker.shared.isActive = false
        }
        onChange?()
        continuation.resume(with: result)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in self?.cancel() }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let selection = PickedCaptureFilter(filter)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.finish(.success(.selectedFilter(selection, title: self.kind.title)))
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in self?.finish(.failure(VideoWriteError.encoding(message))) }
    }
}

private final class RegionOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
