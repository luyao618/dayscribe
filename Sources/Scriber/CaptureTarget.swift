import ScreenCaptureKit

enum CaptureKind: String, CaseIterable {
    case region, window, display
    var title: String { switch self { case .region: L10n.text("自选区域"); case .window: L10n.text("单个窗口"); case .display: L10n.text("整块屏幕") } }
    var symbol: String { switch self { case .region: "viewfinder"; case .window: "macwindow"; case .display: "display" } }
}

// ScreenCaptureKit delivers this filter once. Treat it as immutable during the
// delegate-to-main-actor handoff; all later filter use is confined to the main actor.
final class PickedCaptureFilter: @unchecked Sendable {
    let filter: SCContentFilter
    init(_ filter: SCContentFilter) { self.filter = filter }
}

/// Regions use top-left, display-local points; microphone/system capture stays global.
enum CaptureRequest: Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case region(display: CGDirectDisplayID, rect: CGRect)
    case selectedFilter(PickedCaptureFilter, title: String)

    var kind: CaptureKind {
        switch self {
        case .region: .region
        case .window: .window
        case .display: .display
        case .selectedFilter(let selection, _): selection.filter.style == .window ? .window : .display
        }
    }

    static func diagnostic(arguments: [String]) throws -> CaptureRequest? {
        func value(_ flag: String) throws -> String? {
            guard let index = arguments.firstIndex(of: flag) else { return nil }
            guard arguments.indices.contains(index + 1) else { throw CaptureTargetError.invalidRegion }
            return arguments[index + 1]
        }
        let display = try value("--capture-display")
        let window = try value("--capture-window")
        let region = try value("--capture-region")
        if let window {
            guard display == nil, region == nil, let id = UInt32(window), id > 0 else { throw CaptureTargetError.unavailable }
            return .window(id)
        }
        guard display != nil || region != nil else { return nil }
        let id = try display.map { text in
            guard let id = UInt32(text), id > 0 else { throw CaptureTargetError.unavailable }
            return id
        } ?? CGMainDisplayID()
        if let region {
            let values = region.split(separator: ",", omittingEmptySubsequences: false).compactMap { Double($0) }
            guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else {
                throw CaptureTargetError.invalidRegion
            }
            return .region(display: id, rect: CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
        }
        return .display(id)
    }
}

enum CaptureTargetError: LocalizedError {
    case unavailable, invalidRegion
    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.text("所选屏幕或窗口已不可用，请重新选择。")
        case .invalidRegion: L10n.text("录屏区域无效，请在一块屏幕内重新框选。")
        }
    }
}

struct CaptureGeometry {
    static func drag(from start: CGPoint, to end: CGPoint, within bounds: CGRect) -> CGRect? {
        guard [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite) else { return nil }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        return !rect.isNull && rect.width >= 2 && rect.height >= 2 ? rect : nil
    }

    static func region(_ rect: CGRect, within size: CGSize) throws -> CGRect {
        guard [rect.minX, rect.minY, rect.width, rect.height, size.width, size.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { throw CaptureTargetError.invalidRegion }
        let clipped = rect.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { throw CaptureTargetError.invalidRegion }
        return clipped
    }

    /// AppKit's global drag coordinates are bottom-left based. Restrict a drag
    /// to its starting display and flip its y coordinate once, not per monitor.
    static func fromAppKit(_ rect: CGRect, screen: CGRect) throws -> CGRect {
        let local = CGRect(x: rect.minX - screen.minX, y: screen.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
        return try region(local, within: screen.size)
    }

    static func pixels(size: CGSize, scale: Double) throws -> (width: Int, height: Int) {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite, scale > 0,
              size.width > 0, size.height > 0,
              size.width * scale <= 8192, size.height * scale <= 8192 else { throw CaptureTargetError.invalidRegion }
        return (Int(ceil(size.width * scale / 2)) * 2, Int(ceil(size.height * scale / 2)) * 2)
    }
}

struct CaptureTarget {
    let filter: SCContentFilter
    let sourceRect: CGRect?
    let title: String

    static func resolve(_ request: CaptureRequest, content: SCShareableContent) throws -> CaptureTarget {
        switch request {
        case .selectedFilter(let filter, let title):
            let windowTitle = filter.filter.style == .window ? filter.filter.includedWindows.first?.title : nil
            return CaptureTarget(filter: filter.filter, sourceRect: nil,
                                 title: windowTitle.flatMap { $0.isEmpty ? nil : $0 } ?? title)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureTargetError.unavailable }
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? window.owningApplication?.applicationName ?? L10n.text("所选窗口")
            return CaptureTarget(filter: SCContentFilter(desktopIndependentWindow: window), sourceRect: nil, title: title)
        case .display(let id), .region(let id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureTargetError.unavailable }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            if case .region(_, let rect) = request {
                let clipped = try CaptureGeometry.region(rect, within: filter.contentRect.size)
                return CaptureTarget(filter: filter, sourceRect: clipped, title: L10n.text("自选区域"))
            }
            return CaptureTarget(filter: filter, sourceRect: nil, title: L10n.text("整块屏幕"))
        }
    }

    func configuration() throws -> SCStreamConfiguration {
        let size = try CaptureGeometry.pixels(size: sourceRect?.size ?? filter.contentRect.size,
                                              scale: Double(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        if let sourceRect { configuration.sourceRect = sourceRect }
        return configuration
    }
}
