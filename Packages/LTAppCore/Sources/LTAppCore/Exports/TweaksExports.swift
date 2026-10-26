/// Tweaks, carrier, storage, proxy & debug-port exports (ui/ABI.md §3.5).
import FirmwareSchema
import Foundation
import LTBridgeC
import LightTouchCore
import HostRuntime

// MARK: - Tweaks

@_cdecl("lt_tweaks_get")
public func lt_tweaks_get(
    _ device: lt_device_t, _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    queryDeviceSnapshot(device, "tweaks", what: "lt_tweaks_get", out: out)
}

@_cdecl("lt_tweaks_set")
public func lt_tweaks_set(
    _ device: lt_device_t, _ tweakId: UnsafePointer<CChar>?, _ on: Int32
) -> LTResult {
    guard let idStr = ltTakeString(tweakId, what: "lt_tweaks_set: tweakId") else { return kLTBadArgument }
    guard let tweak = Tweak(rawValue: idStr) else {
        LTLastError.set("lt_tweaks_set: unknown tweak “\(idStr)”")
        return kLTBadArgument
    }
    return withSession(device, what: "lt_tweaks_set") { core, session in
        session.tweaksPanel.set(tweak, on: on != 0)
        guard let handle = core.handle(for: session.instance.id) else { return }
        core.refreshTweaksSnapshot(session: session, handle: handle)
        EventPump.shared.post(kind: kLTEventTweaksChanged, device: handle)
    }
}

@_cdecl("lt_tweaks_set_color")
public func lt_tweaks_set_color(_ device: lt_device_t, _ color: Int32) -> LTResult {
    guard color >= 0, let coreAnimationColor = CoreAnimationColor(rawValue: UInt32(color)) else {
        LTLastError.set("lt_tweaks_set_color: unknown color \(color)")
        return kLTBadArgument
    }
    return withSession(device, what: "lt_tweaks_set_color") { core, session in
        session.tweaksPanel.set(coreAnimationColor: coreAnimationColor)
        guard let handle = core.handle(for: session.instance.id) else { return }
        core.refreshTweaksSnapshot(session: session, handle: handle)
        EventPump.shared.post(kind: kLTEventTweaksChanged, device: handle)
    }
}

@_cdecl("lt_tweaks_set_clock")
public func lt_tweaks_set_clock(_ device: lt_device_t, _ epoch: Double) -> LTResult {
    guard epoch.isFinite, epoch > 0 else {
        LTLastError.set("lt_tweaks_set_clock: epoch must be a positive finite timestamp")
        return kLTBadArgument
    }
    let date = Date(timeIntervalSince1970: epoch)
    return withSession(device, what: "lt_tweaks_set_clock") { core, session in
        session.tweaksPanel.set(clock: date)
        guard let handle = core.handle(for: session.instance.id) else { return }
        core.refreshTweaksSnapshot(session: session, handle: handle)
        EventPump.shared.post(kind: kLTEventTweaksChanged, device: handle)
    }
}

@_cdecl("lt_tweaks_list_hidden_apps")
public func lt_tweaks_list_hidden_apps(_ device: lt_device_t) -> LTResult {
    withSession(device, what: "lt_tweaks_list_hidden_apps") { _, session in
        Task {
            await session.tweaksPanel.listHiddenApps()
            let session = session
            await MainActor.run {
                guard let core = appCore(), let handle = core.handle(for: session.instance.id) else { return }
                core.refreshTweaksSnapshot(session: session, handle: handle)
                EventPump.shared.post(kind: kLTEventHiddenAppsListed, device: handle)
            }
        }
    }
}

@_cdecl("lt_tweaks_open_app")
public func lt_tweaks_open_app(
    _ device: lt_device_t, _ bundleId: UnsafePointer<CChar>?
) -> LTResult {
    guard let bundleIdStr = ltTakeString(bundleId, what: "lt_tweaks_open_app: bundleId") else { return kLTBadArgument }
    guard !bundleIdStr.isEmpty else {
        LTLastError.set("lt_tweaks_open_app: empty bundleId")
        return kLTBadArgument
    }
    return withSession(device, what: "lt_tweaks_open_app") { core, session in
        Task {
            let app = HiddenApp.candidates.first { $0.bundleID == bundleIdStr }
                ?? HiddenApp(name: bundleIdStr, bundleID: bundleIdStr, bundle: bundleIdStr)
            await session.tweaksPanel.open(app)
            let session = session
            await MainActor.run {
                guard let core = appCore(), let handle = core.handle(for: session.instance.id) else { return }
                core.refreshTweaksSnapshot(session: session, handle: handle)
                // Failures surface via kLTEventTweaksChanged (message).
                EventPump.shared.post(kind: kLTEventTweaksChanged, device: handle)
            }
        }
    }
}

// MARK: - Carrier

@_cdecl("lt_carrier_set_visible")
public func lt_carrier_set_visible(_ device: lt_device_t, _ visible: Int32) -> LTResult {
    withSession(device, what: "lt_carrier_set_visible") { _, session in
        session.carrierVisible = visible != 0
        if visible != 0 {
            session.carrierPanel.poll()
        }
    }
}

@_cdecl("lt_carrier_get")
public func lt_carrier_get(
    _ device: lt_device_t, _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    queryDeviceSnapshot(device, "carrier", what: "lt_carrier_get", out: out)
}

/// lt_carrier_set_field: typed-but-unapplied edits (validation stays in the model).
@_cdecl("lt_carrier_set_field")
public func lt_carrier_set_field(
    _ device: lt_device_t, _ field: UnsafePointer<CChar>?, _ value: UnsafePointer<CChar>?
) -> LTResult {
    guard let fieldStr = ltTakeString(field, what: "lt_carrier_set_field: field") else { return kLTBadArgument }
    guard let valueStr = ltTakeString(value, what: "lt_carrier_set_field: value") else { return kLTBadArgument }
    return withSession(device, what: "lt_carrier_set_field") { core, session in
        let panel = session.carrierPanel
        switch fieldStr {
        case "carrierName": panel.carrierName = valueStr
        case "mcc": panel.mcc = valueStr
        case "mnc": panel.mnc = valueStr
        case "callNumber": panel.callNumber = valueStr
        case "smsNumber": panel.smsNumber = valueStr
        case "smsText": panel.smsText = valueStr
        case "latitude": panel.latitude = valueStr
        case "longitude": panel.longitude = valueStr
        default:
            LTLastError.set("lt_carrier_set_field: unknown field “\(fieldStr)”")
            return
        }
        guard let handle = core.handle(for: session.instance.id) else { return }
        core.refreshCarrierSnapshot(session: session, handle: handle)
    }
}

@_cdecl("lt_carrier_apply_network")
public func lt_carrier_apply_network(_ device: lt_device_t) -> LTResult {
    withSession(device, what: "lt_carrier_apply_network") { core, session in
        session.carrierPanel.applyNetwork()
        guard let handle = core.handle(for: session.instance.id) else { return }
        core.refreshCarrierSnapshot(session: session, handle: handle)
        EventPump.shared.post(kind: kLTEventCarrierChanged, device: handle)
    }
}

@_cdecl("lt_carrier_set_registered")
public func lt_carrier_set_registered(_ device: lt_device_t, _ registered: Int32) -> LTResult {
    withSession(device, what: "lt_carrier_set_registered") { _, session in
        session.carrierPanel.set(registered: registered != 0)
    }
}

@_cdecl("lt_carrier_set_sim")
public func lt_carrier_set_sim(_ device: lt_device_t, _ present: Int32) -> LTResult {
    withSession(device, what: "lt_carrier_set_sim") { _, session in
        session.carrierPanel.set(simPresent: present != 0)
    }
}

@_cdecl("lt_carrier_set_bars")
public func lt_carrier_set_bars(_ device: lt_device_t, _ bars: Int32) -> LTResult {
    withSession(device, what: "lt_carrier_set_bars") { _, session in
        session.carrierPanel.set(bars: Int(bars))
    }
}

@_cdecl("lt_carrier_ring")
public func lt_carrier_ring(_ device: lt_device_t) -> LTResult {
    withSession(device, what: "lt_carrier_ring") { _, session in
        session.carrierPanel.ring()
    }
}

@_cdecl("lt_carrier_answer")
public func lt_carrier_answer(_ device: lt_device_t) -> LTResult {
    withSession(device, what: "lt_carrier_answer") { _, session in
        session.carrierPanel.answer()
    }
}

@_cdecl("lt_carrier_hangup")
public func lt_carrier_hangup(_ device: lt_device_t) -> LTResult {
    withSession(device, what: "lt_carrier_hangup") { _, session in
        session.carrierPanel.hangUp()
    }
}

@_cdecl("lt_carrier_send_sms")
public func lt_carrier_send_sms(_ device: lt_device_t) -> LTResult {
    withSession(device, what: "lt_carrier_send_sms") { _, session in
        session.carrierPanel.sendSMS()
    }
}

@_cdecl("lt_carrier_apply_location")
public func lt_carrier_apply_location(_ device: lt_device_t) -> LTResult {
    withSession(device, what: "lt_carrier_apply_location") { _, session in
        session.carrierPanel.applyLocation()
    }
}

@_cdecl("lt_carrier_set_location")
public func lt_carrier_set_location(
    _ device: lt_device_t, _ lat: Double, _ lon: Double
) -> LTResult {
    guard lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else {
        LTLastError.set("lt_carrier_set_location: coordinates out of range")
        return kLTBadArgument
    }
    return withSession(device, what: "lt_carrier_set_location") { _, session in
        session.carrierPanel.set(location: GPSLocation(latitude: lat, longitude: lon))
    }
}

@_cdecl("lt_carrier_toggle_walk")
public func lt_carrier_toggle_walk(_ device: lt_device_t) -> LTResult {
    withSession(device, what: "lt_carrier_toggle_walk") { _, session in
        session.carrierPanel.toggleWalk()
    }
}

@_cdecl("lt_carrier_notice")
public func lt_carrier_notice(
    _ device: lt_device_t, _ text: UnsafePointer<CChar>?
) -> LTResult {
    guard let textStr = ltTakeString(text, what: "lt_carrier_notice: text") else { return kLTBadArgument }
    return withSession(device, what: "lt_carrier_notice") { _, session in
        session.carrierPanel.notice(textStr)
    }
}

// MARK: - Storage

@_cdecl("lt_storage_get")
public func lt_storage_get(
    _ device: lt_device_t, _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    queryDeviceSnapshot(device, "storage", what: "lt_storage_get", out: out)
}

/// Applies a storage action. json: {"action": "clearCaches" | "removeUnusedIPAs"}.
/// Both actions are the StorageSettingsView rows (decrypted-firmware cache
/// prune, unused-IPA removal); they are app-global, the device handle only
/// scopes the call.
@_cdecl("lt_storage_set")
public func lt_storage_set(
    _ device: lt_device_t, _ json: UnsafePointer<CChar>?
) -> LTResult {
    guard let jsonStr = ltTakeString(json, what: "lt_storage_set: json") else { return kLTBadArgument }
    struct Action: Codable { var action: String }
    guard let action = ltDecodeJSON(jsonStr, as: Action.self) else {
        LTLastError.set("lt_storage_set: json must be {\"action\": …}")
        return kLTBadArgument
    }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard ltResolveDevice(device) != nil else { return kLTNoSuchDevice }
    switch action.action {
    case "clearCaches":
        Task { @MainActor in
            guard let core = appCore() else { return }
            let preparing = core.jobs.jobs.values.contains {
                if case .preparing = $0 { true } else { false }
            }
            guard !preparing else {
                postToast(
                    title: "Can’t clear caches",
                    body: "A firmware preparation is using the decrypt cache.",
                    category: "storage"
                )
                return
            }
            guard let executable = FirmwareJobs.preparer else {
                postToast(title: "Can’t clear caches", body: "The preparer tool isn’t available.", category: "storage")
                return
            }
            do {
                _ = try await FirmwareTool.run(
                    FirmwareCommand.CachePrune(root: IPSWStore.cachesDirectory.appendingPathComponent("Decrypted", isDirectory: true)),
                    executable: executable
                )
                logEvent("storage: cleared unused decrypt cache")
            } catch {
                postToast(title: "Couldn’t clear caches", body: error.localizedDescription, category: "storage")
            }
        }
    case "removeUnusedIPAs":
        Task { @MainActor in
            guard let core = appCore() else { return }
            do {
                try IPALibrary.removeUnused(devices: core.library.instances)
                logEvent("storage: removed the IPAs no device has")
            } catch {
                postToast(title: "Couldn’t remove unused apps", body: error.localizedDescription, category: "storage")
            }
        }
    default:
        LTLastError.set("lt_storage_set: unknown action “\(action.action)”")
        return kLTBadArgument
    }
    return kLTAccepted
}

// MARK: - Web proxy

@_cdecl("lt_proxy_get")
public func lt_proxy_get(
    _ device: lt_device_t, _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    queryDeviceSnapshot(device, "proxy", what: "lt_proxy_get", out: out)
}

@_cdecl("lt_proxy_set")
public func lt_proxy_set(
    _ device: lt_device_t, _ json: UnsafePointer<CChar>?
) -> LTResult {
    guard let jsonStr = ltTakeString(json, what: "lt_proxy_set: json") else { return kLTBadArgument }
    guard let config = ltDecodeJSON(jsonStr, as: WebProxyConfiguration.self) else {
        LTLastError.set("lt_proxy_set: json must decode as WebProxyConfiguration")
        return kLTBadArgument
    }
    return withSession(device, what: "lt_proxy_set") { core, session in
        do {
            try session.proxy.configure(config)
        } catch {
            postToast(title: "Couldn’t apply the proxy", body: error.localizedDescription, category: "proxy")
            return
        }
        guard let handle = core.handle(for: session.instance.id) else { return }
        core.refreshProxySnapshot(session: session, handle: handle)
        // No event: the ABI has no proxy-changed event; the caller just set it
        // and lt_proxy_get reads the refreshed snapshot.
    }
}

// MARK: - Debug port

@_cdecl("lt_debug_port_get")
public func lt_debug_port_get(
    _ device: lt_device_t, _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    queryDeviceSnapshot(device, "debugPort", what: "lt_debug_port_get", out: out)
}

/// json: {"enabled": bool}. The port itself is chosen at the next boot
/// (DeviceOptions.chooseDebugPort); the lldb attach command is in the query.
@_cdecl("lt_debug_port_set")
public func lt_debug_port_set(
    _ device: lt_device_t, _ json: UnsafePointer<CChar>?
) -> LTResult {
    guard let jsonStr = ltTakeString(json, what: "lt_debug_port_set: json") else { return kLTBadArgument }
    struct Setting: Codable { var enabled: Bool }
    guard let setting = ltDecodeJSON(jsonStr, as: Setting.self) else {
        LTLastError.set("lt_debug_port_set: json must be {\"enabled\": bool}")
        return kLTBadArgument
    }
    return withSession(device, what: "lt_debug_port_set") { core, session in
        session.setDebugPortEnabled(setting.enabled)
        guard let handle = core.handle(for: session.instance.id) else { return }
        core.refreshDebugPortSnapshot(session: session, handle: handle)
    }
}
