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
    func resyncTimeZone() {
        // TimeZoneSync is not wired in this pass (ADDITIONS.md); the clock is
        // set at boot from Tweaks' bootClock via the machine options.
    }
}

extension DeviceSession: BootCycleHost {
    var helper: DeviceHelper? { process }
    var nextStartChanged: Bool { bootSettings.map { $0 != currentBootSettings } ?? false }

    var currentBootSettings: BootSettings {
        BootSettings(
            panel: instance.panel,
            network: NetworkAccessPreference.decided(defaults: ltPrefs()) ?? true,
            debugPort: options.debugPortEnabled,
            bootArgs: DeviceOptions.bootArgs(ltPrefs())
        )
    }

    func syncGuest() async throws {
        // Guest filesystem sync goes through the guest agent's sync op; without
        // a live agent there is nothing to sync through (BootCycle then takes
        // the halt-and-fresh-helper path via hasGuestTools == false).
        throw SessionUnavailable()
    }

    func halt() -> Task<Bool, Never> { ladder.halt() }

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

    func startBootWatch() { bootWatch.start() }
}

extension DeviceSession: ShutdownHost {
    func willStop() {
        AppInstaller.discard(for: instance.id)
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

    func discardInstalls() { AppInstaller.discard(for: instance.id) }

    func stopGuestWatches() {
        rotation.stopWatching()
    }
}

extension DeviceSession: InputHost {
    var keyboardInputEnabled: Bool { keyboard.enabled }

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

    func pressHome() { input.tap(.home) }

    func readyForInput() { deviceReachable = true }
}

extension DeviceSession: BootWatchHost {
    var bootFinished: Bool { deviceReachable == true }

    // BootWatchHost.discardInstalls is covered by the EraseHost extension's
    // discardInstalls() (same signature); releaseBootResources is on the class.
}

extension DeviceSession: AppsHost {
    var usbmuxSession: String? { usbmux.session?.clientSocket }
    var guestUDID: String? { instance.identity?.udid }
    var installerUsesDevice: Bool { AppInstaller.isUsingDevice(instance.id) }
}

// MARK: - CarrierBackend (@MainActor protocol)

extension DeviceSession: CarrierBackend {
    var carrierSettings: CarrierSettings { carrierModem.carrierSettings }

    @discardableResult
    func setCarrierSettings(_ settings: CarrierSettings) -> Bool {
        carrierModem.setCarrierSettings(settings)
    }

    func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void) {
        carrierModem.modem(property, value, done: done)
    }

    func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void) {
        carrierModem.modemStatus(done)
    }
}

// MARK: - Keyboard control (MachineControl)

extension DeviceSession {
    /// Wires KeyboardInput's control through BootSessionScope.control: the
    /// reply lands on @MainActor and is dropped when the boot retired.
    func keyboardControl(_ request: LinkRequest, done: @escaping @MainActor (Bool) -> Void) {
        bootScope.control(request, on: link, done)
    }
}
