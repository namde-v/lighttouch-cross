import HostRuntime
import Foundation
import Testing

@testable import LightTouchCore

/// A panel capture turns the way the window shows it.
struct PanelCaptureTests {
    /// 2x1, a red pixel on the left.
    func image() -> LTMImage {
        var image = LTMImage(width: 2, height: 1, b: 0, g: 0, r: 0)
        image.pixels[2] = 255  // red at (0, 0)
        return image
    }

    /// The red pixel, top-left origin.
    func red(_ img: LTMImage) -> [Int] {
        for y in 0..<img.height {
            for x in 0..<img.width where img.bgra(atX: x, y: y).r > 128 { return [x, y] }
        }
        return []
    }

    @Test func quarterTurnsMoveTheLeftPixel() throws {
        let image = image()
        let cw = PanelCapture.rotated(image, clockwiseQuarterTurns: 1)
        #expect(cw.width == 1 && cw.height == 2 && red(cw) == [0, 0], "clockwise: left goes to the top")
        #expect(
            red(PanelCapture.rotated(image, clockwiseQuarterTurns: 3)) == [0, 1],
            "counter-clockwise: left goes to the bottom"
        )
        #expect(red(PanelCapture.rotated(image, clockwiseQuarterTurns: 2)) == [1, 0])
        #expect(PanelCapture.rotated(image, clockwiseQuarterTurns: 0) == image)
    }

    @Test func turnsCombineScanAndDeviceRotation() {
        // The iPad's panel scans a quarter counter-clockwise of upright (panelRotation -pi/2).
        #expect(PanelCapture.quarterTurns(guestTurn: -.pi / 2, deviceDegrees: 0, surfaceFollowsRotation: false) == 3)
        #expect(PanelCapture.quarterTurns(guestTurn: -.pi / 2, deviceDegrees: 90, surfaceFollowsRotation: false) == 0)
        #expect(PanelCapture.quarterTurns(guestTurn: 0, deviceDegrees: 270, surfaceFollowsRotation: false) == 3)
        #expect(
            PanelCapture.quarterTurns(guestTurn: 0, deviceDegrees: 270, surfaceFollowsRotation: true) == 0,
            "a surface that follows the device"
        )
        #expect(PanelCapture.quarterTurns(guestTurn: .pi, deviceDegrees: 180, surfaceFollowsRotation: false) == 0)
    }
}
