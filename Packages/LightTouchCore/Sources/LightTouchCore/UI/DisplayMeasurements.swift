import HostRuntime

/// CoreGraphics synthesizes a 72-dpi size when hardware measurements are absent.
/// Do not turn that estimate into a Physical Size command.
public enum DisplayMeasurements {
    #if os(macOS)
    /// The display `id` (NSScreen's NSScreenNumber) whose frame is `logical` points.
    public static func pointsPerMillimeter(display id: CGDirectDisplayID, logical: CGSize) -> CGFloat? {
        var millimeters = CGDisplayScreenSize(id)
        let rotation = Int(CGDisplayRotation(id)) % 180
        if rotation != 0 { millimeters = CGSize(width: millimeters.height, height: millimeters.width) }
        return pointsPerMillimeter(logical: logical, hardware: millimeters, fallbackBounds: CGDisplayBounds(id).size)
    }
    #else
    /// No display-server metadata on Linux/Windows in this port (CoreGraphics
    /// display services are macOS-only): physical-size detection is unavailable
    /// and the caller falls back. See SHIM_NOTES.md.
    public static func pointsPerMillimeter(display id: UInt32, logical: CGSize) -> CGFloat? {
        nil
    }
    #endif

    public static func pointsPerMillimeter(logical: CGSize, hardware: CGSize, fallbackBounds: CGSize) -> CGFloat? {
        let values = [logical.width, logical.height, hardware.width, hardware.height]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let estimated = CGSize(
            width: fallbackBounds.width * 25.4 / 72,
            height: fallbackBounds.height * 25.4 / 72
        )
        guard abs(hardware.width - estimated.width) > 1 || abs(hardware.height - estimated.height) > 1 else {
            return nil
        }
        let x = logical.width / hardware.width
        let y = logical.height / hardware.height
        // Reject unusable metadata rather than stretching the device.
        guard abs(x / y - 1) < 0.05 else { return nil }
        return (x + y) / 2
    }
}
