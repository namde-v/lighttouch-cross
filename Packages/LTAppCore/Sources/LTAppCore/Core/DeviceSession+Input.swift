/// DeviceSession's input entry points for the C bridge (ui/ABI.md §3.4).
///
/// The touch/key/button commands bypass the @MainActor hop: they read the
/// mirrored `fastLink` and call `HelperLink.send`, which is thread-safe and
/// ordered (DeviceLink writes on its own queue). Orientation, GPS and zoom go
/// through @MainActor because they touch settings/panel models.
import DeviceRuntime
import HostServiceClient
import LTBridgeC
import Foundation
import HostRuntime
import LightTouchCore

extension DeviceSession {
    // MARK: - Fast path (any thread)

    /// Touch phases (qemu-ios-ui.h QEMU_IOS_TOUCH_*).
    enum TouchPhase: Int32 { case down = 0, move = 1, up = 2 }

    /// Injects a touch at normalized panel coordinates (0…1, y down).
    /// No-op when the helper isn't linked.
    nonisolated func injectTouch(x: Double, y: Double, phase: Int32, slot: Int32 = 0) {
        guard let link = fastLink else { return }
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)
        link.send(.touch(slot: Int(slot), phase: Int(phase), x: clampedX, y: clampedY))
    }

    /// Injects a Mac key code press/release (KeyboardInput's USB HID path).
    nonisolated func injectKey(macKeyCode: Int32, down: Bool) {
        fastLink?.send(.key(macKeyCode: Int(macKeyCode), down: down))
    }

    /// Injects a hardware button (0 home, 1 power, 2 volume up, 3 volume down
    /// per DeviceInput.Button; the ABI exposes 0–2).
    nonisolated func injectButton(button: Int32, down: Bool) {
        fastLink?.send(.button(Int(button), down: down))
    }

    /// Injects a button tap: down now, release after DeviceInput's hold
    /// interval (mirrors DeviceInput.tap's release-off-main-queue).
    nonisolated func injectTap(button: Int32) {
        guard let link = fastLink else { return }
        link.send(.button(Int(button), down: true))
        nonisolated(unsafe) let release = link
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.10) {
            release.send(.button(Int(button), down: false))
        }
    }

    /// Injects a shake gesture.
    nonisolated func injectShake() {
        fastLink?.send(.shake)
    }

    /// Injects typed text via the US-key path (mirrors DeviceInput.typeText's
    /// key fallback, without the guest-agent round trip: off-actor there is
    /// no agent to ask). Characters with no US key are skipped.
    nonisolated func injectText(_ text: String, shiftHeld: Bool) {
        guard let link = fastLink, !text.isEmpty else { return }
        for character in text {
            guard let (code, shift) = GuestKeyboard.key(for: character) else { continue }
            let pressShift = shift && !shiftHeld
            if pressShift { link.send(.key(macKeyCode: 56, down: true)) }
            link.send(.key(macKeyCode: Int(code), down: true))
            link.send(.key(macKeyCode: Int(code), down: false))
            if pressShift { link.send(.key(macKeyCode: 56, down: false)) }
        }
    }

    // MARK: - @MainActor input

    /// Absolute orientation: 0 portrait, 1 landscape-right, 2 upside-down,
    /// 3 landscape-left. Quarter-turns the short way (DeviceRotation keeps the
    /// guest in lockstep).
    @MainActor
    func setOrientation(degrees: Int) {
        rotation.rotate(toDegrees: degrees)
    }

    /// Pushes a GPS fix to the guest modem and saves it to carrier settings.
    @MainActor
    func setGPS(latitude: Double, longitude: Double) {
        let location = GPSLocation(latitude: latitude, longitude: longitude)
        carrierPanel.set(location: location)
        carrierModem.modem("gps-fix", location.fix()) { _ in }
    }

    /// Clears the GPS fix (stops the walk, tells the modem the fix is gone).
    @MainActor
    func clearGPS() {
        carrierModem.modem("gps-fix", "") { _ in }
    }

    // MARK: - Apps

    /// Re-reads the installed apps (lt_apps_refresh). Updates the cache;
    /// the snapshot builder renders it.
    @MainActor
    func refreshAppsList() async {
        guard let services = try? apps.services else { return }
        if let installed = try? await services.installedApps() {
            cachedInstalledApps = installed
        }
    }

    // MARK: - Lock / wake / start

    /// lt_device_lock: the Device-menu Lock item. Powered off → Start (boot);
    /// otherwise the power button toggles the guest's sleep (Lock/Wake).
    @MainActor
    func setLocked(_ locked: Bool) {
        if isPoweredOff {
            if !locked { boot(options: nil) }
            return
        }
        input.tap(.power)
    }
}
