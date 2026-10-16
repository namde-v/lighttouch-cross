import Foundation
import HostRuntime

/// A capture of the panel turned the way the window shows it.
public enum PanelCapture {
    /// Clockwise quarter-turns from the panel's scan to the window: scan-to-upright (`guestTurn`, radians) plus,
    /// where the surface doesn't follow the device, the device's own rotation.
    public static func quarterTurns(guestTurn: CGFloat, deviceDegrees: Int, surfaceFollowsRotation: Bool) -> Int {
        let device = surfaceFollowsRotation ? 0 : deviceDegrees / 90
        return ((Int((guestTurn * 2 / .pi).rounded()) + device) % 4 + 4) % 4
    }

    /// `image` turned clockwise by `turns` quarters; the image itself for none.
    public static func rotated(_ image: LTMImage, clockwiseQuarterTurns turns: Int) -> LTMImage {
        image.rotated(clockwiseQuarterTurns: turns)
    }
}
