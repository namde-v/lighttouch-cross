// The guest's own install and uninstall notifications (notification_proxy) for the device's current boot, so the
// inspector's list changes the moment an app does instead of on its next poll.

import Foundation
import HostServiceClient
import HostServiceWire

/// One watcher per boot: on the boot's endpoint (which carries the boot's id), replaced as soon as Restart or Power On
/// renews the boot, stopped while the device has no services. Only the current boot's events reach `onChange`.
///
/// Thread-safe and synchronous (not @MainActor): the boot-change notification calls it
/// off the main thread, and @MainActor hops never execute on Linux without a pumped main
/// queue. Mutable state is guarded by `lock`.
///
/// BootSessionScope is not @Observable (nonisolated for background-thread use), so boot
/// renewals and retirements arrive via `bootSessionScopeDidChange`, not observation tracking.
public final class AppChangeWatch: @unchecked Sendable {
    private let apps: DeviceApps
    private let attachAllowed: @Sendable () async -> Bool
    private let onChange: @Sendable () -> Void
    /// The watcher's attach and observe; nil is NotificationProxy's own (the services worker).
    nonisolated(unsafe) var observe: NotificationProxy.Observer?

    private let lock = NSLock()
    nonisolated(unsafe) private var _endpoint: HostServiceEndpoint?
    nonisolated(unsafe) private var _watcher: NotificationProxy?
    nonisolated(unsafe) private var _bootObserver: NSObjectProtocol?
    nonisolated(unsafe) private var _started = false

    public nonisolated var endpoint: HostServiceEndpoint? {
        lock.withLock { _endpoint }
    }

    public init(
        apps: DeviceApps,
        attachAllowed: @escaping @Sendable () async -> Bool,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.apps = apps
        self.attachAllowed = attachAllowed
        self.onChange = onChange
    }

    /// Watches the current boot from now on, following each new one.
    public nonisolated func start() {
        let alreadyStarted = lock.withLock { () -> Bool in
            guard !_started else { return true }
            _started = true
            return false
        }
        guard !alreadyStarted else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: .bootSessionScopeDidChange,
            object: apps.bootScope,
            queue: nil
        ) { [weak self] _ in self?.follow() }
        lock.withLock { _bootObserver = observer }
        // Initial follow: attach to the current boot now.
        follow()
    }

    public nonisolated func stop() {
        let observer: NSObjectProtocol? = lock.withLock {
            let o = _bootObserver
            _bootObserver = nil
            _started = false
            return o
        }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        endWatcher()
    }

    /// A new watcher when the boot changed, none without services.
    ///
    /// Synchronous on the caller's thread: @MainActor hops never execute on Linux
    /// without a pumped main queue, so this must not hop (the boot-change
    /// notification calls it directly).
    nonisolated private func follow() {
        let current = (try? apps.services)?.endpoint
        let watcher: NotificationProxy? = lock.withLock {
            guard current != _endpoint else { return nil as NotificationProxy? }
            _watcher?.stop()
            _watcher = nil
            _endpoint = current
            guard let current else { return nil }
            let w =
                observe.map {
                    NotificationProxy(
                        clientSocket: current.socket,
                        udid: current.udid,
                        session: current.session,
                        observe: $0
                    )
                } ?? NotificationProxy(clientSocket: current.socket, udid: current.udid, session: current.session)
            _watcher = w
            return w
        }
        // Start outside the lock: it spawns the watcher task.
        if let watcher {
            let attachAllowed = self.attachAllowed
            let onChange = self.onChange
            watcher.start(attachAllowed: attachAllowed) { [weak self] in
                guard let self, (try? self.apps.services)?.endpoint == current else { return }
                onChange()
            }
        }
    }

    nonisolated private func endWatcher() {
        lock.withLock {
            _watcher?.stop()
            _watcher = nil
            _endpoint = nil
        }
    }
}
