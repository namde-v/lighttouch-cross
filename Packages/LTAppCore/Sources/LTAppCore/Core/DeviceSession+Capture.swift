import LTBridgeC
/// DeviceSession's capture actions (ui/ABI.md §3.8, §6 gaps 4 and 11).
///
/// Frame sourcing: Swift reads the helper's frame ring through the Qt-facing
/// mirror (ShmCapture.supplier) — zero bridge traffic in the hot loop, reusing
/// ScreenRecordingSession unchanged. Screenshots are encoded by the portable
/// PNG writer (LTMPNG); clipboard/open-app are Qt-side effects driven by the
/// CaptureDone event + prefs snapshot.
///
/// The save-destination handshake (gap 11): `stop(discard: false)` suspends
/// the session in `.saving` with `chooseSaveDestination` posting
/// `kLTEventRecordingSaveNeeded`; `lt_capture_record_save` /
/// `lt_capture_record_discard` resume it.
import DeviceRuntime
import Foundation
import HostRuntime
import LightTouchCore

enum LTRecordingError: Error, LocalizedError {
    /// The take is ready; Qt must supply the destination (two-step handshake).
    case awaitingDestination
    /// No frame has been published yet (screenshot with no display link).
    case noFrame
    var errorDescription: String? {
        switch self {
        case .awaitingDestination: return "Waiting for a save destination."
        case .noFrame: return "No frame has been published yet."
        }
    }
}

extension DeviceSession {
    // MARK: - Screenshots

    /// Captures the latest mirrored frame, rotated per PanelCapture, and
    /// writes it to the capture destination. Result: kLTEventCaptureDone.
    @MainActor
    func takeScreenshot() {
        guard let core = AppCore.shared, let handle = core.handle(for: instance.id) else { return }
        let availability = core.captureAvailability(for: self)
        guard !screenshotBusy else { return }
        guard availability.canTakeScreenshot else {
            postCaptureDone(handle: handle, kind: kLTCaptureScreenshot, path: nil, ok: false,
                            message: "The device isn’t running.")
            return
        }
        screenshotBusy = true
        core.refreshCaptureAvailabilitySnapshot(session: self, handle: handle)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.screenshotBusy = false
                if let core = AppCore.shared, let handle = core.handle(for: self.instance.id) {
                    core.refreshCaptureAvailabilitySnapshot(session: self, handle: handle)
                }
            }
            do {
                guard let mirror = self.displayMirror, let image = mirror.latestImage() else {
                    throw LTRecordingError.noFrame
                }
                let turns = PanelCapture.quarterTurns(
                    guestTurn: 0,
                    deviceDegrees: self.rotation.degrees,
                    surfaceFollowsRotation: false
                )
                let rotated = PanelCapture.rotated(image, clockwiseQuarterTurns: turns)
                guard let png = LTMPNG.encode(rotated) else {
                    throw CaptureError.failed("Couldn’t encode the screenshot.")
                }
                guard let prefs = ltPrefs() else { throw CaptureError.failed("The core isn’t initialized.") }
                let destination = try CapturePreferences(defaults: prefs)
                    .captureDestination("screenshot", extension: "png")
                try png.write(to: destination)
                self.postCaptureDone(
                    handle: handle, kind: kLTCaptureScreenshot,
                    path: destination.path, ok: true, message: nil
                )
            } catch {
                self.postCaptureDone(
                    handle: handle, kind: kLTCaptureScreenshot,
                    path: nil, ok: false, message: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Screen recording

    @MainActor
    func startRecording() {
        guard let core = AppCore.shared, let handle = core.handle(for: instance.id) else { return }
        guard !recording.isActive else { return }
        let availability = core.captureAvailability(for: self)
        guard availability.canStartRecording else {
            postCaptureDone(handle: handle, kind: kLTCaptureRecording, path: nil, ok: false,
                            message: "The device isn’t running.")
            return
        }
        recording.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.recordingChanged() }
        }
        recording.onCompleted = { [weak self] completion in
            MainActor.assumeIsolated { self?.recordingCompleted(completion) }
        }
        recording.chooseSaveDestination = { [weak self] _ in
            await self?.awaitSaveDestination()
        }
        recording.start(
            frame: ShmCapture.supplier(for: self),
            destination: { [weak self] in
                guard let self else { throw LTRecordingError.awaitingDestination }
                if let path = self.pendingSavePath { return URL(fileURLWithPath: path) }
                throw LTRecordingError.awaitingDestination
            }
        )
        lastRecordingTickSecond = -1
    }

    @MainActor
    func stopRecording(discard: Bool) {
        guard recording.canStop else { return }
        if discard {
            recording.stop(discard: true)
        } else {
            recording.stop(discard: false)
            // complete() will throw awaitingDestination -> chooseSaveDestination
            // posts kLTEventRecordingSaveNeeded and suspends there.
        }
    }

    /// Resolves the suspended save-destination handshake (gap 11).
    /// `path` nil = discard the take.
    func completeRecordingSave(path: String?) {
        if let path {
            pendingSavePath = path
            saveContinuation?.resume(returning: URL(fileURLWithPath: path))
        } else {
            discardAfterSave = true
            saveContinuation?.resume(returning: nil)
        }
        saveContinuation = nil
    }

    /// Qt's answer to kLTEventRecordingSaveNeeded (lt_capture_record_save).
    @MainActor
    func saveRecording(to url: URL) {
        completeRecordingSave(path: url.path)
    }

    /// Qt's answer to kLTEventRecordingSaveNeeded (lt_capture_record_discard).
    @MainActor
    func discardRecording() {
        completeRecordingSave(path: nil)
    }

    // MARK: - Availability (for lt_capture_availability)

    /// Whether a frame is available for screenshot.
    @MainActor
    var hasFrame: Bool {
        displayMirror?.latestImage() != nil
    }

    /// Whether recording can start (device running, not already recording).
    @MainActor
    var canRecord: Bool {
        !recording.isActive
    }

    /// Whether a recording is in progress.
    @MainActor
    var isRecording: Bool {
        recording.isActive
    }

    // MARK: - Recording callbacks

    private func recordingChanged() {
        guard let core = AppCore.shared, let handle = core.handle(for: instance.id) else { return }
        core.refreshCaptureAvailabilitySnapshot(session: self, handle: handle)
        let phase: Int32 =
            switch recording.phase {
            case .idle: kLTRecordingPhaseIdle
            case .starting: kLTRecordingPhaseStarting
            case .recording: kLTRecordingPhaseRecording
            case .saving: kLTRecordingPhaseSaving
            case .saved: kLTRecordingPhaseIdle
            }
        EventPump.shared.post(kind: kLTEventRecordingPhaseChanged, device: handle) { e in
            e.u.recordingPhaseChanged.phase = phase
        }
    }

    private func recordingCompleted(_ completion: ScreenRecordingSession.Completion) {
        guard let core = AppCore.shared, let handle = core.handle(for: instance.id) else { return }
        pendingSavePath = nil
        switch completion {
        case .saved(let url):
            postCaptureDone(handle: handle, kind: kLTCaptureRecording, path: url.path, ok: true, message: nil)
        case .discarded:
            postCaptureDone(handle: handle, kind: kLTCaptureRecording, path: nil, ok: true, message: nil)
        case .failed(let kept):
            if discardAfterSave {
                discardAfterSave = false
                if let kept, FileManager.default.fileExists(atPath: kept.path) {
                    try? FileManager.default.removeItem(at: kept)
                }
                postCaptureDone(handle: handle, kind: kLTCaptureRecording, path: nil, ok: true, message: nil)
            } else {
                postCaptureDone(
                    handle: handle, kind: kLTCaptureRecording,
                    path: kept?.path, ok: false,
                    message: recording.failure?.localizedDescription ?? "The recording couldn’t be saved."
                )
            }
        }
        core.refreshCaptureAvailabilitySnapshot(session: self, handle: handle)
    }

    /// Suspends until Qt answers the save-destination prompt (gap 11).
    private func awaitSaveDestination() async -> URL? {
        if let handle = AppCore.shared?.handle(for: instance.id) {
            let suggested = CapturePreferences.captureName("recording")
            EventPump.shared.post(kind: kLTEventRecordingSaveNeeded, device: handle) { e in
                e.u.recordingSaveNeeded.suggestedName = ltCopyCString(suggested)
            }
        }
        return await withCheckedContinuation { continuation in
            saveContinuation = continuation
        }
    }

    // MARK: - Helpers

    private func postCaptureDone(handle: lt_device_t, kind: Int32, path: String?, ok: Bool, message: String?) {
        EventPump.shared.post(kind: kLTEventCaptureDone, device: handle) { e in
            e.u.captureDone.kind = kind
            e.u.captureDone.path = ltCopyCString(path)
            e.u.captureDone.ok = ok ? 1 : 0
            e.u.captureDone.message = ltCopyCString(message)
        }
    }

    // MARK: - Handshake state (stored on the session)

    private var pendingSavePath: String? {
        get { captureHandshake.pendingSavePath }
        set { captureHandshake.pendingSavePath = newValue }
    }

    private var saveContinuation: CheckedContinuation<URL?, Never>? {
        get { captureHandshake.saveContinuation }
        set { captureHandshake.saveContinuation = newValue }
    }

    private var discardAfterSave: Bool {
        get { captureHandshake.discardAfterSave }
        set { captureHandshake.discardAfterSave = newValue }
    }
}

/// The recording save handshake's mutable state (extensions can't add stored
/// properties, so it lives in a box owned by the session).
final class CaptureHandshakeState {
    var pendingSavePath: String?
    var saveContinuation: CheckedContinuation<URL?, Never>?
    var discardAfterSave = false
}
