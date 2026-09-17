import CoreGraphics
import Testing
@testable import Scriber

struct CaptureTargetTests {
    @Test func mapsAppKitDragsOnOffsetDisplaysAndClipsAtTheirBounds() throws {
        let screen = CGRect(x: -1600, y: -400, width: 1600, height: 1200)
        let region = try CaptureGeometry.fromAppKit(CGRect(x: -1500, y: -200, width: 400, height: 300), screen: screen)
        #expect(region == CGRect(x: 100, y: 700, width: 400, height: 300))
        let clipped = try CaptureGeometry.fromAppKit(CGRect(x: -1700, y: 600, width: 300, height: 300), screen: screen)
        #expect(clipped == CGRect(x: 0, y: 0, width: 200, height: 200))
        let pixels = try CaptureGeometry.pixels(size: CGSize(width: 1728, height: 1117), scale: 2)
        #expect(pixels.width == 3456 && pixels.height == 2234)
        let fractional = try CaptureGeometry.pixels(size: CGSize(width: 300.25, height: 200.75), scale: 2)
        #expect(fractional.width == 602 && fractional.height == 402)
    }

    @Test func rejectsEmptyOffDisplayAndNonFiniteGeometry() {
        for rect in [CGRect.zero, CGRect(x: 500, y: 500, width: 10, height: 10),
                     CGRect(x: 1, y: 1, width: 1, height: 10), CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20)] {
            #expect(throws: CaptureTargetError.self) { try CaptureGeometry.region(rect, within: CGSize(width: 400, height: 300)) }
        }
        #expect(throws: CaptureTargetError.self) { try CaptureGeometry.pixels(size: CGSize(width: 9000, height: 100), scale: 2) }
        #expect(throws: CaptureTargetError.self) { try CaptureGeometry.pixels(size: CGSize(width: 100, height: 100), scale: .nan) }
    }

    @Test func parsesExplicitDiagnosticTargetsWithoutSilentlyFallingBack() throws {
        guard case .region(let display, let rect) = try CaptureRequest.diagnostic(arguments: [
            "--capture-display", "3", "--capture-region", "12.5,40,300,200"]) else { Issue.record("Expected region"); return }
        #expect(display == 3 && rect == CGRect(x: 12.5, y: 40, width: 300, height: 200))
        for arguments in [["--capture-window", "3", "--capture-display", "1"],
                          ["--capture-region", "1,nan,100,100"], ["--capture-region", "1,2,-3,4"],
                          ["--capture-display", "0"], ["--capture-window"], ["--capture-window", "invalid"]] {
            #expect(throws: CaptureTargetError.self) { try CaptureRequest.diagnostic(arguments: arguments) }
        }
    }
}
