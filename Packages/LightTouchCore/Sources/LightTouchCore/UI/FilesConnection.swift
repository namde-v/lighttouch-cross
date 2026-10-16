// The Files window's tie to one device's boot. It browses through that boot's services endpoint, so retiring the
// boot stops its worker, and a copy pins it there until the copy ends, whatever is selected meanwhile and however
// the device's reachability reads.

import Foundation
import HostServiceWire

/// The Files window's tie to one device's boot. Nonisolated (was @Observable
/// @MainActor): the bridge's file exports read it from any thread. State is
/// guarded by `lock`. Changed for LTAppCore (ui/ABI.md §6 gap 1).
public final class FilesConnection: @unchecked Sendable {
    public struct Binding: Equatable, Sendable {
        public let device: UUID
        public let endpoint: HostServiceEndpoint
        public init(device: UUID, endpoint: HostServiceEndpoint) {
            self.device = device
            self.endpoint = endpoint
        }
    }

    public enum State: Equatable {
        case disconnected
        case connected(Binding)
        case transferring(Binding)
    }

    /// The app's one Files window's: what each device's hasFileTransfer reads.
    public static let shared = FilesConnection()

    private let lock = NSLock()
    private var _state = State.disconnected
    public var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    public init() {}

    public var binding: Binding? {
        switch state {
        case .disconnected: nil
        case .connected(let binding), .transferring(let binding): binding
        }
    }

    /// Files are being copied to or from `device`: its other reads stand aside (AppsDevice.readsSuppressed).
    public func isTransferring(_ device: UUID) -> Bool {
        if case .transferring(let binding) = state { binding.device == device } else { false }
    }

    /// Follows the selected device's boot. `reachable` nil is unknown (our own device work holds back the reads that
    /// would say), which keeps a binding to that same boot rather than dropping it. A copy keeps its binding.
    /// True when the binding changed, so the browser reloads.
    @discardableResult
    public func follow(device: UUID?, endpoint: HostServiceEndpoint?, reachable: Bool?) -> Bool {
        lock.withLock {
            if case .transferring = _state { return false }
            let target = device.flatMap { device in endpoint.map { Binding(device: device, endpoint: $0) } }
            let currentBinding: Binding? = {
                switch _state {
                case .disconnected: nil
                case .connected(let b), .transferring(let b): b
                }
            }()
            let next: State
            if let target, reachable == true || (reachable == nil && currentBinding == target) {
                next = .connected(target)
            } else {
                next = .disconnected
            }
            guard next != _state else { return false }
            _state = next
            return true
        }
    }

    /// The browser started or ended a copy.
    public func setTransferring(_ transferring: Bool) {
        lock.withLock {
            switch (_state, transferring) {
            case (.connected(let binding), true): _state = .transferring(binding)
            case (.transferring(let binding), false): _state = .connected(binding)
            default: break
            }
        }
    }
}
// force rebuild
