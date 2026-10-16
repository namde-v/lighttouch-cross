/// The lt_device_t handle registry (ui/ABI.md §1.2).
///
/// Opaque cookies minted at startup for each library device, stable for the
/// process lifetime; 0 is never valid. The registry maps both ways
/// (lt_device_find / lt_device_uuid) under one lock.
import Foundation

final class HandleRegistry: Sendable {
    static let shared = HandleRegistry()

    private let lock = NSLock()
    private var next: lt_device_t = 1
    private var byHandle: [lt_device_t: UUID] = [:]
    private var byUUID: [UUID: lt_device_t] = [:]

    private init() {}

    /// Registers `uuid`, returning its stable handle (idempotent).
    @discardableResult
    func register(_ uuid: UUID) -> lt_device_t {
        lock.withLock {
            if let existing = byUUID[uuid] { return existing }
            let handle = next
            next &+= 1
            byHandle[handle] = uuid
            byUUID[uuid] = handle
            return handle
        }
    }

    func handle(for uuid: UUID) -> lt_device_t? {
        lock.withLock { byUUID[uuid] }
    }

    func uuid(for handle: lt_device_t) -> UUID? {
        guard handle != 0 else { return nil }
        return lock.withLock { byHandle[handle] }
    }

    /// Removes a device's handle (device deleted from the library).
    func unregister(_ uuid: UUID) {
        lock.withLock {
            guard let handle = byUUID.removeValue(forKey: uuid) else { return }
            byHandle.removeValue(forKey: handle)
        }
    }

    func unregister(handle: lt_device_t) {
        lock.withLock {
            guard let uuid = byHandle.removeValue(forKey: handle) else { return }
            byUUID.removeValue(forKey: uuid)
        }
    }

    /// All live handles (tests, diagnostics).
    func allHandles() -> [lt_device_t] {
        lock.withLock { Array(byHandle.keys) }
    }

    /// Clears the registry. Tests and lt_shutdown only.
    func resetForTests() {
        lock.withLock {
            next = 1
            byHandle = [:]
            byUUID = [:]
        }
    }
}
