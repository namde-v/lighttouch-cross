/// Lock-protected snapshot caches (ui/ABI.md §4.2).
///
/// @MainActor state that Qt polls (device list/rows, status, tweaks, carrier,
/// jobs, catalog, …) is serialized to JSON by Swift on its own thread and the
/// copy is stored here. Queries only take the lock, copy the bytes out, and
/// return — they never hop to @MainActor and never block on it.
///
/// Keys are namespaced strings: global snapshots live in one map, per-device
/// snapshots in another keyed by lt_device_t.
import Foundation
import LTBridgeC

final class SnapshotStore: @unchecked Sendable {
    static let shared = SnapshotStore()

    private let lock = NSLock()
    private var global: [String: Data] = [:]
    private var perDevice: [lt_device_t: [String: Data]] = [:]

    private init() {}

    // MARK: - Writers (@MainActor refresh path)

    func setGlobal(_ key: String, json: Data) {
        lock.withLock { global[key] = json }
    }

    func setDevice(_ handle: lt_device_t, key: String, json: Data) {
        lock.withLock { perDevice[handle, default: [:]][key] = json }
    }

    func removeDevice(_ handle: lt_device_t) {
        lock.withLock { perDevice.removeValue(forKey: handle) }
    }

    // MARK: - Readers (query path: lock, copy, return)

    func global(_ key: String) -> Data? {
        lock.withLock { global[key] }
    }

    func device(_ handle: lt_device_t, key: String) -> Data? {
        lock.withLock { perDevice[handle]?[key] }
    }

    /// Clears everything. Tests and lt_shutdown only.
    func resetForTests() {
        lock.withLock {
            global = [:]
            perDevice = [:]
        }
    }
}

/// JSON encode helper: Encodable → Data with sorted keys (stable snapshots).
func ltEncodeJSON<T: Encodable>(_ value: T) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    return try? encoder.encode(value)
}

/// Decodes a JSON document passed in from C (borrowed string → Data → T).
func ltDecodeJSON<T: Decodable>(_ json: String, as type: T.Type = T.self) -> T? {
    try? JSONDecoder().decode(T.self, from: Data(json.utf8))
}
