// Same geometry disambiguation as the main target: Foundation and HostRuntime
// both define these on Linux; the port speaks HostRuntime's LTMGeometry.
import HostRuntime

typealias CGFloat = HostRuntime.CGFloat
typealias CGSize = HostRuntime.CGSize
typealias CGPoint = HostRuntime.CGPoint
typealias CGRect = HostRuntime.CGRect
typealias CGVector = HostRuntime.CGVector
