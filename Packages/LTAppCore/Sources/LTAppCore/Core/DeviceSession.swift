import LTBridgeC
/// The portable per-device session (ui/ABI.md §6 gap 1).
///
/// Mirrors `upstream/LightTouchMac/Device/EmulatorController.swift` (the
/// composition root the port has no equivalent of) without any AppKit: one
/// session per library device, owning its boot, its helper process and every
/// Session component through its host protocol (the extension in
/// DeviceSession+Hosts.swift).
///
/// Concurrency: the session is **nonisolated**. The Session state machines
/// (BootCycle, ShutdownLadder, DeviceErase, …) are nonisolated classes that
/// call their host's protocol requirements synchronously — including from
/// background Tasks — so the host side must be callable off @MainActor.
/// Mutable state is guarded by `lock`; the only @MainActor pieces are the
/// CarrierBackend witnesses and the carrier-panel entry points (CarrierPanelModel
/// is @MainActor), which run from @MainActor command tasks.
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

final class DeviceSession {
    /// Guards every mutable field below. Never held across a call into a
    /// component, AppCore, or the event pump (reentrancy would deadlock).
    private let lock = NSLock()

    /// The library record this session runs.
    var instance: DeviceInstance
    let profile: Board
    /// The firmware version (from the catalog at creation; drives tweaks).
    let firmwareVersion: String
    /// Directories from lt_init's config (app-owned on Linux/Windows).
    let directories: LTAppDirectories
    /// The helper executable URL (resourceDir/LightTouchDevice), if present.
    let helperURL: URL?

    // MARK: - Bookkeeping (lock-guarded)

    let bootScope = BootSessionScope()
    let workers = WorkerRetirement()
    private var _state: VMState = .notStarted
    var state: VMState {
        get { lock.withLock { _state } }
    }
    private var _isErasing = false
    var isErasing: Bool {
        get { lock.withLock { _isErasing } }
        set { lock.withLock { _isErasing = newValue } }
    }
    private var _started = false
    var started: Bool {
        get { lock.withLock { _started } }
        set { lock.withLock { _started = newValue } }
    }
    private var _isReleased = false
    var isReleased: Bool {
        get { lock.withLock { _isReleased } }
        set { lock.withLock { _isReleased = newValue } }
    }
    private var _expectsSetup = false
    var expectsSetup: Bool {
        get { lock.withLock { _expectsSetup } }
        set { lock.withLock { _expectsSetup = newValue } }
    }
    private var _inRecovery = false
    var inRecovery: Bool {
        get { lock.withLock { _inRecovery } }
        set { lock.withLock { _inRecovery = newValue } }
    }
    private var _storageFailedReported = false
    var storageFailedReported: Bool {
        get { lock.withLock { _storageFailedReported } }
        set { lock.withLock { _storageFailedReported = newValue } }
    }
    /// Set while lt_device_erase / DeviceErase runs; ShutdownHost reads it.
    private var _filesMeddled = false
    var filesMeddled: Bool {
        get { lock.withLock { _filesMeddled } }
        set { lock.withLock { _filesMeddled = newValue } }
    }

    /// This helper's process, from restart() until its death.
    private var _process: DeviceProcess?
    var process: DeviceProcess? {
        get { lock.withLock { _process } }
        set { lock.withLock { _process = newValue } }
    }
    /// The current helper link, mirrored for the input fast path (ui/ABI.md
    /// §4: input commands return in microseconds). `HelperLink.send` is
    /// thread-safe and ordered (DeviceLink writes on its own queue), and a
    /// stale link is harmless: sends to a dead helper are dropped by the link.
    nonisolated(unsafe) var fastLink: HelperLink?
    var link: DeviceLink? { process?.link }
    var status: SharedStatus? { process?.status }
    /// What this helper's boot was built with (BootSettings); a Start after
    /// Shut Down compares it with the next (BootCycleHost.nextStartChanged).
    private var _bootSettings: BootSettings?
    var bootSettings: BootSettings? {
        get { lock.withLock { _bootSettings } }
        set { lock.withLock { _bootSettings = newValue } }
    }
    private var _lastFrameSerial: UInt64 = 0
    var lastFrameSerial: UInt64 {
        get { lock.withLock { _lastFrameSerial } }
        set { lock.withLock { _lastFrameSerial = newValue } }
    }

    // MARK: - Settings, notices, watches (immutable after init)

    let settingsFile: DeviceSettingsFile
    let notices: DeviceNotices
    let readiness: ReadinessWatch
    let bootWatch: BootWatch

    // MARK: - Machine control (immutable after init)

    let cycle: BootCycle
    let ladder: ShutdownLadder
    let eraser: DeviceErase

    // MARK: - Input (immutable after init)

    let input: DeviceInput
    let keyboard: KeyboardInput
    let rotation: DeviceRotation
    private var _compassHeading: Int?
    var compassHeading: Int? {
        get { lock.withLock { _compassHeading } }
        set { lock.withLock { _compassHeading = newValue } }
    }

    // MARK: - Panels (immutable after init)

    let tweaks: DeviceTweaks
    let tweaksPanel: TweaksPanelModel
    let carrierModem: CarrierModem
    /// @MainActor (CarrierPanelModel is); only touched from @MainActor methods.
    let carrierPanel: CarrierPanelModel

    // MARK: - App management, options, proxy (immutable after init)

    let apps: DeviceApps
    let options: DeviceOptions
    let proxy: DeviceWebProxy
    /// @MainActor (USBMux is); only touched from @MainActor methods.
    private var _usbmux: USBMux?
    @MainActor var usbmux: USBMux {
        if let _usbmux { return _usbmux }
        let u = USBMux()
        _usbmux = u
        return u
    }
    /// The usbmux session, cached for the nonisolated AppsHost witness and
    /// bootConfiguration (USBMux itself is @MainActor; started in restart()).
    private var _usbmuxSession: USBMux.Session?
    var usbmuxSessionCached: USBMux.Session? {
        get { lock.withLock { _usbmuxSession } }
        set { lock.withLock { _usbmuxSession = newValue } }
    }
    let agentCache = GuestAgentCache()
    var guestAgent: GuestAgent { GuestAgent(link: nil, cache: agentCache) }
    var guest: GuestServices { GuestServices(agent: guestAgent) }

    // MARK: - Capture (lock-guarded)

    /// This device's screen recording (one at a time; Swift owns the session).
    /// @MainActor (ScreenRecordingSession is); only touched from @MainActor methods.
    private var _recording: ScreenRecordingSession?
    @MainActor var recording: ScreenRecordingSession {
        if let _recording { return _recording }
        let r = ScreenRecordingSession()
        _recording = r
        return r
    }
    /// Screenshot in flight (CaptureAvailability.screenshotBusy).
    private var _screenshotBusy = false
    var screenshotBusy: Bool {
        get { lock.withLock { _screenshotBusy } }
        set { lock.withLock { _screenshotBusy = newValue } }
    }
    /// The Qt-facing display-link mirror (created on hello, see ShmCapture.swift).
    private var _displayMirror: QtFrameMirror?
    var displayMirror: QtFrameMirror? {
        get { lock.withLock { _displayMirror } }
        set { lock.withLock { _displayMirror = newValue } }
    }
    /// The recording save handshake's state (gap 11; see DeviceSession+Capture.swift).
    let captureHandshake = CaptureHandshakeState()

    // MARK: - Status poll (driven by lt_pump_main_queue; see DeviceSession+Poll.swift)

    private var _lastPolledFrameSerial: UInt64 = 0
    var lastPolledFrameSerial: UInt64 {
        get { lock.withLock { _lastPolledFrameSerial } }
        set { lock.withLock { _lastPolledFrameSerial = newValue } }
    }
    private var _lastRecordingTickSecond: Int = -1
    var lastRecordingTickSecond: Int {
        get { lock.withLock { _lastRecordingTickSecond } }
        set { lock.withLock { _lastRecordingTickSecond = newValue } }
    }
    private var _wasErasing = false
    var wasErasing: Bool {
        get { lock.withLock { _wasErasing } }
        set { lock.withLock { _wasErasing = newValue } }
    }

    /// Display zoom, in percent (ui/ABI.md §3.4). Qt renders the frame scaled;
    /// the bridge only tracks the value and notifies.
    private var _zoomPercent: Double = 100
    var zoomPercent: Double {
        get { lock.withLock { _zoomPercent } }
        set { lock.withLock { _zoomPercent = newValue } }
    }
    /// Latest published frame size, for zoom-to-fit.
    private var _frameWidth: Int = 0
    var frameWidth: Int {
        get { lock.withLock { _frameWidth } }
        set { lock.withLock { _frameWidth = newValue } }
    }
    private var _frameHeight: Int = 0
    var frameHeight: Int {
        get { lock.withLock { _frameHeight } }
        set { lock.withLock { _frameHeight = newValue } }
    }

    /// The window's finger-dots toggle (Qt renders the overlay; ui/ABI.md §2.3).
    private var _fingerDotsShown = false
    var fingerDotsShown: Bool {
        get { lock.withLock { _fingerDotsShown } }
        set { lock.withLock { _fingerDotsShown = newValue } }
    }
    private var _deviceReachable: Bool?
    var deviceReachable: Bool? {
        get { lock.withLock { _deviceReachable } }
        set { lock.withLock { _deviceReachable = newValue } }
    }
    /// Whether the carrier panel is visible (drives its poll from the session poll).
    private var _carrierVisible = false
    var carrierVisible: Bool {
        get { lock.withLock { _carrierVisible } }
        set { lock.withLock { _carrierVisible = newValue } }
    }
    /// The last installed-apps read (lt_apps_refresh / snapshot builder).
    private var _cachedInstalledApps: [InstalledApp] = []
    var cachedInstalledApps: [InstalledApp] {
        get { lock.withLock { _cachedInstalledApps } }
        set { lock.withLock { _cachedInstalledApps = newValue } }
    }

    // MARK: - Init

    init(instance: DeviceInstance, profile: Board, firmwareVersion: String, directories: LTAppDirectories, helperURL: URL?) {
        self.instance = instance
        self.profile = profile
        self.firmwareVersion = firmwareVersion
        self.directories = directories
        self.helperURL = helperURL

        let settingsFile = DeviceSettingsFile(directory: instance.paths(
            state: directories.stateDir, logs: directories.logDir
        ).directory)
        self.settingsFile = settingsFile
        let notices = DeviceNotices(
            settings: settingsFile,
            shortName: profile.shortName
        ) { [weak self] in self?.storageFailed ?? false }
        self.notices = notices
        // The components below take the session as an unowned host; all
        // stored properties are initialized before any of them is created.
        self.readiness = ReadinessWatch(host: self, notices: notices)
        self.bootWatch = BootWatch(host: self)
        self.cycle = BootCycle(host: self)
        self.ladder = ShutdownLadder(host: self)
        self.eraser = DeviceErase(host: self)
        self.input = DeviceInput(host: self, settings: settingsFile)
        self.keyboard = KeyboardInput(
            settings: settingsFile,
            canToggleHardwareKeyboard: profile.canToggleHardwareKeyboard,
            control: { [weak self] request, done in self?.keyboardControl(request, done: done) },
            send: { [weak self] command in self?.link?.send(command) },
            canPress: { [weak self] in self.map { $0.acceptsInput && !$0.isSleeping } ?? false }
        )
        self.rotation = DeviceRotation(
            host: self,
            settings: settingsFile,
            setsAccelerometer: profile.orientationSource == .springBoard
        )
        let tweaks = DeviceTweaks(
            settings: settingsFile,
            version: firmwareVersion,
            guestTools: profile.hasGuestTools,
            clockPinned: false,
            guestRoot: directories.resourceDir
        )
        self.tweaks = tweaks
        let tweaksPanel = TweaksPanelModel(tweaks: tweaks, guest: nil)
        self.tweaksPanel = tweaksPanel
        self.carrierModem = CarrierModem(
            hasCellular: profile.hasCellular,
            settings: settingsFile,
            scope: bootScope
        ) { [weak self] in self?.link }
        self.carrierPanel = CarrierPanelModel(backend: self)
        self.apps = DeviceApps(host: self)
        self.options = DeviceOptions(
            settings: settingsFile,
            board: instance.board,
            link: { [weak self] in self?.link }
        )
        self.proxy = DeviceWebProxy(
            directory: { [weak self] in
                guard let self else { return URL(fileURLWithPath: "/tmp") }
                return WebProxyConfiguration.directory(for: instance)
            },
            shortName: profile.shortName
        )
        // The Tweaks panel's finger-dots get/set drives the window toggle
        // through the bridge (lt_display_set_finger_dots + event).
        tweaksPanel.fingerDots = (
            get: { [weak self] in self?.fingerDotsShown ?? false },
            set: { [weak self] in self?.setFingerDots($0) }
        )
    }

    /// Sets the finger-dots toggle: snapshot refresh + event for Qt.
    func setFingerDots(_ shown: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard _fingerDotsShown != shown else { return false }
            _fingerDotsShown = shown
            return true
        }
        guard changed else { return }
        Task { @MainActor in
            guard let core = AppCore.shared, let handle = core.handle(for: self.instance.id) else { return }
            if let data = ltEncodeJSON(FingerDotsDTO(shown: shown)) {
                SnapshotStore.shared.setDevice(handle, key: "fingerDots", json: data)
            }
            EventPump.shared.post(kind: kLTEventFingerDotsChanged, device: handle) { e in
                e.u.fingerDotsChanged.shown = shown ? 1 : 0
            }
        }
    }

    var paths: DeviceInstance.Paths {
        instance.paths(state: directories.stateDir, logs: directories.logDir)
    }

    var iosVersion: String { firmwareVersion }

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
    var canReachDevice: Bool { deviceReachable == true }
    var halting: Bool { ladder.halting }

    /// The one way `state` changes (VMState.transition(to:)).
    func transition(to next: VMState) {
        let (old, new) = lock.withLock { () -> (VMState, VMState) in
            let old = _state
            _state.transition(to: next)
            return (old, _state)
        }
        if new != old {
            let session = self
            Task { @MainActor in AppCore.shared?.sessionStateChanged(session) }
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
            debugPort: options?.debugPort ?? self.options.debugPortEnabled,
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
        fastLink = process.link
        lastFrameSerial = 0
        lastPolledFrameSerial = 0
        // Start usbmuxd on @MainActor (USBMux is @MainActor); the session is
        // cached for bootConfiguration and the AppsHost witness.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let session = self.usbmux.start(paths: self.paths)
            self.usbmuxSessionCached = session
            self.apps.host = self  // refresh usbmux session if DeviceApps was created earlier
        }
        process.onDeath = { [weak self, weak process] reason in
            guard let self, let process, self.process === process else { return }
            Task { @MainActor in self.helperDied(reason: reason) }
        }
        transition(to: .booting)
        notices.helperStarted()
        // The status poll runs from lt_pump_main_queue() (no Timer: Qt's event
        // loop doesn't run the main CFRunLoop on Linux).
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
        let usbSession = usbmuxSessionCached
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
        let session = self
        Task { @MainActor in AppCore.shared?.sessionBootEnded(session, end: end) }
    }

    func retireBoot() {
        guard !bootScope.retired else { return }
        bootScope.retire()
    }

    /// The helper is gone: the mirror ring and usbmuxd end with it.
    func releaseBootResources() {
        if let mirror = displayMirror {
            displayMirror = nil
            mirror.close()
            let session = self
            Task { @MainActor in AppCore.shared?.postDisplayLinkClosed(session) }
        }
        // USBMux is @MainActor; stop it there.
        Task { @MainActor [weak self] in
            self?.usbmux.stop()
            self?.usbmuxSessionCached = nil
        }
        process = nil
        fastLink = nil
        rotation.stopWatching()
    }

    // MARK: - Teardown

    /// Releases the session (lt_shutdown / device deleted).
    func release() {
        isReleased = true
        retireBoot()
        releaseBootResources()
        Task { @MainActor [weak self] in self?.recording.dismiss() }
    }
}
