/// The Swift→C++ event fan-out (ui/ABI.md §2, §4.3).
///
/// One registered C callback per process. Swift builds the `LTEvent` on the
/// producing thread, mallocs its strings, invokes the callback synchronously,
/// then deep-frees the strings. The callback is a leaf: Swift never waits on
/// it and never retains the event afterwards.
///
/// Threading: every mutable field is guarded by one NSLock (spike note:
/// `nonisolated(unsafe)` + lock). Events post from arbitrary Swift threads —
/// helper-link threads, job tasks, @MainActor — so posting takes the lock,
/// copies the callback/ctx pair out, and invokes without holding it.
import Foundation
import LTBridgeC

final class EventPump: Sendable {
    static let shared = EventPump()

    private let lock = NSLock()
    private var callback: lt_event_fn?
    private var ctx: UnsafeMutableRawPointer?
    private var dropped: UInt64 = 0
    private var coalesced: UInt64 = 0
    private var seqs: [Int32: UInt64] = [:]

    // Coalescing state (ui/ABI.md §2.3, §4.3).
    private var deviceListPending = false
    private var lastCarrierPost = Date.distantPast

    private init() {}

    // MARK: - Registration (ui/ABI.md §2.1, §2.4)

    /// Idempotent; nil unregisters. Re-registering replaces the previous.
    func setCallback(_ fn: lt_event_fn?, _ ctx: UnsafeMutableRawPointer?) {
        lock.withLock {
            self.callback = fn
            self.ctx = ctx
        }
    }

    func droppedEvents() -> UInt64 { lock.withLock { dropped } }
    func coalescedEvents() -> UInt64 { lock.withLock { coalesced } }

    /// The last sequence number issued for a kind (tests).
    func lastSeq(for kind: Int32) -> UInt64 { lock.withLock { seqs[kind] ?? 0 } }

    // MARK: - Posting

    /// Posts one event. Assigns the per-kind monotonic `seq`, invokes the
    /// callback synchronously from the caller's thread, then frees the
    /// event's strings. When no callback is registered the event is dropped
    /// and the §2.4 diagnostics counter is bumped.
    func post(kind: Int32, device: lt_device_t = 0, build: (inout LTEvent) -> Void) {
        let (cb, c): (lt_event_fn?, UnsafeMutableRawPointer?) = lock.withLock { (callback, ctx) }
        guard let cb else {
            lock.withLock { dropped &+= 1 }
            return
        }
        var event = LTEvent()
        event.kind = kind
        event.device = device
        event.seq = lock.withLock {
            let next = (seqs[kind] ?? 0) &+ 1
            seqs[kind] = next
            return next
        }
        build(&event)
        // The callback may override seq (e.g. frameAvailable carries frameSeq).
        withUnsafePointer(to: &event) { cb($0, c) }
        ltFreeEventStrings(&event)
    }

    // MARK: - Coalesced posts (ui/ABI.md §2.3)

    /// Device-list changes burst (add/delete/rename/duplicate during imports);
    /// Swift debounces to at most one per ~frame (16 ms).
    func postDeviceListChanged() {
        let schedule: Bool = lock.withLock {
            guard !deviceListPending else { return false }
            deviceListPending = true
            return true
        }
        guard schedule else {
            lock.withLock { coalesced &+= 1 }
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(16))
            let fire: Bool = lock.withLock {
                defer { deviceListPending = false }
                return true
            }
            if fire { post(kind: kLTEventDeviceListChanged) }
        }
    }

    /// Carrier panel polls; its change event is throttled to at most 2/sec.
    func postCarrierChanged(device: lt_device_t) {
        let now = Date()
        let allow: Bool = lock.withLock {
            guard now.timeIntervalSince(lastCarrierPost) >= 0.5 else { return false }
            lastCarrierPost = now
            return true
        }
        guard allow else {
            lock.withLock { coalesced &+= 1 }
            return
        }
        post(kind: kLTEventCarrierChanged, device: device)
    }

    // MARK: - Test support

    /// Resets callback, counters and coalescing state. Tests only.
    func resetForTests() {
        lock.withLock {
            callback = nil
            ctx = nil
            dropped = 0
            coalesced = 0
            seqs = [:]
            deviceListPending = false
            lastCarrierPost = .distantPast
        }
    }
}
