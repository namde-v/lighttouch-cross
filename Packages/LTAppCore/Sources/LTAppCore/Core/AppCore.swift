import LTBridgeC
/// The portable app-core orchestrator (ui/ABI.md §6 gap 1).
///
/// Mirrors what `upstream/LightTouchMac` composed in its app target (app
/// delegate + window controllers around `EmulatorController`): one @MainActor
/// owner for the `DeviceLibrary`, the `FirmwareJobs`, the `FirmwareCatalog`,
/// the `SidebarList`, the settings stores, the `lt_device_t` handle registry,
/// one `DeviceSession` per device, the lock-protected snapshot caches (§4.2),
/// and the `LTEvent` fan-out feeding the C callback.
///
/// Nonisolated entry points (`lt_` commands/queries) reach the core through
/// the lock-guarded `appCore()` global; commands hop onto @MainActor with
/// `Task { @MainActor in }` and queries read `SnapshotStore`.
import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import LightTouchCore

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

// MARK: - Directories and config

/// The directories the Qt side owns (lt_init's configJson; no Bundle.main).
/// `stateDir` is derived from `appSupportDir` via `StorageLocations.stateRoot`
/// (exactly as the Mac app did); the derivation runs on @MainActor in
/// `AppCore.startup`.
struct LTAppDirectories {
    var stateDir: URL
    var logDir: URL
    var resourceDir: URL
    /// Where the emulator's files (bootroms etc.) live: resourceDir/files.
    var filesRoot: String { resourceDir.appendingPathComponent("files").path }
    /// The LightTouchDevice helper executable, when the install ships it.
    var helperURL: URL? {
        let url = resourceDir.appendingPathComponent("LightTouchDevice")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}

struct LTInitConfig: Decodable {
    var appSupportDir: String
    var logDir: String
    var resourceDir: String
}

// MARK: - Globals (nonisolated, lock-guarded)

private let gCoreLock = NSLock()
nonisolated(unsafe) private var gCore: AppCore?
nonisolated(unsafe) private var gPrefs: LTFileDefaults?
nonisolated(unsafe) private var gInitialized = false
nonisolated(unsafe) private var gShutDown = false

/// The core, when lt_init's @MainActor phase finished. Nonisolated so
/// commands and queries can reach it; all its state is @MainActor-isolated.
func appCore() -> AppCore? {
    gCoreLock.withLock { gCore }
}

func setAppCore(_ core: AppCore?) {
    gCoreLock.withLock { gCore = core }
}

/// The file-backed defaults (ui/ABI.md §6 gap 5). Set by lt_init.
func ltPrefs() -> LTFileDefaults? {
    gCoreLock.withLock { gPrefs }
}

func setPrefs(_ prefs: LTFileDefaults?) {
    gCoreLock.withLock { gPrefs = prefs }
}

func ltIsInitialized() -> Bool {
    gCoreLock.withLock { gInitialized }
}

func ltMarkInitialized() {
    gCoreLock.withLock { gInitialized = true }
}

func ltIsShutDown() -> Bool {
    gCoreLock.withLock { gShutDown }
}

func ltMarkShutDown() {
    gCoreLock.withLock { gShutDown = true }
}

// MARK: - AppCore

/// The @MainActor composition root. Constructed on @MainActor during lt_init.
@MainActor
final class AppCore {
    /// Direct access from @MainActor contexts (sessions, tasks). nonisolated(unsafe)
    /// so the input fast path can resolve the core without a @MainActor hop;
    /// written once during lt_init and cleared during lt_shutdown.
    nonisolated(unsafe) static var shared: AppCore?

    /// Immutable after @MainActor init; nonisolated(unsafe) so synchronous
    /// queries (log sources, help lookup) can read paths off-actor.
    nonisolated(unsafe) let directories: LTAppDirectories
    let prefs: LTFileDefaults
    let library: DeviceLibrary
    let catalog: FirmwareCatalog
    let jobs: FirmwareJobs
    let storageWork = DeviceStorageWork()
    var sidebar: SidebarList
    /// One live session per library device, created lazily. Guarded by
    /// sessionsLock; nonisolated(unsafe) so the input fast path can resolve a
    /// session without a @MainActor hop — off-actor the session is only ever
    /// touched through its thread-safe injection entry points.
    private let sessionsLock = NSLock()
    nonisolated(unsafe) var sessions: [Foundation.UUID: DeviceSession] = [:]

    /// All sessions (a copy, for @MainActor iteration). Lock-guarded, so
    /// nonisolated: log-source enumeration reads it off-actor.
    nonisolated func allSessions() -> [DeviceSession] {
        sessionsLock.withLock { Array(sessions.values) }
    }

    /// Nonisolated session lookup for the input fast path (ui/ABI.md §4).
    nonisolated func fastSession(for uuid: Foundation.UUID) -> DeviceSession? {
        sessionsLock.withLock { sessions[uuid] }
    }

    private var observers: [NSObjectProtocol] = []
    var logFollow: LogFollow?

    private init(
        directories: LTAppDirectories,
        prefs: LTFileDefaults,
        library: DeviceLibrary,
        catalog: FirmwareCatalog,
        jobs: FirmwareJobs,
        sidebar: SidebarList
    ) {
        self.directories = directories
        self.prefs = prefs
        self.library = library
        self.catalog = catalog
        self.jobs = jobs
        self.sidebar = sidebar
    }

    // MARK: - Startup

    /// Builds the core on @MainActor: storage layout, library/catalog/jobs,
    /// handle minting, initial snapshots, change observation.
    static func startup(config: LTInitConfig, prefs: LTFileDefaults) async throws -> AppCore {
        let appSupportDir = URL(fileURLWithPath: config.appSupportDir, isDirectory: true)
        let logDir = URL(fileURLWithPath: config.logDir, isDirectory: true)
        let resourceDir = URL(fileURLWithPath: config.resourceDir, isDirectory: true)
        // Storage layout (StorageLocations.prepare): the state dir is derived
        // from appSupportDir exactly as the Mac app derived it.
        _ = try StorageLocations.prepare(applicationSupport: appSupportDir, library: appSupportDir)
        let stateDir = StorageLocations.stateRoot(applicationSupport: appSupportDir)
        // LTM_STATE_DIR is the port's designed override (Bundled.layout): the
        // app log and friends resolve into the Qt-owned state dir. Set before
        // any core code reads Bundled (the first logEvent below).
        // setenv is POSIX-only; on Windows the CRT _putenv_s is the equivalent
        // (precedent: FirmwareKit FitCheckTests setenv shim).
        #if os(Windows)
        stateDir.path.withCString { ptr in _ = _putenv_s("LTM_STATE_DIR", ptr) }
        #else
        stateDir.path.withCString { ptr in _ = setenv("LTM_STATE_DIR", ptr, 1) }
        #endif
        let directories = LTAppDirectories(
            stateDir: stateDir,
            logDir: logDir,
            resourceDir: resourceDir
        )

        let library = DeviceLibrary(state: directories.stateDir)
        let catalog = AppCore.loadCatalog(resourceDir: directories.resourceDir)
        let jobs = FirmwareJobs(
            catalog: catalog,
            state: directories.stateDir,
            logs: directories.logDir,
            resources: directories.resourceDir,
            library: library,
            sweep: false,
            defaults: prefs,
            presentError: { logEvent("firmware job: \($0)") }
        )
        let sidebar = SidebarList.load(prefs, catalog: catalog) { entry in
            library.instances(firmware: entry.id).isEmpty == false
                || jobs.jobs[entry.id] != nil
        }
        let core = AppCore(
            directories: directories,
            prefs: prefs,
            library: library,
            catalog: catalog,
            jobs: jobs,
            sidebar: sidebar
        )
        core.mintHandles()
        core.startObservers()
        core.refreshAllSnapshots()
        core.logFollow = LogFollow(core: core)
        Self.shared = core
        setAppCore(core)
        return core
    }

    private static func loadCatalog(resourceDir: URL) -> FirmwareCatalog {
        let url = resourceDir.appendingPathComponent("firmware-catalog.json")
        if let catalog = try? FirmwareCatalog.load(from: url) { return catalog }
        // No catalog shipped (or not yet): the firmware surfaces are empty but
        // the core is usable. The UI is told through empty query results.
        logEvent("catalog: no firmware-catalog.json in \(resourceDir.path); starting with an empty catalog")
        let empty = #"{"format":1,"entries":[]}"#
        return (try? JSONDecoder().decode(FirmwareCatalog.self, from: Data(empty.utf8)))!
    }

    // MARK: - Handles and sessions

    private func mintHandles() {
        for instance in library.instances {
            HandleRegistry.shared.register(instance.id)
        }
    }

    /// The handle for a library device, or nil when unknown. Nonisolated: the
    /// handle registry is thread-safe; background witnesses resolve handles.
    nonisolated func handle(for uuid: Foundation.UUID) -> lt_device_t? {
        HandleRegistry.shared.handle(for: uuid)
    }

    /// The session for a device, creating it on first use.
    func session(for uuid: Foundation.UUID) -> DeviceSession? {
        if let existing = sessionsLock.withLock({ sessions[uuid] }) { return existing }
        guard let instance = library.instance(id: uuid),
            let profile = instance.profile
        else { return nil }
        let session = DeviceSession.create(
            instance: instance,
            profile: profile,
            firmwareVersion: catalog.entry(id: instance.firmware)?.version ?? "",
            directories: directories,
            helperURL: directories.helperURL
        )
        sessionsLock.withLock { sessions[uuid] = session }
        return session
    }

    /// Drops a session (device deleted). The session releases its resources.
    func dropSession(for uuid: Foundation.UUID) {
        sessionsLock.withLock {
            sessions[uuid]?.release()
            sessions.removeValue(forKey: uuid)
        }
    }

    // MARK: - Change observation → snapshots + events

    private func startObservers() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: DeviceLibrary.didChangeNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.libraryChanged() }
            },
            center.addObserver(forName: FirmwareJobs.didChangeNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.jobsChanged() }
            },
            center.addObserver(forName: FirmwareJobs.didPublishNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.jobsChanged() }
            },
        ]
        storageWork.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.storageWorkChanged() }
        }
    }

    private func libraryChanged() {
        // Register handles for newcomers; drop handles/sessions for the gone.
        let ids = Set(library.instances.map(\.id))
        for instance in library.instances { HandleRegistry.shared.register(instance.id) }
        for uuid in sessionsLock.withLock({ Array(sessions.keys) }) where !ids.contains(uuid) {
            dropSession(for: uuid)
            if let handle = HandleRegistry.shared.handle(for: uuid) {
                SnapshotStore.shared.removeDevice(handle)
            }
            HandleRegistry.shared.unregister(uuid)
        }
        refreshLibrarySnapshots()
        EventPump.shared.postDeviceListChanged()
    }

    private func jobsChanged() {
        refreshJobsSnapshots()
        refreshLibrarySnapshots() // rows carry job state
        EventPump.shared.postDeviceListChanged()
    }

    private func storageWorkChanged() {
        refreshLibrarySnapshots()
        EventPump.shared.post(kind: kLTEventStorageBusyChanged)
    }

    // MARK: - Session-initiated updates

    /// A session's VM state moved: refresh its snapshots, post the event.
    func sessionStateChanged(_ session: DeviceSession) {
        refreshDeviceSnapshots(session)
        guard let handle = handle(for: session.instance.id) else { return }
        let s = session
        EventPump.shared.post(kind: kLTEventDeviceStatusChanged, device: handle) { e in
            e.u.deviceStatusChanged.machine = Int32(ltVMState(s.state))
            e.u.deviceStatusChanged.running = s.isRunning ? 1 : 0
            e.u.deviceStatusChanged.sleeping = s.isSleeping ? 1 : 0
        }
        EventPump.shared.post(kind: kLTEventCaptureAvailabilityChanged, device: handle)
    }

    func sessionBootEnded(_ session: DeviceSession, end: BootEnd) {
        _ = end
        refreshDeviceSnapshots(session)
    }

    func postDisplayLinkReady(_ session: DeviceSession, mirror: QtFrameMirror) {
        guard let handle = handle(for: session.instance.id) else { return }
        let fd = mirror.fd
        let w = Int32(mirror.width), h = Int32(mirror.height), stride = Int32(mirror.stride)
        let generation = mirror.generation
        EventPump.shared.post(kind: kLTEventDisplayLinkReady, device: handle) { e in
            e.u.displayLinkReady.fd = fd
            e.u.displayLinkReady.width = w
            e.u.displayLinkReady.height = h
            e.u.displayLinkReady.stride = stride
            e.u.displayLinkReady.format = kLTPixelFormatBGRA32
            e.u.displayLinkReady.ringGeneration = generation
        }
    }

    func postDisplayLinkClosed(_ session: DeviceSession) {
        guard let handle = handle(for: session.instance.id) else { return }
        EventPump.shared.post(kind: kLTEventDisplayLinkClosed, device: handle)
    }

    /// One poll step for every live session (from lt_pump_main_queue).
    func pollSessions() {
        for session in allSessions() { session.poll() }
    }

    // MARK: - Snapshots

    /// Refreshes every snapshot (startup, and after cross-cutting changes).
    func refreshAllSnapshots() {
        refreshLibrarySnapshots()
        refreshJobsSnapshots()
        refreshCatalogSnapshot()
        refreshAboutSnapshot()
        refreshNetworkStatusSnapshot()
        for session in allSessions() { refreshDeviceSnapshots(session) }
    }

    /// The lt_about_credits payload. AboutCredits' statics are @MainActor-
    /// isolated, so this builds on @MainActor at startup; the query then reads
    /// the lock-protected snapshot like any other.
    func refreshAboutSnapshot() {
        struct Credit: Codable {
            var name: String
            var site: String
            var license: String
        }
        struct About: Codable {
            var version: String
            var credits: [Credit]
        }
        let about = About(
            version: LTAppVersion,
            credits: AboutCredits.projects.map {
                Credit(name: $0.name, site: $0.site.absoluteString, license: $0.license)
            }
        )
        if let data = ltEncodeJSON(about) {
            SnapshotStore.shared.setGlobal("about", json: data)
        }
    }

    /// Refreshes one device's snapshots (status, notice, capture availability…).
    /// Per-domain builders live in AppCore+Snapshots.swift.
    func refreshDeviceSnapshots(_ session: DeviceSession) {
        guard let handle = handle(for: session.instance.id) else { return }
        refreshStatusSnapshot(session: session, handle: handle)
        refreshNoticeSnapshot(session: session, handle: handle)
        refreshCaptureAvailabilitySnapshot(session: session, handle: handle)
        refreshTweaksSnapshot(session: session, handle: handle)
        refreshCarrierSnapshot(session: session, handle: handle)
        refreshAppsSnapshot(session: session, handle: handle)
        refreshZoomSnapshot(session: session, handle: handle)
        refreshStorageSnapshot(session: session, handle: handle)
        refreshProxySnapshot(session: session, handle: handle)
        refreshDebugPortSnapshot(session: session, handle: handle)
    }

    // MARK: - Shutdown

    /// Graceful teardown: stops sessions, releases everything, posts Shutdown.
    /// After this returns, the core is gone; only lt_init is legal again.
    func shutdown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        logFollow = nil
        for session in allSessions() { session.release() }
        sessionsLock.withLock { sessions = [:] }
        SnapshotStore.shared.resetForTests()
        HandleRegistry.shared.resetForTests()
        EventPump.shared.post(kind: kLTEventShutdown)
        Self.shared = nil
        setAppCore(nil)
        setPrefs(nil)
        ltMarkShutDown()
    }
}

/// Maps VMState to the kLTVMState* constants.
func ltVMState(_ state: VMState) -> Int32 {
    switch state {
    case .notStarted: return kLTVMStateNotStarted
    case .booting: return kLTVMStateBooting
    case .running: return kLTVMStateRunning
    case .paused: return kLTVMStatePaused
    case .poweredOff: return kLTVMStatePoweredOff
    case .dead: return kLTVMStateDead
    }
}
