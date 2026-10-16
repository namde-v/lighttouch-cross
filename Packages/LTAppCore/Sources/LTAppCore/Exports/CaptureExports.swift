// CaptureExports.swift — ABI.md §3.8: screenshots and screen recordings.
//
// Fronts ScreenRecordingSession, PanelCapture, CapturePreferences, reusing the
// shm-ring frame supplier (ShmCapture). Frames never cross the bridge; Swift
// maps the same shm ring the Qt DisplayItem maps.

import Foundation
import LTBridgeC
import LightTouchCore

// MARK: - Screenshot

/// Captures the latest frame (rotated per PanelCapture.quarterTurns), writes
/// via CapturePreferences, emits kLTEventCaptureDone.
@_cdecl("lt_capture_screenshot")
public func lt_capture_screenshot(_ device: lt_device_t) -> LTResult {
    guard let session = sessionForDevice(device) else {
        return kLTBadHandle
    }
    Task { @MainActor in
        await session.takeScreenshot()
    }
    return kLTOk
}

// MARK: - Recording

@_cdecl("lt_capture_record_start")
public func lt_capture_record_start(_ device: lt_device_t) -> LTResult {
    guard let session = sessionForDevice(device) else {
        return kLTBadHandle
    }
    Task { @MainActor in
        await session.startRecording()
    }
    return kLTOk
}

@_cdecl("lt_capture_record_stop")
public func lt_capture_record_stop(_ device: lt_device_t, _ discard: Int32) -> LTResult {
    guard let session = sessionForDevice(device) else {
        return kLTBadHandle
    }
    Task { @MainActor in
        await session.stopRecording(discard: discard != 0)
    }
    return kLTOk
}

/// Qt's answer to kLTEventRecordingSaveNeeded: save the finished recording to `path`.
@_cdecl("lt_capture_record_save")
public func lt_capture_record_save(_ device: lt_device_t, _ path: UnsafePointer<CChar>?) -> LTResult {
    guard let session = sessionForDevice(device) else {
        return kLTBadHandle
    }
    guard let path, let url = URL(string: String(cString: path)) ?? Optional(URL(fileURLWithPath: String(cString: path))) else {
        LTLastError.set("lt_capture_record_save: missing path")
        return kLTBadArgument
    }
    Task { @MainActor in
        await session.saveRecording(to: url)
    }
    return kLTOk
}

@_cdecl("lt_capture_record_discard")
public func lt_capture_record_discard(_ device: lt_device_t) -> LTResult {
    guard let session = sessionForDevice(device) else {
        return kLTBadHandle
    }
    Task { @MainActor in
        await session.discardRecording()
    }
    return kLTOk
}

// MARK: - Capture preferences

private struct CapturePrefsDTO: Codable {
    var saveLocation: String
    var copyOnCapture: Bool
    var recordsBezel: Bool
    var openAfterCapture: Bool
    var sound: Bool
}

@_cdecl("lt_capture_prefs_get")
public func lt_capture_prefs_get(_ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> LTResult {
    guard let out else { return kLTBadArgument }
    let prefs = CapturePreferences.shared
    let dto = CapturePrefsDTO(
        saveLocation: prefs.saveLocation.path,
        copyOnCapture: prefs.copyOnCapture,
        recordsBezel: prefs.recordsBezel,
        openAfterCapture: prefs.openFinderAfterCapture,
        sound: prefs.playSoundAfterCapture
    )
    guard let json = ltEncodeJSON(dto) else { return kLTFailed }
    out.pointee = ltCopyCString(json).map { UnsafePointer($0) }
    return kLTOk
}

@_cdecl("lt_capture_prefs_set")
public func lt_capture_prefs_set(_ json: UnsafePointer<CChar>?) -> LTResult {
    guard let json, let dto = ltDecodeJSON(CapturePrefsDTO.self, from: String(cString: json)) else {
        LTLastError.set("lt_capture_prefs_set: invalid JSON")
        return kLTBadArgument
    }
    let prefs = CapturePreferences.shared
    prefs.saveLocation = URL(fileURLWithPath: dto.saveLocation)
    prefs.copyOnCapture = dto.copyOnCapture
    prefs.recordsBezel = dto.recordsBezel
    prefs.openFinderAfterCapture = dto.openAfterCapture
    prefs.playSoundAfterCapture = dto.sound
    EventPump.shared.post(kind: kLTEventCapturePrefsChanged) { _ in }
    return kLTOk
}

// MARK: - Capture availability
// (lt_capture_availability is in SessionExports.swift; it reads the
// "captureAvailability" snapshot maintained by DeviceSession+Capture.)

// MARK: - Helpers

/// Resolves an lt_device_t handle to its DeviceSession (nil if unknown).
func sessionForDevice(_ device: lt_device_t) -> DeviceSession? {
    guard let core = appCore(),
          let uuid = HandleRegistry.shared.uuid(for: device) else { return nil }
    return core.session(for: uuid)
}
