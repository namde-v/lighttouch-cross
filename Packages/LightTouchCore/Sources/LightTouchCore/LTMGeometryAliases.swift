// Geometry for this module: HostRuntime's LTMGeometry types, unambiguous.
//
// Both Foundation (swift-corelibs-foundation) and HostRuntime define
// CGFloat/CGSize/CGPoint/CGRect/CGVector on Linux, so a file importing both
// sees every geometry type as ambiguous. These module-scope aliases pin this
// module to HostRuntime's (the port's canonical geometry, per SHIM_NOTES.md);
// a file that needs Foundation's can still name it `Foundation.CGSize`.
//
// Public: these types appear in public signatures throughout the module.
import HostRuntime

public typealias CGFloat = HostRuntime.CGFloat
public typealias CGSize = HostRuntime.CGSize
public typealias CGPoint = HostRuntime.CGPoint
public typealias CGRect = HostRuntime.CGRect
public typealias CGVector = HostRuntime.CGVector

// HostRuntime's CGRect is geometry-minimal (origin/size); the CoreGraphics
// conveniences used here live in this extension instead of in HostRuntime.
// Nonisolated: pure geometry, used from nonisolated contexts.
extension CGRect {
    public nonisolated var minX: CGFloat { origin.x }
    public nonisolated var minY: CGFloat { origin.y }
    public nonisolated var maxX: CGFloat { origin.x + size.width }
    public nonisolated var maxY: CGFloat { origin.y + size.height }
    public nonisolated var midX: CGFloat { origin.x + size.width / 2 }
    public nonisolated var midY: CGFloat { origin.y + size.height / 2 }
    public nonisolated func insetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        CGRect(
            x: origin.x + dx, y: origin.y + dy,
            width: size.width - 2 * dx, height: size.height - 2 * dy)
    }
    /// CoreGraphics convention: the minimum edges count as inside.
    public nonisolated func contains(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }
}
