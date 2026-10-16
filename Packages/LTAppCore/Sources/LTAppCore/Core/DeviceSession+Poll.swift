import LTBridgeC
/// DeviceSession's status poll, display-link management and capture actions.
///
/// The poll runs on @MainActor, driven by `lt_pump_main_queue()` (which the
/// Qt side calls on a timer): it advances the VM state on new frames, mirrors
/// frames into the Qt-facing ring, posts frame/status/zoom events, and ticks
/// the screen recording. No `Timer` is used: a Timer on the main RunLoop would
/// never fire under Qt's event loop on Linux.
import DeviceRuntime
import Foundation
import HostRuntime
import LightTouchCore

extension DeviceSession {
    /// One poll step. Called on @MainActor from `lt_pump_main_queue()`.
    @MainActor
    func poll() {
        guard !isReleased else { return }
        pollHelper()
        pollRecordingTick()
        refreshEraseBusy()
    }

    /// Watches the erase overlay (DeviceErase's `isErasing`, held beside the VM
    /// state): on change refreshes the row + posts StorageBusyChanged, and
    /// releases the storage claim when the erase ends.
    @MainActor
    private func refreshEraseBusy() {
        if isErasing != wasErasing {
            wasErasing = isErasing
            let lower = instance.id.uuidString.lowercased()
            if !isErasing {
                AppCore.shared?.storageWork.unclaim(lower)
            }
            AppCore.shared?.refreshLibrarySnapshots()
            EventPump.shared.post(kind: kLTEventStorageBusyChanged)
        }
    }

    @MainActor
    private func pollHelper() {
        // Refresh the lock-guarded snapshots the background host witnesses
        // read (BootCycle/Shutdown/Erase call them off the main thread).
        lock.withLock {
            _bgStatus = process?.status
            _bgShuttingDown = ladder.shuttingDown
            _bgHalting = ladder.halting
            _bgStorageFailed = process?.status?.storageFailed ?? false
            _bgPreparingDevice = readiness.preparingDevice
            _bgInstallerUsesDevice = AppInstaller.isUsingDevice(instance.id)
            _bgKeyboardInputEnabled = keyboard.enabled
        }
        guard let process else { return }
        if process.isDead {
            // Death is reported through process.onDeath; nothing to poll.
            return
        }
        guard let status = process.status else { return }

        // New frames end the boot (VMState.runsAfterFrame), unless a power-on
        // is still waiting to resume the machine.
        let serial = status.frameSerial
        if serial != lastPolledFrameSerial {
            lastPolledFrameSerial = serial
            if state.runsAfterFrame(poweringOn: cycle.poweringOn) {
                transition(to: .running)
                deviceReachable = true
            }
            mirrorFrame(status: status)
        }

        // Storage failure flips CaptureAvailability/input gating.
        if status.storageFailed, !storageFailedReported {
            storageFailedReported = true
            AppCore.shared?.refreshDeviceSnapshots(self)
        }
    }

    // MARK: - Display link

    /// Publishes the newest helper frame into the Qt-facing mirror ring,
    /// creating the ring (and posting DisplayLinkReady) on first frame or on
    /// a geometry/ring-generation change.
    @MainActor
    private func mirrorFrame(status: SharedStatus) {
        guard let surface = link?.frontSurface()?.surface else { return }
        let w = surface.width, h = surface.height
        frameWidth = w
        frameHeight = h
        if let mirror = displayMirror, mirror.width == w, mirror.height == h {
            mirror.publish(surface: surface)
            postFrameAvailable(serial: status.frameSerial, width: w, height: h)
            return
        }
        // (Re)create the mirror: new fd, new generation.
        let old = displayMirror
        let generation = (old?.generation ?? 0) &+ 1
        guard let mirror = QtFrameMirror(width: w, height: h, generation: generation) else { return }
        displayMirror = mirror
        old?.close() // the fd stays valid for Qt mmaps already taken; the mapping persists
        mirror.publish(surface: surface)
        AppCore.shared?.postDisplayLinkReady(self, mirror: mirror)
        postFrameAvailable(serial: status.frameSerial, width: w, height: h)
        AppCore.shared?.refreshDeviceSnapshots(self)
    }

    private func postFrameAvailable(serial: UInt64, width: Int, height: Int) {
        guard let handle = AppCore.shared?.handle(for: instance.id) else { return }
        EventPump.shared.post(kind: kLTEventFrameAvailable, device: handle) { e in
            e.seq = serial // ABI: seq carries frameSeq redundantly
            e.u.frameAvailable.frameSeq = serial
            e.u.frameAvailable.width = Int32(width)
            e.u.frameAvailable.height = Int32(height)
        }
    }

    @MainActor
    private func pollRecordingTick() {
        guard recording.phase == .recording else { return }
        let elapsed = recording.elapsedSeconds
        if elapsed != lastRecordingTickSecond {
            lastRecordingTickSecond = elapsed
            guard let handle = AppCore.shared?.handle(for: instance.id) else { return }
            EventPump.shared.post(kind: kLTEventRecordingTick, device: handle) { e in
                e.u.recordingTick.elapsedSeconds = UInt64(max(0, elapsed))
            }
        }
    }
}
