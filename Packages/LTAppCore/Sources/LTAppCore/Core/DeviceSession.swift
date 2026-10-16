/// The portable per-device session (ui/ABI.md §6 gap 1).
///
/// Mirrors `upstream/LightTouchMac/Device/EmulatorController.swift` (the
/// composition root the port has no equivalent of) without any AppKit: one
/// session per library device, owning its boot, its helper process and every
/// Session component through its host protocol (the extension in
/// DeviceSession+Hosts.swift).
///
/// What this wires for real: the VM lifecycle (MachineState), restart/power-on
/// (BootCycle), stop/shut-down (ShutdownLadder), erase (DeviceErase), notices
/// (DeviceNotices), input (DeviceInput/KeyboardInput), rotation
/// (DeviceRotation), tweaks (DeviceTweaks + TweaksPanelModel), carrier
/// (CarrierModem + CarrierPanelModel), app management (DeviceApps), boot
/// options (DeviceOptions), the web proxy (DeviceWebProxy), boot/readiness
/// watches, usbmuxd (USBMux), the guest agent/services, screen recording, and
/// the Qt-facing display-link mirror ring.
///
/// Deliberately not wired in this pass (no §3 export needs them; tracked in
/// ADDITIONS.md): ForegroundWatch, ConnectionRecovery, ActivationCheck,
/// GuestPackageWatch, vibration, host sleep (HostPower), the serial log
/// capture, and the device file watch. Their host-protocol surface is stubbed
/// where a component requires it, with safe defaults.
import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore

/// Boot options for lt_device_boot, parsed from the optionsJson document.
struct LTBootOptions: Decodable {
    var panel: String?
    var network: Bool?
    var debugPort: Bool?
    var bootArgs: String?
}

@MainActor
final class DeviceSession {
    /// The library record this session runs.
    var instance: DeviceInstance
    let profile: Board
    /// Directories from lt_init's config (app-owned on Linux/Windows).
    let directories: LTAppDirectories
    /// The helper executable URL (resourceDir/LightTouchDevice), if present.
    let helperURL: URL?

    // MARK: - Bookkeeping

    let bootScope = BootSessionScope()
    let workers = WorkerRetirement()
    private(set) var state: VMState = .notStarted
    var isErasing = false
    var started = false
    var isReleased = false
    var expectsSetup = false
    var inRecovery = false
    var storageFailedReported = false
    /// Set while lt_device_erase / DeviceErase runs; ShutdownHost reads it.
    var filesMeddled = false

    /// This helper's process, from restart() until its death.
    var process: DeviceProcess?
    var link: DeviceLink? { process?.link }
    var status: SharedStatus? { process?.status }
    /// What this helper's boot was built with (BootSettings); a Start after
    /// Shut Down compares it with the next (BootCycleHost.nextStartChanged).
    var bootSettings: BootSettings?
    var lastFrameSerial: UInt64 = 0

    // MARK: - Settings, notices, watches

    private(set) lazy var settingsFile = DeviceSettingsFile(directory: paths.directory)
    private(set) lazy var notices = DeviceNotices(
        settings: settingsFile,
        shortName: profile.shortName
    ) { [weak self] in self?.storageFailed ?? false }
    private(set) lazy var readiness = ReadinessWatch(host: self, notices: notices)
    private(set) lazy var bootWatch = BootWatch(host: self)

    // MARK: - Machine control

    private(set) lazy var cycle = BootCycle(host: self)
    private(set) lazy var ladder = ShutdownLadder(host: self)
    private(set) lazy var eraser = DeviceErase(host: self)

    // MARK: - Input

    private(set) lazy var input = DeviceInput(host: self, settings: settingsFile)
    private(set) lazy var keyboard = KeyboardInput(
        settings: settingsFile,
        canToggleHardwareKeyboard: profile.canToggleHardwareKeyboard,
        control: { [weak self] request, done in self?.keyboardControl(request, done: done) },
        send: { [weak self] command in self?.link?.send(command) },
        canPress: { [weak self] in self.map { $0.acceptsInput && !$0.isSleeping } ?? false }
    )
    private(set) lazy var rotation = DeviceRotation(
        host: self,
        settings: settingsFile,
        setsAccelerometer: profile.orientationSource == .springBoard
    )
    var compassHeading: Int?

    // MARK: - Panels

    private(set) lazy var tweaks = DeviceTweaks(
        settings: settingsFile,
        version: iosVersion,
        guestTools: hasGuestTools,
        clockPinned: false,
        guestRoot: directories.resourceDir
    )
    private(set) lazy var tweaksPanel = TweaksPanelModel(tweaks: tweaks, guest: nil)
    private(set) lazy var carrierModem = CarrierModem(
        hasCellular: profile.hasCellular,
        settings: settingsFile,
        scope: bootScope
    ) { [weak self] in self?.link }
    private(set) lazy var carrierPanel = CarrierPanelModel(backend: self)

    // MARK: - App management, options, proxy

    private(set) lazy var apps = DeviceApps(host: self)
    private(set) lazy var options = DeviceOptions(
        settings: settingsFile,
        board: instance.board,
        link: { [weak self] in self?.link }
    )
    private(set) lazy var proxy = DeviceWebProxy(
        directory: { [weak self] in
            guard let self else { return URL(fileURLWithPath: "/tmp") }
            return WebProxyConfiguration.directory(for: instance)
        },
        shortName: profile.shortName
    )
    let usbmux = USBMux()
    let agentCache = GuestAgentCache()
    var guestAgent: GuestAgent { GuestAgent(link: nil, cache: agentCache) }
    var guest: GuestServices { GuestServices(agent: guestAgent) }

    // MARK: - Capture

    /// This device's screen recording (one at a time; Swift owns the session).
    private(set) lazy var recording = ScreenRecordingSession()
    /// Screenshot in flight (CaptureAvailability.screenshotBusy).
    var screenshotBusy = false
    /// The Qt-facing display-link mirror (created on hello, see ShmCapture.swift).
    var displayMirror: QtFrameMirror?

    // MARK: - Status poll

    private var statusTimer: Timer?
    private var lastPolledFrameSerial: UInt64 = 0

    // MARK: - Init

    init(instance: DeviceInstance, profile: Board, directories: LTAppDirectories, helperURL: URL?) {
        self.instance = instance
        self.profile = profile
        self.directories = directories
        self.helperURL = helperURL
    }

    var paths: DeviceInstance.Paths {
        instance.paths(state: directories.stateDir, logs: directories.logDir)
    }

    var iosVersion: String {
        AppCore.shared?.catalog.entry(id: instance.firmware)?.version ?? ""
    }

    var hasGuestTools: Bool { profile.hasGuestTools }
    var isDead: Bool { state.isDead }
    var isPoweredOff: Bool { state == .poweredOff }
    var isSleeping: Bool { false } // host sleep is not wired on Linux/Windows yet (ADDITIONS.md)
    var isRunning: Bool { state == .running }
    var isPaused: Bool { state == .paused }
    var shuttingDown: Bool { ladder.shuttingDown }
    var storageFailed: Bool { status?.storageFailed ?? false }
    var preparingDevice: Bool { readiness.preparingDevice }
    var isInstalling: Bool { false } // wired to AppInstaller when installs run
    var acceptsInput: Bool {
        isRunning && !isSleeping && deviceReachable == true
    }
    var deviceReachable: Bool?
    var canReachDevice: Bool { deviceReachable == true }
    var halting: Bool { ladder.halting }

    /// The one way `state` changes (VMState.transition(to:)).
    func transition(to next: VMState) {
        let old = state
        state.transition(to: next)
        if state != old {
            AppCore.shared?.sessionStateChanged(self)
        }
    }

    // MARK: - Boot / halt / pause / reset / lock

    /// lt_device_boot: BootSettings from optionsJson, then a fresh helper.
    func boot(options: LTBootOptions?) {
        guard !isReleased else { return }
        if let panel = options?.panel { instance.panel = panel }
        bootSettings = BootSettings(
            panel: options?.panel ?? instance.panel,
            network: options?.network ?? NetworkAccessPreference.decided(defaults: ltPrefs()) ?? true,
            debugPort: options?.debugPort ?? options.debugPortEnabled,
            bootArgs: options?.bootArgs ?? DeviceOptions.bootArgs(ltPrefs())
        )
        restart()
    }

    /// Spawns a fresh helper (DeviceSessionHost.restart in upstream).
    func restart() {
        guard !isReleased else { return }
        retireBoot()
        let instanceID = instance.id
        let profile = profile
        let logURL = paths.logs.appendingPathComponent("native.log")
        let process = DeviceProcess(
            instance: instanceID,
            profile: profile,
            log: logURL,
            lease: paths.lease,
            helper: helperURL
        )
        self.process = process
        lastFrameSerial = 0
        lastPolledFrameSerial = 0
        process.onDeath = { [weak self, weak process] reason in
            guard let self, let process, self.process === process else { return }
            Task { @MainActor in self.helperDied(reason: reason) }
        }
        transition(to: .booting)
        notices.helperStarted()
        startStatusPoll()
        process.start(
            { [weak self] info in self?.bootConfiguration(hardware: info.deviceInfo) },
            preparation: nil
        ) { [weak self] result in
            if case .failure(let error) = result {
                Task { @MainActor in self?.failBoot(error) }
            }
        }
    }

    /// Builds the BootConfig after the helper's hello (nil = cannot boot).
    private func bootConfiguration(hardware: DeviceInfo?) -> BootConfig? {
        guard !isDead, !isReleased else { return nil }
        proxy.forgetEndpoint()
        let prepared: PreparedDeviceBoot
        do {
            guard let hardware else {
                throw DeviceToolsError.failed("The emulator library has no machine for this \(profile.shortName).")
            }
            prepared = try PreparedDeviceBoot.prepare(
                board: profile,
                base: paths.base,
                overlay: paths.overlay,
                writableNOR: paths.writableNOR,
                storageKey: instance.storage.key,
                bootrom: BootRecipe.bootrom(profile.bootrom, filesRoot: directories.filesRoot),
                dieID: instance.identity?.dieID,
                panel: bootSettings?.panel,
                clock: tweaks.bootClock
            )
        } catch PreparedDeviceBoot.Failure.baseMismatch {
            notices.report(
                "This \(profile.shortName)’s data was made with an older system image.", for: .erase)
            endBoot(.unbuildable)
            return nil
        } catch {
            failBoot(error)
            return nil
        }
        let usbSession = usbmux.start(paths: paths)
        do {
            var config = try prepared.configuration(
                hardware: hardware,
                bootArgs: bootSettings?.bootArgs ?? "",
                usbAddress: usbSession?.guestAddress,
                wifi: bootSettings?.network ?? true,
                guestPackage: nil,
                serial: "null",
                audio: ["-audio", "driver=none"],
                netdev: nil,
                carrier: profile.hasCellular ? carrierModem.carrierSettings : nil,
                refreshHz: 60
            )
            config.webProxy = proxy.endpoint
            if let port = options.chooseDebugPort(booting: true) {
                config.argv += DebugPort.arguments(port: port)
            }
            cycle.begin()
            return config
        } catch {
            failBoot(error)
            return nil
        }
    }

    private func failBoot(_ error: Error) {
        logEvent("boot: \(instance.name): \(error)")
        notices.report(error.localizedDescription, for: .powerOff)
        endBoot(.unbuildable)
    }

    /// The helper died: release the boot's resources, mark dead unless halted.
    func helperDied(reason: String) {
        let wasHalting = halting
        releaseBootResources()
        if !wasHalting {
            notices.report(reason, for: .powerOff)
        }
        endBoot(.helperGone)
    }

    func endBoot(_ end: BootEnd) {
        retireBoot()
        switch end {
        case .unbuildable:
            transition(to: .dead(nil))
        case .guestPoweredOff:
            transition(to: .poweredOff)
        case .helperGone:
            // A halt's exit is Stopped (already .poweredOff via the ladder);
            // anything else is a crash: dead.
            if !isPoweredOff && !isDead { transition(to: .dead(nil)) }
        }
        AppCore.shared?.sessionBootEnded(self, end: end)
    }

    func retireBoot() {
        guard !bootScope.retired else { return }
        bootScope.retire()
    }

    /// The helper is gone: the status poll, mirror ring and usbmuxd end with it.
    func releaseBootResources() {
        stopStatusPoll()
        if let mirror = displayMirror {
            displayMirror = nil
            mirror.close()
            AppCore.shared?.postDisplayLinkClosed(self)
        }
        usbmux.stop()
        process = nil
        rotation.stopWatching()
    }

    // MARK: - Teardown

    /// Releases the session (lt_shutdown / device deleted).
    func release() {
        isReleased = true
        retireBoot()
        releaseBootResources()
        recording.dismiss()
    }
}
