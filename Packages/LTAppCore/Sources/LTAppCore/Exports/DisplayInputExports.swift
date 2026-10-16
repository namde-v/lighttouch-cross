/// Display & input exports (ui/ABI.md §3.4).
///
/// Input commands take the fast path: they resolve the session through
/// AppCore's nonisolated lookup and inject via nonisolated entry points —
/// `HelperLink.send` is thread-safe and ordered (DeviceLink writes on its own
/// queue). No @MainActor hop, so these return in microseconds. Zoom and the
/// panel-size/finger-dots commands go through @MainActor (settings + events);
/// the zoom math itself is pure.
import Foundation
import HostRuntime
import LTBridgeC
import LightTouchCore

// MARK: - Input (fast path, no @MainActor hop)

/// Resolves the session for the input fast path. The handle must be known and
/// the core initialized; a device with no session yet accepts the input as a
/// no-op (nowhere to send it, like the Mac app's nil link).
private func ltFastSession(_ device: lt_device_t) -> DeviceSession? {
    guard ltIsInitialized(), !ltIsShutDown(),
          let uuid = ltResolveDevice(device)
    else { return nil }
    return appCore()?.fastSession(for: uuid)
}

/// lt_input_touch: normalized touch (0–1, y-down) → LinkCommand.touch.
/// phase is kLTTouchBegan/Moved/Ended/Cancelled; one call per touch id.
@_cdecl("lt_input_touch")
public func lt_input_touch(
    _ device: lt_device_t, _ phase: Int32, _ x: Double, _ y: Double, _ touchId: Int32
) -> LTResult {
    guard ltResolveDevice(device) != nil else { return kLTNoSuchDevice }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard x.isFinite, y.isFinite else {
        LTLastError.set("lt_input_touch: coordinates must be finite")
        return kLTBadArgument
    }
    guard (0...3).contains(phase) else {
        LTLastError.set("lt_input_touch: phase must be kLTTouchBegan(0)..kLTTouchCancelled(3)")
        return kLTBadArgument
    }
    ltFastSession(device)?.injectTouch(x: x, y: y, phase: phase, slot: touchId)
    return kLTAccepted
}

/// lt_input_key: KeyboardInput.sendKey → helper key command. `code` is the
/// USB HID usage the guest expects (Qt translates native codes via
/// lt_key_mac_from_evdev); `modifiers` is the KeyModifiers bitmask.
@_cdecl("lt_input_key")
public func lt_input_key(
    _ device: lt_device_t, _ code: UInt16, _ down: Int32, _ modifiers: Int32
) -> LTResult {
    guard ltResolveDevice(device) != nil else { return kLTNoSuchDevice }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    _ = modifiers // accepted for ABI parity; the guest-side mapping is Qt's (gap 8)
    ltFastSession(device)?.keyboard.sendKey(macKeyCode: code, down: down != 0)
    return kLTAccepted
}

/// lt_input_text: text that doesn't map to key codes (IME, dead keys) —
/// DeviceInput.typeText / .paste.
@_cdecl("lt_input_text")
public func lt_input_text(
    _ device: lt_device_t, _ text: UnsafePointer<CChar>?, _ shiftHeld: Int32
) -> LTResult {
    guard ltResolveDevice(device) != nil else { return kLTNoSuchDevice }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard let textStr = ltTakeString(text, what: "lt_input_text: text") else { return kLTBadArgument }
    guard !textStr.isEmpty else { return kLTAccepted }
    ltFastSession(device)?.input.typeText(textStr, shiftHeld: shiftHeld != 0)
    return kLTAccepted
}

/// lt_input_button: DeviceInput.tap — Home/Menu, volume, etc.
/// (DeviceInput.Button raw values as kLTButton…).
@_cdecl("lt_input_button")
public func lt_input_button(_ device: lt_device_t, _ button: Int32) -> LTResult {
    guard ltResolveDevice(device) != nil else { return kLTNoSuchDevice }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard let btn = DeviceInput.Button(rawValue: Int(button)) else {
        LTLastError.set("lt_input_button: unknown button \(button)")
        return kLTBadArgument
    }
    ltFastSession(device)?.input.tap(btn)
    return kLTAccepted
}

/// lt_input_shake: DeviceInput.shake().
@_cdecl("lt_input_shake")
public func lt_input_shake(_ device: lt_device_t) -> LTResult {
    guard ltResolveDevice(device) != nil else { return kLTNoSuchDevice }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    ltFastSession(device)?.input.shake()
    return kLTAccepted
}

/// lt_input_tilt: DeviceInput.setTilt → accelerometer.
@_cdecl("lt_input_tilt")
public func lt_input_tilt(_ device: lt_device_t, _ angle: Double, _ pitch: Double) -> LTResult {
    guard ltResolveDevice(device) != nil else { return kLTNoSuchDevice }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard angle.isFinite, pitch.isFinite else {
        LTLastError.set("lt_input_tilt: angle/pitch must be finite")
        return kLTBadArgument
    }
    ltFastSession(device)?.input.setTilt(angle: angle, pitch: pitch)
    return kLTAccepted
}

/// lt_input_motion_pose: DeviceInput.setMotionPose.
@_cdecl("lt_input_motion_pose")
public func lt_input_motion_pose(_ device: lt_device_t, _ pose: Int32) -> LTResult {
    guard ltResolveDevice(device) != nil else { return kLTNoSuchDevice }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard let motionPose = DeviceInput.MotionPose(rawValue: Int(pose)) else {
        LTLastError.set("lt_input_motion_pose: pose must be kLTMotionPoseUpright(0)/kLTMotionPoseFlat(1)")
        return kLTBadArgument
    }
    // setMotionPose writes DeviceSettings — go through @MainActor.
    return withSession(device, what: "lt_input_motion_pose") { _, session in
        session.input.setMotionPose(motionPose)
    }
}

/// lt_input_rotate: DeviceRotation — guest rotation request (degrees).
/// Resulting geometry arrives as kLTEventRotationChanged.
@_cdecl("lt_input_rotate")
public func lt_input_rotate(_ device: lt_device_t, _ degrees: Int32) -> LTResult {
    withSession(device, what: "lt_input_rotate") { _, session in
        session.setOrientation(degrees: Int(degrees))
    }
}

/// lt_input_compass: compass heading override (Device-menu compass items).
@_cdecl("lt_input_compass")
public func lt_input_compass(_ device: lt_device_t, _ heading: Int32) -> LTResult {
    guard (0..<360).contains(heading) else {
        LTLastError.set("lt_input_compass: heading must be 0–359")
        return kLTBadArgument
    }
    return withSession(device, what: "lt_input_compass") { core, session in
        session.compassHeading = Int(heading)
        guard let handle = core.handle(for: session.instance.id) else { return }
        core.refreshStatusSnapshot(session: session, handle: handle)
    }
}

/// lt_input_keyboard_pointer_key: KeyboardPointer.key — the keyboard-as-mouse
/// drive mode. The resulting Touch is forwarded internally to the touch path.
@_cdecl("lt_input_keyboard_pointer_key")
public func lt_input_keyboard_pointer_key(
    _ device: lt_device_t, _ code: UInt16, _ down: Int32, _ modifiers: Int32
) -> LTResult {
    guard ltResolveDevice(device) != nil else { return kLTNoSuchDevice }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard let session = ltFastSession(device) else { return kLTAccepted }
    var pointer = KeyboardPointer()
    let mods = KeyModifiers(rawValue: Int(modifiers))
    let (_, touches) = pointer.key(code, down: down != 0, modifiers: mods, typingOff: false, canTouch: true)
    for touch in touches {
        let phase: Int32
        switch touch.phase {
        case .begin: phase = kLTTouchBegan
        case .update: phase = kLTTouchMoved
        case .end: phase = kLTTouchEnded
        }
        session.injectTouch(x: Double(touch.point.x), y: Double(touch.point.y), phase: phase, slot: 0)
    }
    return kLTAccepted
}

// MARK: - Zoom (commands + pure math)

// ui/ABI.md §4.3: the zoom model (ZoomMode/ZoomContext) is nonisolated; the
// pure functions compute from their arguments only.

/// lt_display_set_zoom: sets ZoomMode ("fit"/"physical"/"pixel"/"p:1.5") and
/// persists per board. Emits kLTEventZoomChanged.
@_cdecl("lt_display_set_zoom")
public func lt_display_set_zoom(
    _ device: lt_device_t, _ mode: UnsafePointer<CChar>?
) -> LTResult {
    guard let modeStr = ltTakeString(mode, what: "lt_display_set_zoom: mode") else { return kLTBadArgument }
    let zoomMode = ZoomMode(defaultsValue: modeStr)
    // Round-trip check: unknown strings become .fit, but an explicitly invalid
    // mode is a caller bug — reject strings that don't round-trip, except the
    // documented names (which always round-trip by construction).
    guard zoomMode.defaultsValue == modeStr || modeStr == "fit" else {
        // ZoomMode(defaultsValue:) maps anything unknown to .fit; only accept
        // the canonical forms.
        LTLastError.set("lt_display_set_zoom: invalid mode “\(modeStr)”")
        return kLTBadArgument
    }
    return withSession(device, what: "lt_display_set_zoom") { core, session in
        zoomMode.save(for: session.profile, in: ltPrefs())
        guard let handle = core.handle(for: session.instance.id) else { return }
        core.refreshZoomSnapshot(session: session, handle: handle)
        core.postZoomChanged(for: session)
    }
}

/// lt_display_get_zoom: {mode, points, shown} from the zoom snapshot.
@_cdecl("lt_display_get_zoom")
public func lt_display_get_zoom(
    _ device: lt_device_t, _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    queryDeviceSnapshot(device, "zoom", what: "lt_display_get_zoom", out: out)
}

/// lt_zoom_stops_json: ZoomContext.stops as JSON [{mode, points}].
/// physical < 0 means none.
@_cdecl("lt_zoom_stops_json")
public func lt_zoom_stops_json(
    _ fit: Double, _ physical: Double, _ backing: Double,
    _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    guard let out else {
        LTLastError.set("lt_zoom_stops_json: null out")
        return kLTBadArgument
    }
    guard fit.isFinite, fit > 0, backing.isFinite, backing > 0 else {
        LTLastError.set("lt_zoom_stops_json: fit/backing must be positive and finite")
        return kLTBadArgument
    }
    let context = ZoomContext(
        fit: fit, physical: physical >= 0 ? physical : nil, backing: backing
    )
    struct Stop: Codable { var mode: String; var points: Double }
    let stops = context.stops.map { Stop(mode: $0.mode.defaultsValue, points: Double($0.points)) }
    guard let data = ltEncodeJSON(stops) else {
        LTLastError.set("lt_zoom_stops_json: encoding failed")
        return kLTFailed
    }
    out.pointee = ltCopyCString(data).map { UnsafePointer($0) }
    return out.pointee == nil ? kLTFailed : kLTOk
}

/// lt_zoom_step: ZoomContext.step(from:direction:) → points, or -1 past either end.
@_cdecl("lt_zoom_step")
public func lt_zoom_step(
    _ fit: Double, _ physical: Double, _ backing: Double, _ p: Double, _ direction: Int32
) -> Double {
    guard fit.isFinite, fit > 0, backing.isFinite, backing > 0,
          p.isFinite, p > 0, direction == 1 || direction == -1
    else { return -1 }
    let context = ZoomContext(
        fit: fit, physical: physical >= 0 ? physical : nil, backing: backing
    )
    guard let mode = context.step(from: CGFloat(p), direction: direction > 0 ? 1 : -1) else { return -1 }
    return Double(context.points(for: mode))
}

/// lt_zoom_draws_nearest: ZoomContext.drawsNearest — Qt picks nearest vs.
/// linear texture filtering.
@_cdecl("lt_zoom_draws_nearest")
public func lt_zoom_draws_nearest(_ p: Double, _ backing: Double) -> Int32 {
    guard p.isFinite, p > 0, backing.isFinite, backing > 0 else { return 0 }
    // drawsNearest(p, backing): nearest when the scale is an integer multiple
    // of the backing scale (pixel-accurate), else linear.
    let scale = p * backing
    return abs(scale.rounded() - scale) < 0.001 ? 1 : 0
}

/// lt_resize_drag: FreeFormResize(board:).drag(…) → {width, height, shiftX,
/// shiftY, limit} in upright guest pixels. Qt applies the size via
/// lt_display_set_panel_size.
@_cdecl("lt_resize_drag")
public func lt_resize_drag(
    _ board: UnsafePointer<CChar>?, _ startW: Double, _ startH: Double,
    _ edgeX: Double, _ edgeY: Double, _ deltaX: Double, _ deltaY: Double,
    _ pointsPerPixel: Double, _ symmetric: Int32, _ quarterTurned: Int32,
    _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    guard let out else {
        LTLastError.set("lt_resize_drag: null out")
        return kLTBadArgument
    }
    guard let boardStr = ltTakeString(board, what: "lt_resize_drag: board") else { return kLTBadArgument }
    guard let boardValue = Board(rawValue: boardStr) else {
        LTLastError.set("lt_resize_drag: unknown board “\(boardStr)”")
        return kLTBadArgument
    }
    for (name, value) in [
        ("startW", startW), ("startH", startH), ("pointsPerPixel", pointsPerPixel),
    ] where !value.isFinite || value <= 0 {
        LTLastError.set("lt_resize_drag: \(name) must be positive and finite")
        return kLTBadArgument
    }
    let resize = FreeFormResize(board: boardValue)
    let drag = resize.drag(
        from: CGSize(width: startW, height: startH),
        edges: CGVector(dx: edgeX, dy: edgeY),
        by: CGVector(dx: deltaX, dy: deltaY),
        points: CGFloat(pointsPerPixel),
        symmetric: symmetric != 0,
        quarterTurned: quarterTurned != 0
    )
    struct DragDTO: Codable {
        var width: Double
        var height: Double
        var shiftX: Double
        var shiftY: Double
        var limit: String?
    }
    let dto = DragDTO(
        width: Double(drag.size.width), height: Double(drag.size.height),
        shiftX: Double(drag.shift.dx), shiftY: Double(drag.shift.dy),
        limit: drag.limit
    )
    guard let data = ltEncodeJSON(dto) else {
        LTLastError.set("lt_resize_drag: encoding failed")
        return kLTFailed
    }
    out.pointee = ltCopyCString(data).map { UnsafePointer($0) }
    return out.pointee == nil ? kLTFailed : kLTOk
}

/// lt_display_set_panel_size: applies the free-form size to the running
/// session. Emits kLTEventRotationChanged (geometry) + kLTEventZoomChanged.
@_cdecl("lt_display_set_panel_size")
public func lt_display_set_panel_size(
    _ device: lt_device_t, _ width: Int32, _ height: Int32
) -> LTResult {
    guard width > 0, height > 0 else {
        LTLastError.set("lt_display_set_panel_size: size must be positive")
        return kLTBadArgument
    }
    return withSession(device, what: "lt_display_set_panel_size") { core, session in
        session.instance.panel = "\(width)x\(height)"
        do {
            try core.library.save(session.instance)
        } catch {
            postToast(title: "Couldn’t resize the panel", body: error.localizedDescription, category: "display")
            return
        }
        guard let handle = core.handle(for: session.instance.id) else { return }
        EventPump.shared.post(kind: kLTEventRotationChanged, device: handle)
        core.refreshZoomSnapshot(session: session, handle: handle)
        core.postZoomChanged(for: session)
    }
}

/// lt_display_set_finger_dots: the window's finger-dots toggle.
@_cdecl("lt_display_set_finger_dots")
public func lt_display_set_finger_dots(_ device: lt_device_t, _ shown: Int32) -> LTResult {
    withSession(device, what: "lt_display_set_finger_dots") { _, session in
        session.setFingerDots(shown != 0)
    }
}

/// lt_display_get_finger_dots: current toggle state.
@_cdecl("lt_display_get_finger_dots")
public func lt_display_get_finger_dots(
    _ device: lt_device_t, _ out: UnsafeMutablePointer<Int32>?
) -> LTResult {
    guard let out else {
        LTLastError.set("lt_display_get_finger_dots: null out")
        return kLTBadArgument
    }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard let uuid = ltResolveDevice(device) else { return kLTNoSuchDevice }
    // A lock-protected read would be ideal; the toggle is set from @MainActor
    // and read here — go through the snapshot the setter maintains.
    guard let data = SnapshotStore.shared.device(device, key: "fingerDots"),
          let dto = try? JSONDecoder().decode(FingerDotsDTO.self, from: data)
    else {
        // No snapshot yet: read the session directly (may be off @MainActor;
        // fingerDotsShown is lock-guarded).
        out.pointee = (appCore()?.fastSession(for: uuid)?.fingerDotsShown ?? false) ? 1 : 0
        return kLTOk
    }
    out.pointee = dto.shown ? 1 : 0
    return kLTOk
}

/// The finger-dots snapshot payload (maintained by setFingerDots).
struct FingerDotsDTO: Codable { var shown: Bool }

// MARK: - Additive: evdev -> Mac keycode (gap 8)

/// Maps a Linux evdev keycode to the Mac USB HID keycode that `lt_input_key`
/// expects. Pure; returns 0 for unmapped codes.
@_cdecl("lt_key_mac_from_evdev")
public func lt_key_mac_from_evdev(_ evdevCode: Int32) -> UInt16 {
    // evdev (KEY_*) -> USB HID usage ID. Covers letters, digits, and common
    // control keys; unmapped codes return 0.
    switch evdevCode {
    case 30: return 0x00  // KEY_A -> kHIDUsage_KeyboardA
    case 48: return 0x01  // KEY_B
    case 46: return 0x02  // KEY_C
    case 32: return 0x03  // KEY_D
    case 18: return 0x04  // KEY_E
    case 33: return 0x05  // KEY_F
    case 34: return 0x06  // KEY_G
    case 35: return 0x07  // KEY_H
    case 23: return 0x08  // KEY_I
    case 36: return 0x09  // KEY_J
    case 37: return 0x0A  // KEY_K
    case 38: return 0x0B  // KEY_L
    case 50: return 0x0C  // KEY_M
    case 49: return 0x0D  // KEY_N
    case 24: return 0x0E  // KEY_O
    case 25: return 0x0F  // KEY_P
    case 16: return 0x10  // KEY_Q
    case 19: return 0x11  // KEY_R
    case 31: return 0x12  // KEY_S
    case 20: return 0x13  // KEY_T
    case 22: return 0x14  // KEY_U
    case 47: return 0x15  // KEY_V
    case 17: return 0x16  // KEY_W
    case 45: return 0x17  // KEY_X
    case 21: return 0x18  // KEY_Y
    case 44: return 0x19  // KEY_Z
    case 2: return 0x1E   // KEY_1
    case 3: return 0x1F   // KEY_2
    case 4: return 0x20   // KEY_3
    case 5: return 0x21   // KEY_4
    case 6: return 0x22   // KEY_5
    case 7: return 0x23   // KEY_6
    case 8: return 0x24   // KEY_7
    case 9: return 0x25   // KEY_8
    case 10: return 0x26  // KEY_9
    case 11: return 0x27  // KEY_0
    case 28: return 0x28  // KEY_ENTER
    case 1: return 0x29   // KEY_ESC
    case 14: return 0x2A  // KEY_BACKSPACE
    case 15: return 0x2B  // KEY_TAB
    case 57: return 0x2C  // KEY_SPACE
    case 12: return 0x2D  // KEY_MINUS
    case 13: return 0x2E  // KEY_EQUAL
    case 26: return 0x2F  // KEY_LEFTBRACE
    case 27: return 0x30  // KEY_RIGHTBRACE
    case 43: return 0x31  // KEY_BACKSLASH
    case 40: return 0x33  // KEY_SEMICOLON
    case 39: return 0x34  // KEY_APOSTROPHE
    case 41: return 0x35  // KEY_GRAVE
    case 51: return 0x36  // KEY_COMMA
    case 52: return 0x37  // KEY_DOT
    case 53: return 0x38  // KEY_SLASH
    case 58: return 0x39  // KEY_CAPSLOCK
    case 59: return 0x3A  // KEY_F1
    case 60: return 0x3B  // KEY_F2
    case 61: return 0x3C  // KEY_F3
    case 62: return 0x3D  // KEY_F4
    case 63: return 0x3E  // KEY_F5
    case 64: return 0x3F  // KEY_F6
    case 65: return 0x40  // KEY_F7
    case 66: return 0x41  // KEY_F8
    case 67: return 0x42  // KEY_F9
    case 68: return 0x43  // KEY_F10
    case 87: return 0x44  // KEY_F11
    case 88: return 0x45  // KEY_F12
    case 110: return 0x49  // KEY_INSERT
    case 102: return 0x4A  // KEY_HOME
    case 104: return 0x4B  // KEY_PAGEUP
    case 111: return 0x4C  // KEY_DELETE
    case 107: return 0x4D  // KEY_END
    case 109: return 0x4E  // KEY_PAGEDOWN
    case 106: return 0x4F  // KEY_RIGHT
    case 105: return 0x50  // KEY_LEFT
    case 108: return 0x51  // KEY_DOWN
    case 103: return 0x52  // KEY_UP
    default: return 0
    }
}
