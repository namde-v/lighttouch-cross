import HostRuntime

/// A two-finger trackpad scroll over the screen as one finger dragging the content (0...1 panel space), sent as the
/// events are handled: down where the cursor is at the fingers' began (moved by that event's own delta), moving with
/// each changed, up at their ended. The momentum phase AppKit sends after the fingers leave is the host's inertia,
/// not a finger: the guest's scroll view has its own, from the finger's last movements. Ignoring all of it also
/// keeps a momentum event from an earlier flick (one that ends after the next swipe's fingers land) from moving or
/// lifting the next swipe's finger.
nonisolated public struct ScrollDrag {
    /// NSEvent.Phase's values, for `phase`.
    public struct Phase: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let began = Phase(rawValue: 1)
        public static let stationary = Phase(rawValue: 2)
        public static let changed = Phase(rawValue: 4)
        public static let ended = Phase(rawValue: 8)
        public static let cancelled = Phase(rawValue: 16)
        public static let mayBegin = Phase(rawValue: 32)
    }
    public enum TouchPhase: Equatable, Sendable { case begin, update, end }
    public struct Touch: Equatable, Sendable {
        public let phase: TouchPhase
        public let point: CGPoint
        public init(_ phase: TouchPhase, _ point: CGPoint) {
            self.phase = phase
            self.point = point
        }
    }

    /// The finger, while it is down.
    public private(set) var point: CGPoint?

    public init() {}

    /// One scroll event's finger phase (empty for a momentum event). `delta`: its movement in panel space; `start`:
    /// the panel point under the cursor, where a gesture's finger goes down.
    public mutating func scroll(phase: Phase, delta: CGVector, start: CGPoint?) -> [Touch] {
        switch phase {
        case .began:
            guard let start else { return [] }
            var touches = lift()
            point = start
            touches.append(Touch(.begin, start))
            return touches + move(delta)
        case .changed:
            return move(delta)
        case .ended, .cancelled:
            return lift()
        default:
            return []
        }
    }

    private mutating func move(_ delta: CGVector) -> [Touch] {
        guard var p = point, delta.dx != 0 || delta.dy != 0 else { return [] }
        p.x = min(max(p.x + delta.dx, 0), 1)
        p.y = min(max(p.y + delta.dy, 0), 1)
        point = p
        return [Touch(.update, p)]
    }

    private mutating func lift() -> [Touch] {
        guard let p = point else { return [] }
        point = nil
        return [Touch(.end, p)]
    }
}
