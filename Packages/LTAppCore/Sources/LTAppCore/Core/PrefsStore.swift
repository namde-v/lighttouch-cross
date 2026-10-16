/// File-backed `UserDefaults` for Linux/Windows (ui/ABI.md §6 gap 5).
///
/// `UserDefaults.standard` has no persistent backend on Linux (verified on
/// Swift 6.4.1: values do not survive the process), and several core models
/// persist through it (`ZoomMode.save(for:in:)`, `SidebarList.save(_:)`,
/// `CapturePreferences`, `CatalogFilter`, `NetworkAccessPreference`). Rather
/// than touching every call site, this one addition subclasses `UserDefaults`
/// with a JSON-file backend rooted at the app's config dir (from `lt_init`).
/// The core keeps calling its `*(_ defaults:)` APIs unchanged.
///
/// Only JSON-compatible values are stored (String, Bool, Int/Double, arrays,
/// dictionaries of those, Data as base64) — everything the core writes.
/// Writes are atomic and write-through under a lock; reads are lock-protected
/// in-memory (loaded once at init).
///
/// Platform notes: pure Foundation, no Darwin/Glibc/WinSDK imports — the same
/// file builds on Linux and Windows.
import Foundation
import LTBridgeC

/// A `UserDefaults` whose storage is a JSON dictionary in a single file.
final class LTFileDefaults: UserDefaults {
    private let fileURL: URL
    private let ioLock = NSLock()
    private var values: [String: Any]

    /// Creates (or opens) the backend at `fileURL`. Missing/corrupt files
    /// start empty; corruption is logged, never fatal. Failable only because
    /// `UserDefaults.init(suiteName:)` is (a hardcoded valid name never fails
    /// in practice).
    init?(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            self.values = dict
        } else {
            self.values = [:]
        }
        super.init(suiteName: "gold.samhenri.LightTouchMac.ltappcore")
    }

    // MARK: - Primitive overrides (the subclassing contract)

    override func object(forKey defaultName: String) -> Any? {
        ioLock.withLock { values[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        ioLock.withLock {
            if let value {
                values[defaultName] = LTFileDefaults.storable(value)
            } else {
                values.removeValue(forKey: defaultName)
            }
            persistLocked()
        }
    }

    override func removeObject(forKey defaultName: String) {
        ioLock.withLock {
            values.removeValue(forKey: defaultName)
            persistLocked()
        }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        ioLock.withLock { values }
    }

    // Convenience accessors route through the primitives explicitly: on some
    // corelibs builds the inherited ones consult the (non-persistent) suite.
    override func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    override func bool(forKey defaultName: String) -> Bool {
        (object(forKey: defaultName) as? Bool) ?? false
    }

    override func integer(forKey defaultName: String) -> Int {
        (object(forKey: defaultName) as? Int) ?? 0
    }

    override func double(forKey defaultName: String) -> Double {
        if let d = object(forKey: defaultName) as? Double { return d }
        if let i = object(forKey: defaultName) as? Int { return Double(i) }
        return 0
    }

    override func stringArray(forKey defaultName: String) -> [String]? {
        object(forKey: defaultName) as? [String]
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }

    override func data(forKey defaultName: String) -> Data? {
        guard let b64 = object(forKey: defaultName) as? String else { return nil }
        return Data(base64Encoded: b64)
    }

    // MARK: - Backend

    private func persistLocked() {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Normalizes a value to something JSONSerialization accepts.
    private static func storable(_ value: Any) -> Any {
        switch value {
        case let d as Data: return d.base64EncodedString()
        case let date as Date: return date.timeIntervalSince1970
        case let arr as [Any]: return arr.map(storable)
        case let dict as [String: Any]: return dict.mapValues(storable)
        case is String, is Bool, is Int, is Double: return value
        case let n as NSNumber: return n.doubleValue
        default: return String(describing: value)
        }
    }
}
