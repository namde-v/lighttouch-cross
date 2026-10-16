/// Session lifecycle & status exports (ui/ABI.md §3.3).
import Foundation
import LTBridgeC
import LightTouchCore

/// Runs `body` on @MainActor with the session, returning kLTNoSuchDevice when
/// the handle is unknown. The session is created on demand (as the window
/// controller created it on open); the work itself is fire-and-forget
/// (commands enqueue and return), with failures posted as toasts.
func withSession(
    _ device: lt_device_t, what: String, _ body: @escaping @MainActor (AppCore, DeviceSession) -> Void
) -> LTResult {
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard let uuid = ltResolveDevice(device) else { return kLTNoSuchDevice }
    Task { @MainActor in
        guard let core = appCore() else { return }
        guard let session = core.session(for: uuid) else {
            postToast(
                title: "Couldn’t open the device",
                body: "The device record is missing.",
                category: "session"
            )
            return
        }
        body(core, session)
    }
    return kLTAccepted
}

// MARK: - Boot / halt / pause / reset / lock

/// lt_device_boot: BootCycle.begin() with BootSettings from optionsJson
/// {panel, network, debugPort, bootArgs}. Progress via kLTEventBootStage;
/// readiness via kLTEventDeviceStatusChanged.
@_cdecl("lt_device_boot")
public func lt_device_boot(
    _ device: lt_device_t, _ optionsJson: UnsafePointer<CChar>?
) -> LTResult {
    var options: LTBootOptions?
    if let optionsJson {
        guard let jsonStr = ltTakeString(optionsJson, what: "lt_device_boot: optionsJson") else {
            return kLTBadArgument
        }
        guard !jsonStr.isEmpty else {
            LTLastError.set("lt_device_boot: optionsJson is empty")
            return kLTBadArgument
        }
        guard let parsed = ltDecodeJSON(jsonStr, as: LTBootOptions.self) else {
            LTLastError.set("lt_device_boot: optionsJson must decode as {panel, network, debugPort, bootArgs}")
            return kLTBadArgument
        }
        options = parsed
    }
    let opts = options
    return withSession(device, what: "lt_device_boot") { _, session in
        session.boot(options: opts)
    }
}

/// lt_device_halt: ShutdownLadder graceful halt.
@_cdecl("lt_device_halt")
public func lt_device_halt(_ device: lt_device_t) -> LTResult {
    withSession(device, what: "lt_device_halt") { _, session in
        _ = session.ladder.halt()
    }
}

/// lt_device_pause: pause/resume the machine.
@_cdecl("lt_device_pause")
public func lt_device_pause(_ device: lt_device_t, _ paused: Int32) -> LTResult {
    withSession(device, what: "lt_device_pause") { _, session in
        if paused != 0 { session.pause() } else { session.resume() }
    }
}

/// lt_device_reset: BootCycle.reset() (in-place restart; resumes a paused
/// guest first).
@_cdecl("lt_device_reset")
public func lt_device_reset(_ device: lt_device_t) -> LTResult {
    withSession(device, what: "lt_device_reset") { _, session in
        session.cycle.reset()
    }
}

/// lt_device_lock: lock/wake. The Device-menu Lock item's three titles
/// (Lock/Wake/Start) are validated via lt_menu_validate; the command locks
/// (or wakes) the guest.
@_cdecl("lt_device_lock")
public func lt_device_lock(_ device: lt_device_t, _ locked: Int32) -> LTResult {
    withSession(device, what: "lt_device_lock") { _, session in
        session.setLocked(locked != 0)
    }
}

// MARK: - Queries

@_cdecl("lt_device_status")
public func lt_device_status(
    _ device: lt_device_t, _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    queryDeviceSnapshot(device, "status", what: "lt_device_status", out: out)
}

/// lt_menu_validate: DeviceMenuState.validate for one item. Pure-ish: reads
/// the status snapshot (no @MainActor hop).
@_cdecl("lt_menu_validate")
public func lt_menu_validate(
    _ device: lt_device_t, _ item: Int32, _ arg: Int32,
    _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    guard let out else {
        LTLastError.set("lt_menu_validate: null out")
        return kLTBadArgument
    }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard ltResolveDevice(device) != nil else { return kLTNoSuchDevice }
    guard let data = SnapshotStore.shared.device(device, key: "menuValidation") else {
        LTLastError.set("lt_menu_validate: snapshot not ready")
        return kLTNotReady
    }
    // The snapshot carries validations for every item; pick the requested one.
    struct Validations: Codable { var items: [String: LTMenuValidationDTO] }
    guard let validations = try? JSONDecoder().decode(Validations.self, from: data),
          let validation = validations.items[String(item)]
    else {
        LTLastError.set("lt_menu_validate: unknown item \(item)")
        return kLTBadArgument
    }
    _ = arg // arg is the compass heading; folded into the snapshot's validation
    guard let outData = ltEncodeJSON(validation) else {
        LTLastError.set("lt_menu_validate: encoding failed")
        return kLTFailed
    }
    out.pointee = ltCopyCString(outData).map { UnsafePointer($0) }
    return out.pointee == nil ? kLTFailed : kLTOk
}

@_cdecl("lt_capture_availability")
public func lt_capture_availability(
    _ device: lt_device_t, _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    queryDeviceSnapshot(device, "captureAvailability", what: "lt_capture_availability", out: out)
}

// MARK: - Notices

@_cdecl("lt_notice_get")
public func lt_notice_get(
    _ device: lt_device_t, _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    queryDeviceSnapshot(device, "notice", what: "lt_notice_get", out: out)
}

@_cdecl("lt_notice_resolve")
public func lt_notice_resolve(
    _ device: lt_device_t, _ operation: UnsafePointer<CChar>?
) -> LTResult {
    guard let opStr = ltTakeString(operation, what: "lt_notice_resolve: operation") else { return kLTBadArgument }
    guard let operation = DeviceNotices.Operation(rawValue: opStr) else {
        LTLastError.set("lt_notice_resolve: unknown operation “\(opStr)”")
        return kLTBadArgument
    }
    return withSession(device, what: "lt_notice_resolve") { _, session in
        session.notices.resolve(operation)
    }
}

@_cdecl("lt_notice_dismiss")
public func lt_notice_dismiss(_ device: lt_device_t) -> LTResult {
    withSession(device, what: "lt_notice_dismiss") { _, session in
        session.notices.dismiss()
    }
}

// MARK: - Network access

/// lt_network_status: LocalNetworkAccess state JSON.
@_cdecl("lt_network_status")
public func lt_network_status(_ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> LTResult {
    querySnapshot("networkStatus", what: "lt_network_status", out: out)
}

/// lt_network_set_allowed: records the NetworkAccessPrompt answer.
@_cdecl("lt_network_set_allowed")
public func lt_network_set_allowed(_ allowed: Int32) -> LTResult {
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    let answer = allowed != 0
    Task { @MainActor in
        guard let core = appCore() else { return }
        core.prefs.set(answer, forKey: NetworkAccessPreference.key)
        core.refreshNetworkStatusSnapshot()
        EventPump.shared.post(kind: kLTEventNetworkAccessChanged)
    }
    return kLTAccepted
}
