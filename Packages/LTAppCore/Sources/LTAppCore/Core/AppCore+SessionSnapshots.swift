import LTBridgeC
/// Snapshot DTOs and @MainActor refresh builders: session status, menu
/// validation, notices, capture availability, zoom (ui/ABI.md §3.3, §3.4).
import DeviceRuntime
import Foundation
import HostRuntime
import LightTouchCore

// MARK: - DTOs

/// lt_device_status: DeviceMenuState fields + CaptureAvailability, flattened.
struct LTDeviceStatusDTO: Codable {
    var machine: Int32
    var running: Bool
    var sleeping: Bool
    var paused: Bool
    var shuttingDown: Bool
    var storageFailed: Bool
    var installing: Bool
    var acceptsInput: Bool
    var hasCompass: Bool
    var hasCellular: Bool
    var compassHeading: Int?
    var editingText: Bool
}

/// lt_menu_validate.
struct LTMenuValidationDTO: Codable {
    var enabled: Bool
    var title: String?
    var checked: Bool?
}

/// lt_notice_get.
struct LTNoticeDTO: Codable {
    var message: String?
    var operation: String?
    var offersErase: Bool
}

/// lt_capture_availability.
struct LTCaptureAvailabilityDTO: Codable {
    var canTakeScreenshot: Bool
    var canStartRecording: Bool
    var canToggleRecording: Bool
    var screenshotBusy: Bool
    var recordingSaving: Bool
    var recordingCanStop: Bool
}

/// lt_display_get_zoom.
struct LTZoomDTO: Codable {
    var mode: String
    var points: Double
    var shown: String
}

// MARK: - Builders

extension AppCore {
    /// The DeviceMenuState snapshot for a session (the struct the menu
    /// validation and lt_device_status both read).
    func menuState(for session: DeviceSession) -> DeviceMenuState {
        var state = DeviceMenuState()
        state.machine = session.state
        state.isRunning = session.isRunning
        state.isSleeping = session.isSleeping
        state.shuttingDown = session.shuttingDown
        state.storageFailed = session.storageFailed
        state.isInstalling = AppInstaller.isUsingDevice(session.instance.id)
        state.hasPendingInstalls = AppInstaller.hasPendingWork(for: session.instance.id)
        state.acceptsInput = session.acceptsInput
        state.hasCompass = session.profile.hasCompass
        state.hasCellular = session.profile.hasCellular
        state.compassHeading = session.compassHeading
        state.editingText = false // Qt owns focus state; it sets this via menu validation context if needed
        return state
    }

    func captureAvailability(for session: DeviceSession) -> CaptureAvailability {
        var availability = CaptureAvailability()
        availability.machine = session.state
        availability.isRunning = session.isRunning
        availability.isSleeping = session.isSleeping
        availability.screenshotBusy = session.screenshotBusy
        let phase = session.recording.phase
        availability.recordingSaving = phase == .saving
        availability.recordingCanStop = session.recording.canStop
        return availability
    }

    // MARK: - Refresh

    func refreshStatusSnapshot(session: DeviceSession, handle: lt_device_t) {
        let menu = menuState(for: session)
        let dto = LTDeviceStatusDTO(
            machine: ltVMState(menu.machine),
            running: menu.isRunning,
            sleeping: menu.isSleeping,
            paused: menu.machine == .paused,
            shuttingDown: menu.shuttingDown,
            storageFailed: menu.storageFailed,
            installing: menu.isInstalling,
            acceptsInput: menu.acceptsInput,
            hasCompass: menu.hasCompass,
            hasCellular: menu.hasCellular,
            compassHeading: menu.compassHeading,
            editingText: menu.editingText
        )
        if let data = ltEncodeJSON(dto) {
            SnapshotStore.shared.setDevice(handle, key: "status", json: data)
        }
    }

    func refreshNoticeSnapshot(session: DeviceSession, handle: lt_device_t) {
        let notices = session.notices
        let dto = LTNoticeDTO(
            message: notices.message,
            operation: notices.shownOperation?.rawValue,
            offersErase: notices.offersErase
        )
        if let data = ltEncodeJSON(dto) {
            SnapshotStore.shared.setDevice(handle, key: "notice", json: data)
        }
    }

    func refreshCaptureAvailabilitySnapshot(session: DeviceSession, handle: lt_device_t) {
        let availability = captureAvailability(for: session)
        let dto = LTCaptureAvailabilityDTO(
            canTakeScreenshot: availability.canTakeScreenshot,
            canStartRecording: availability.canStartRecording,
            canToggleRecording: availability.canToggleRecording,
            screenshotBusy: availability.screenshotBusy,
            recordingSaving: availability.recordingSaving,
            recordingCanStop: availability.recordingCanStop
        )
        if let data = ltEncodeJSON(dto) {
            SnapshotStore.shared.setDevice(handle, key: "captureAvailability", json: data)
        }
    }

    func refreshZoomSnapshot(session: DeviceSession, handle: lt_device_t) {
        let mode = ZoomMode.saved(for: session.profile, in: prefs)
        // Effective points need the view geometry (Qt-side); the snapshot
        // carries the mode and its nominal points at backing 1.
        let context = ZoomContext(fit: 1, physical: nil, backing: 1)
        let dto = LTZoomDTO(
            mode: mode.defaultsValue,
            points: Double(context.points(for: mode)),
            shown: context.shown(mode).defaultsValue
        )
        if let data = ltEncodeJSON(dto) {
            SnapshotStore.shared.setDevice(handle, key: "zoom", json: data)
        }
    }
}

// MARK: - Menu validation (pure over the snapshot)

/// Maps the ABI's kLTMenuItem* to DeviceMenuState.Item; nil = bad argument.
func ltMenuItem(_ item: Int32, arg: Int32) -> DeviceMenuState.Item? {
    switch item {
    case kLTMenuItemLock: return .lock
    case kLTMenuItemRotate: return .rotate
    case kLTMenuItemCompassHeading: return .compassHeading(Int(arg))
    case kLTMenuItemCarrier: return .carrier
    case kLTMenuItemInput: return .input
    case kLTMenuItemPause: return .pause
    case kLTMenuItemRestart: return .restart
    default: return nil
    }
}

// MARK: - Network access

/// The lt_network_status query payload.
struct LTNetworkStatusDTO: Codable {
    var state: Int32 // kLTNetworkAccess…
    var explanation: String
}

extension AppCore {
    func refreshNetworkStatusSnapshot() {
        let answer = prefs.object(forKey: NetworkAccessPreference.key) as? Bool
        let dto = LTNetworkStatusDTO(
            state: answer.map { $0 ? kLTNetworkAccessAllowed : kLTNetworkAccessDenied }
                ?? kLTNetworkAccessUnknown,
            explanation: "Whether the guest may reach the local network. Set by lt_network_set_allowed."
        )
        if let data = ltEncodeJSON(dto) {
            SnapshotStore.shared.setGlobal("networkStatus", json: data)
        }
    }
}
