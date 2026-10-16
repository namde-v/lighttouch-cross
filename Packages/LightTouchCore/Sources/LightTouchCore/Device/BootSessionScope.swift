import Foundation
import Observation

/// Owns work which must never outlive one boot. The halt transaction itself
/// belongs to the controller, so retiring a boot cannot cancel its cleanup.
/// Observable: which boot is current (`id`, `retired`), for what follows each boot (AppChangeWatch).
///
/// Nonisolated (was @MainActor): the session state machines call the host's
/// BootSessionScope from background threads, so the scope must be callable
/// off @MainActor. Mutable state is guarded by `lock`. Changed for LTAppCore
/// (the portable app-core orchestrator, ui/ABI.md §6 gap 1).
public final class BootSessionScope: @unchecked Sendable {
    public init() {}
    public enum Work: CaseIterable {
        case foreground, readiness, recovery, watchdog, timeZone, orientation
        case guestPackage, activation, staging, powerOn, reset
    }
    private let lock = NSLock()
    private var _id = UUID()
    public var id: UUID {
        get { lock.withLock { _id } }
    }
    @ObservationIgnored private var _generation = 0
    public var generation: Int {
        get { lock.withLock { _generation } }
    }
    private var _retired = false
    public var retired: Bool {
        get { lock.withLock { _retired } }
    }
    @ObservationIgnored private var tasks: [Work: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [String: NSObjectProtocol] = [:]

    public subscript(work: Work) -> Task<Void, Never>? {
        get { lock.withLock { tasks[work] } }
        set {
            lock.withLock {
                tasks[work]?.cancel()
                guard !_retired else {
                    newValue?.cancel()
                    return
                }
                tasks[work] = newValue
            }
        }
    }
    public var timeZoneObserver: NSObjectProtocol? {
        get { lock.withLock { observers["timeZone"] } }
        set { setObserver("timeZone", newValue) }
    }
    /// The Mac's region and 24-hour setting (NSLocale.currentLocaleDidChangeNotification).
    public var localeObserver: NSObjectProtocol? {
        get { lock.withLock { observers["locale"] } }
        set { setObserver("locale", newValue) }
    }
    private func setObserver(_ key: String, _ newValue: NSObjectProtocol?) {
        lock.withLock {
            if let old = observers[key] { NotificationCenter.default.removeObserver(old) }
            guard !_retired else {
                if let newValue { NotificationCenter.default.removeObserver(newValue) }
                observers[key] = nil
                return
            }
            observers[key] = newValue
        }
    }
    public func retire() {
        lock.withLock {
            guard !_retired else { return }
            _retired = true
            _generation += 1  // invalidate suspended completions before another boot
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
        }
        // Observers touch NotificationCenter; do it outside the lock.
        timeZoneObserver = nil
        localeObserver = nil
    }
    public func renew() {
        retire()
        lock.withLock {
            _id = UUID()
            _retired = false
        }
    }
}
// force rebuild
