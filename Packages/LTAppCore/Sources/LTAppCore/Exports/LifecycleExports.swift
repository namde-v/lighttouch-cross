/// Lifecycle exports (ui/ABI.md §3.1).
///
/// Commands validate, enqueue onto @MainActor and return within microseconds;
/// queries read lock-protected snapshots; pure functions are lock-free.
import Foundation
import LTBridgeC
import LightTouchCore

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

/// The app version lt_version() reports (About panel).
let LTAppVersion = "1.0.0"

/// The ABI version lt_abi_version() reports (ui/ABI.md §5). Starts at 1;
/// additive-only evolution keeps it there.
let LTABIVersion: Int32 = 1

// MARK: - lt_init / lt_shutdown

/// Initializes the app controller. Runs once, on the Qt UI (main) thread:
/// validates the config, prepares storage, creates the file-backed defaults,
/// then builds the @MainActor core, pumping the main runloop until it is
/// usable (or a 30 s timeout). Returns kLTOk when the core is usable.
@_cdecl("lt_init")
public func lt_init(_ configJson: UnsafePointer<CChar>?) -> LTResult {
    guard let jsonStr = ltTakeString(configJson, what: "lt_init: configJson") else { return kLTBadArgument }
    guard let config = ltDecodeJSON(jsonStr, as: LTInitConfig.self) else {
        LTLastError.set("lt_init: configJson must be {\"appSupportDir\":…, \"logDir\":…, \"resourceDir\":…}")
        return kLTBadArgument
    }
    for (key, value) in [
        ("appSupportDir", config.appSupportDir), ("logDir", config.logDir),
        ("resourceDir", config.resourceDir),
    ] where value.isEmpty {
        LTLastError.set("lt_init: \(key) is empty")
        return kLTBadArgument
    }
    if ltIsInitialized() {
        LTLastError.set("lt_init: already initialized")
        return kLTFailed
    }
    if ltIsShutDown() {
        LTLastError.set("lt_init: the core was shut down; restart the process")
        return kLTFailed
    }

    // The file-backed defaults (gap 5) live beside the state dir.
    let appSupportDir = URL(fileURLWithPath: config.appSupportDir, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    } catch {
        LTLastError.set("lt_init: can’t create appSupportDir: \(error.localizedDescription)")
        return kLTFailed
    }
    let prefs = LTFileDefaults(
        fileURL: appSupportDir.appendingPathComponent("ltappcore-preferences.json")
    )
    setPrefs(prefs)

    // Build the @MainActor core, pumping the main runloop until it finishes.
    // This must run on the main thread: only there does the pump drain the
    // @MainActor executor (a background thread times out with a clear error).
    final class StartupBox: @unchecked Sendable {
        var core: AppCore?
        var error: Error?
    }
    let box = StartupBox()
    Task { @MainActor in
        do {
            box.core = try await AppCore.startup(config: config, prefs: prefs)
        } catch {
            box.error = error
        }
    }
    let deadline = Date().addingTimeInterval(30)
    while box.core == nil, box.error == nil, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    if let error = box.error {
        setPrefs(nil)
        LTLastError.set("lt_init: \(error.localizedDescription)")
        return kLTFailed
    }
    guard box.core != nil else {
        setPrefs(nil)
        LTLastError.set(
            "lt_init: timed out building the core — call lt_init on the main/UI thread and pump the main runloop"
        )
        return kLTFailed
    }
    ltMarkInitialized()
    logEvent("ltappcore: initialized (ABI v\(LTABIVersion))")
    return kLTOk
}

/// Graceful teardown: stops jobs, halts sessions, closes helper links, then
/// posts kLTEventShutdown. Pumps the main runloop (up to 15 s) so the teardown
/// actually completes before returning; after it returns only lt_init (fresh
/// process state) is legal.
@_cdecl("lt_shutdown")
public func lt_shutdown() -> LTResult {
    guard ltIsInitialized() else {
        LTLastError.set("lt_shutdown: not initialized")
        return kLTNotReady
    }
    if ltIsShutDown() { return kLTOk }
    let done = LTBox<Bool>(false)
    Task { @MainActor in
        appCore()?.shutdown()
        done.value = true
    }
    let deadline = Date().addingTimeInterval(15)
    while done.value != true, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard done.value == true else {
        LTLastError.set("lt_shutdown: timed out waiting for teardown")
        return kLTFailed
    }
    return kLTOk
}

/// A tiny lock-guarded Sendable box for MainActor completion flags.
final class LTBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    init(_ value: T? = nil) { self._value = value }
}

// MARK: - Events, version, strings

@_cdecl("lt_set_event_callback")
public func lt_set_event_callback(_ fn: lt_event_fn?, _ ctx: UnsafeMutableRawPointer?) -> LTResult {
    // Registration is allowed before lt_init completes: events are dropped
    // (counted) until the core posts them; the callback itself is process-wide.
    EventPump.shared.setCallback(fn, ctx)
    return kLTAccepted
}

@_cdecl("lt_abi_version")
public func lt_abi_version() -> Int32 { LTABIVersion }

@_cdecl("lt_version")
public func lt_version(_ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> LTResult {
    guard let out else {
        LTLastError.set("lt_version: null out")
        return kLTBadArgument
    }
    guard ltIsInitialized() else { return kLTNotReady }
    out.pointee = ltCopyCString(LTAppVersion).map { UnsafePointer($0) }
    return out.pointee == nil ? kLTFailed : kLTOk
}

/// The one legal deallocator for every returned string (ui/ABI.md §1.3).
/// NULL-safe.
@_cdecl("lt_free_string")
public func lt_free_string(_ s: UnsafePointer<CChar>?) {
    guard let s else { return }
    free(UnsafeMutableRawPointer(mutating: s))
    LTStringStats.recordFree()
}

/// Deep-frees an event's string payloads (ui/ABI.md §1.3). The trampoline
/// calls this on the original after deep-copying.
@_cdecl("lt_free_event_strings")
public func lt_free_event_strings(_ e: UnsafePointer<LTEvent>?) {
    guard let e else { return }
    var event = e.pointee
    ltFreeEventStrings(&event)
}

// MARK: - Quit

/// Begins graceful shutdown (QuitCoordinator semantics, Qt-owned dialogs):
/// a recording or storage work in flight blocks with a toast; otherwise every
/// running device halts at once and kLTEventQuitReady posts when the last one
/// stops (or the budget lapses).
@_cdecl("lt_quit_request")
public func lt_quit_request() -> LTResult {
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    Task { @MainActor in
        guard let core = appCore() else { return }
        if core.storageWork.isErasing {
            postToast(title: "Can’t quit yet", body: "A device is being erased.", category: "quit")
            return
        }
        let recording = core.allSessions().first { $0.recording.isActive }
        if recording != nil {
            postToast(
                title: "Can’t quit yet",
                body: "A screen recording is in progress. Stop it first.",
                category: "quit"
            )
            return
        }
        let halts = core.allSessions().filter { $0.isRunning || $0.state == .booting }
        guard !halts.isEmpty else {
            EventPump.shared.post(kind: kLTEventQuitReady)
            return
        }
        var remaining = halts.count
        let budget = Task {
            try? await Task.sleep(for: .seconds(30))
            MainActor.assumeIsolated {
                if remaining > 0 {
                    remaining = 0
                    EventPump.shared.post(kind: kLTEventQuitReady)
                }
            }
        }
        for session in halts {
            Task {
                _ = await session.ladder.halt().value
                MainActor.assumeIsolated {
                    remaining -= 1
                    if remaining == 0 {
                        budget.cancel()
                        EventPump.shared.post(kind: kLTEventQuitReady)
                    }
                }
            }
        }
    }
    return kLTAccepted
}

// MARK: - About

/// JSON { "version":…, "credits": […] } from AboutCredits (built at startup).
@_cdecl("lt_about_credits")
public func lt_about_credits(_ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> LTResult {
    querySnapshot("about", what: "lt_about_credits", out: out)
}

// MARK: - Toast helper (cross-cutting, ui/ABI.md §2.3)

/// Posts a kLTEventToast (LTMNotifier / CaptureNotifications path, §6 gap 7:
/// the notification backend is the Qt-side toast via this event).
func postToast(title: String, body: String, category: String) {
    EventPump.shared.post(kind: kLTEventToast) { e in
        e.u.toast.title = ltCopyCString(title)
        e.u.toast.body = ltCopyCString(body)
        e.u.toast.category = ltCopyCString(category)
    }
}

/// The additive main-queue pump (see lt_bridge.h): drains Swift's @MainActor
/// executor on the calling thread for up to `budgetMs`, and runs one session
/// poll step. The Qt side calls this on a timer; only the main thread drains.
@_cdecl("lt_pump_main_queue")
public func lt_pump_main_queue(_ budgetMs: Double) {
    let budget = max(0, budgetMs) / 1000
    let deadline = Date().addingTimeInterval(budget)
    Task { @MainActor in
        appCore()?.pollSessions()
        appCore()?.logFollow?.poll()
    }
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}
