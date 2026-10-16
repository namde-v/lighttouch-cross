import LTBridgeC
/// DeviceSession's host-protocol conformances: the Session components run
/// against the session through these (mirrors the extension at the end of
/// upstream's EmulatorController.swift).
///
/// Methods that need a live helper/guest degrade gracefully: link-dependent
/// reads return nil/false, guest operations throw `SessionUnavailable`, and
/// user-visible failures go through DeviceNotices. Nothing here fabricates a
/// live device.
import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import LightTouchCore

/// Thrown by host operations that need a live guest/helper when there is none.
struct SessionUnavailable: Error, LocalizedError {
    var errorDescription: String? { "The device isn’t running." }
}

extension DeviceSession: MachineHost {
    var helperLink: (any HelperLink)? { fastLink }
    func resyncTimeZone() {
        // TimeZoneSync is not wired in this pass (ADDITIONS.md); the clock is
        // set at boot from Tweaks' bootClock via the machine options.
    }
}

extension DeviceSession: BootCycleHost {
    /// BootCycle's handle on the helper process. DeviceProcess itself is
    /// @MainActor, so the facade hops; nil when there is no process yet
    /// (preserves BootCycle's "no helper -> restart" logic).
    var helper: DeviceHelper? {
        guard process != nil else { return nil }
        return SessionDeviceHelper(self)
    }
    var nextStartChanged: Bool { bootSettings.map { $0 != currentBootSettings } ?? false }

    var currentBootSettings: BootSettings {
        // The debug-port choice is cached on the session (DeviceOptions is
        // @MainActor); the rest are pure reads.
        let debugPort = lock.withLock { _bgDebugPort }
        return BootSettings(
            panel: instance.panel,
            network: NetworkAccessPreference.decided(defaults: ltPrefs() ?? UserDefaults.standard) ?? true,
            debugPort: debugPort,
            bootArgs: DeviceOptions.bootArgs(ltPrefs() ?? UserDefaults.standard)
        )
    }

    func syncGuest() async throws {
        // Guest filesystem sync goes through the guest agent's sync op; without
        // a live agent there is nothing to sync through (BootCycle then takes
        // the halt-and-fresh-helper path via hasGuestTools == false).
        throw SessionUnavailable()
    }

    /// May be called from background state-machine tasks; the ladder is
    /// @MainActor. The returned Task lets BootCycle await the halt.
    func halt() -> Task<Bool, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.ladder.halt().value
        }
    }

    func forgetBootFacts() {
        deviceReachable = nil
        expectsSetup = false
        inRecovery = false
        agentCache.reset()
    }

    func ensureUSBMux() {
        // usbmuxd starts per-boot in bootConfiguration (it must listen before
        // the guest's USB); nothing to re-ensure here.
    }

    func publishDeveloperConnection() {
        // DeveloperConnectionProfile wiring is not in this pass (ADDITIONS.md).
    }

    func resetRotation() { rotation.reset() }

    func startTimeZoneSync() {
        // TimeZoneSync not wired in this pass (ADDITIONS.md).
    }

    func startForegroundWatch() {
        // ForegroundWatch not wired in this pass (ADDITIONS.md).
    }

    func startOrientationWatch() {
        if hasGuestTools { rotation.startGuestWatch() } else { rotation.startInterfaceWatch() }
    }

    func startGuestPackageWatch() {
        // GuestPackageWatch not wired in this pass (ADDITIONS.md).
    }

    func startBootWatch() {
        Task { @MainActor [weak self] in self?.bootWatch.start() }
    }
}

extension DeviceSession: ShutdownHost {
    func willStop() {
        let id = instance.id
        // AppInstaller is @MainActor; discarding is a cleanup command.
        Task { @MainActor in AppInstaller.discard(for: id) }
    }
}

extension DeviceSession: EraseHost {
    var eraseTargets: DeviceErase.Targets {
        DeviceErase.Targets(
            overlay: paths.overlay,
            snapshots: [paths.snapshot, paths.snapshotMeta, paths.snapshotTmp, paths.snapshotBad],
            preparedNOR: paths.writableNOR,
            state: directories.stateDir,
            owner: instance.id
        )
    }

    func discardInstalls() {
        let id = instance.id
        Task { @MainActor in AppInstaller.discard(for: id) }
    }

    func stopGuestWatches() {
        // DeviceRotation is @MainActor; stopping a watch is a command.
        Task { @MainActor [weak self] in self?.rotation.stopWatching() }
    }
}

extension DeviceSession: InputHost {
    /// Cached by poll() on @MainActor (KeyboardInput is actor-bound).
    var keyboardInputEnabled: Bool { lock.withLock { _bgKeyboardInputEnabled } }

    func typeThroughAgent(_ text: String) async -> Bool {
        // it_agent's `type` into the focused field; no agent link is exposed
        // without a live guest, so typing falls back to key events (the
        // DeviceInput.typeText path handles that choice).
        false
    }
}

extension DeviceSession: RotationHost {
    func interfaceOrientation() async throws -> Int {
        // springboardservices' UIInterfaceOrientation; needs a live device.
        throw SessionUnavailable()
    }

    func guestOrientation() async throws -> Int? {
        // The guest agent's SpringBoard degrees; nil when no agent.
        nil
    }
}

extension DeviceSession: ReadinessHost {
    var isPainting: Bool { state == .running }
    var countsBootTime: Bool { !isSleeping && state != .paused }

    func deviceReady() async -> Bool {
        // The USB bridge sees the guest: usbmuxd is up and the guest answers.
        // Without a live helper there is nothing to ask.
        false
    }

    func waitForSpringBoard(agentCounts: Bool) async throws {
        throw SessionUnavailable()
    }

    func pressHome() {
        Task { @MainActor [weak self] in self?.input.tap(.home) }
    }

    func readyForInput() { deviceReachable = true }
}

extension DeviceSession: BootWatchHost {
    var bootFinished: Bool { deviceReachable == true }

    // BootWatchHost.discardInstalls is covered by the EraseHost extension's
    // discardInstalls() (same signature); releaseBootResources is on the class.
}

extension DeviceSession: AppsHost {
    /// Nonisolated: AppChangeWatch reads these from background threads. usbmuxSessionCached
    /// is lock-guarded; instance is set once at init and never mutated.
    nonisolated var usbmuxSession: String? { usbmuxSessionCached?.clientSocket }
    nonisolated var guestUDID: String? { instance.identity?.udid }
    /// Cached by poll() on @MainActor (AppInstaller is actor-bound).
    var installerUsesDevice: Bool { lock.withLock { _bgInstallerUsesDevice } }
}

// MARK: - CarrierBackend (@MainActor protocol)

extension DeviceSession: CarrierBackend {
    @MainActor var carrierSettings: CarrierSettings { carrierModem.carrierSettings }

    @MainActor
    @discardableResult
    func setCarrierSettings(_ settings: CarrierSettings) -> Bool {
        carrierModem.setCarrierSettings(settings)
    }

    @MainActor
    func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void) {
        carrierModem.modem(property, value, done: done)
    }

    @MainActor
    func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void) {
        carrierModem.modemStatus(done)
    }
}

// MARK: - Keyboard control (MachineControl)

extension DeviceSession {
    /// Wires KeyboardInput's control through BootSessionScope.control: the
    /// reply lands on @MainActor and is dropped when the boot retired.
    func keyboardControl(_ request: LinkRequest, done: @escaping @MainActor (Bool) -> Void) {
        // KeyboardInput's control closure runs off the main thread; the link
        // request itself is @MainActor.
        Task { @MainActor [weak self] in
            guard let self else { return done(false) }
            self.bootScope.control(request, on: self.fastLink, done)
        }
    }
}

// MARK: - SessionDeviceHelper

/// The nonisolated DeviceHelper the boot state machines use. DeviceProcess
/// itself is @MainActor, so reads go through the session's lock-guarded
/// caches and commands hop to @MainActor. BootCycle calls these from
/// background tasks, so every entry point must be nonisolated-safe.
final class SessionDeviceHelper: DeviceHelper, @unchecked Sendable {
    private weak var session: DeviceSession?

    init(_ session: DeviceSession) { self.session = session }

    var isDead: Bool {
        guard let session else { return true }
        return session.state.isDead
    }

    func terminate() {
        Task { @MainActor [weak self] in self?.session?.process?.terminate() }
    }

    func kill() {
        Task { @MainActor [weak self] in self?.session?.process?.kill() }
    }

    func waitForExit(timeout: TimeInterval) async -> Bool {
        let process = await MainActor.run { [weak self] in self?.session?.process }
        guard let process else { return true }
        return await process.waitForExit(timeout: timeout)
    }
}
