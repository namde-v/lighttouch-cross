// Geometry shims: CoreGraphics is Apple-only, and HostRuntime uses only its
// geometry types (no drawing, no color, no images). These mirror the API
// surface HostRuntime actually uses: width/height, x/y, origin/size,
// zero, equality, and the labeled initializers.
//
// Deviations from CoreGraphics to know about:
// - CGFloat is Double here, as on all 64-bit Apple platforms.
// - Codable uses keyed containers ("width"/"height", "x"/"y", ...). Board's
//   Codable synthesis compiles on Linux, but the wire format is not
//   guaranteed to match Apple's CoreGraphics encoding.

public typealias CGFloat = Double

public struct CGSize: Sendable, Equatable, Hashable, Codable {
    public var width: CGFloat
    public var height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    /// CoreGraphics also spells these with Int (DeviceInfo.screenPixels).
    public init(width: Int, height: Int) {
        self.init(width: CGFloat(width), height: CGFloat(height))
    }

    public static let zero = CGSize(width: 0, height: 0)
}

public struct CGPoint: Sendable, Equatable, Hashable, Codable {
    public var x: CGFloat
    public var y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    public init(x: Int, y: Int) {
        self.init(x: CGFloat(x), y: CGFloat(y))
    }

    public static let zero = CGPoint(x: 0, y: 0)
}

public struct CGRect: Sendable, Equatable, Hashable, Codable {
    public var origin: CGPoint
    public var size: CGSize

    public init(origin: CGPoint, size: CGSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.origin = CGPoint(x: x, y: y)
        self.size = CGSize(width: width, height: height)
    }

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.init(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }

    public var x: CGFloat {
        get { origin.x }
        set { origin.x = newValue }
    }
    public var y: CGFloat {
        get { origin.y }
        set { origin.y = newValue }
    }
    public var width: CGFloat {
        get { size.width }
        set { size.width = newValue }
    }
    public var height: CGFloat {
        get { size.height }
        set { size.height = newValue }
    }

    public static let zero = CGRect(x: 0, y: 0, width: 0, height: 0)
}

public struct CGVector: Sendable, Equatable, Hashable, Codable {
    public var dx: CGFloat
    public var dy: CGFloat

    public init(dx: CGFloat, dy: CGFloat) {
        self.dx = dx
        self.dy = dy
    }

    public init(dx: Int, dy: Int) {
        self.init(dx: CGFloat(dx), dy: CGFloat(dy))
    }

    public static let zero = CGVector(dx: 0, dy: 0)
}
