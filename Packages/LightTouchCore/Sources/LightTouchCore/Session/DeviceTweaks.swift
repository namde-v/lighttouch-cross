// Tweaks (Tweaks.swift) for one device: its saved TweakSettings, and on a running device the foreground watch's
// apply (DeviceTweaks.apply), which brings the guest to them whenever they change, and once at every start.

import Foundation
import HostRuntime
import HostServiceWire
import Observation

@Observable public final class DeviceTweaks {
    @ObservationIgnored private let settingsFile: DeviceSettingsFile
    /// The device's firmware version ("4.2.1").
    public let version: String
    /// The board runs Light Touch's guest tools (the agent): no iPhone OS 1.x.
    public let guestTools: Bool
    /// The base pins its own clock (a beta kept inside its release window): Time Machine stays off.
    public let clockPinned: Bool

    /// The Developer Disk Image Developer Settings mounts: the app's for this version; nil where none fits.
    public let developerImage: URL?

    /// `guestRoot`: the unpacked guest archive, which holds the app's Developer Disk Images.
    public init(
        settings: DeviceSettingsFile,
        version: String,
        guestTools: Bool,
        clockPinned: Bool,
        guestRoot: URL? = Bundled.guestRoot
    ) {
        settingsFile = settings
        self.version = version
        self.guestTools = guestTools
        self.clockPinned = clockPinned
        developerImage = DeveloperDiskImage.image(version: version, in: guestRoot)
    }

    public var settings: TweakSettings { settingsFile.value.tweaks ?? TweakSettings() }

    public func change(_ change: (inout TweakSettings) -> Void) {
        settingsFile.change { s in
            var t = s.tweaks ?? TweakSettings()
            change(&t)
            s.tweaks = t
        }
    }

    public func isAvailable(_ tweak: Tweak) -> Bool {
        if tweak == .developerSettings, developerImage == nil { return false }
        return tweak.isAvailable(version: version, guestTools: guestTools, clockPinned: clockPinned)
    }

    /// The next start's clock (Time Machine), as PreparedDeviceBoot takes it.
    public var bootClock: Date? { settings.clock(clockPinned: clockPinned) }

    // MARK: Applying

    /// What this boot last sent; nil until its first apply.
    @ObservationIgnored private var applied: TweakSettings.Applied?
    /// The tweaks the running guest's agent can't apply (an older guest package), for the panel.
    public private(set) var needsNewerGuestTools: [Tweak] = []
    /// The last apply's failure, for the panel.
    public private(set) var failure: String?

    public func forgetBoot() {
        applied = nil
        mountedImage = false
        mountFailure = nil
        needsNewerGuestTools = []
        failure = nil
    }

    // MARK: Developer Settings

    /// This boot mounted (or tried) the Developer Disk Image.
    @ObservationIgnored private var mountedImage = false

    /// Mounts the version's Developer Disk Image once per boot while Developer Settings is on. A mounted image stays
    /// until the device restarts: the mounter of these versions has no unmount.
    public func mountDeveloperImage(services: DeviceServices) async {
        guard settings.isOn(.developerSettings), isAvailable(.developerSettings), let image = developerImage,
            !mountedImage
        else { return }
        mountedImage = true
        do {
            let mounted = try await services.mountDeveloperImage(image)
            logEvent("tweaks: Developer Disk Image \(mounted ? "mounted" : "already mounted"): \(image.path)")
            mountFailure = nil
        } catch {
            mountFailure = error.localizedDescription
            logEvent("tweaks: \(error)")
        }
    }
    /// This boot's mount failure, for the panel (an apply after it doesn't clear it).
    public private(set) var mountFailure: String?

    /// Brings the running guest to the saved settings when they changed since this boot's last apply (or at its
    /// first). `isCurrent` says the boot is still this one.
    public func apply(guest: GuestServices, isCurrent: () -> Bool) async throws {
        guard guestTools else { return }
        let settings = settings
        let target = settings.applied(version: version)
        guard target != applied else { return }
        do {
            let result = try await TweakApplier.apply(
                settings,
                version: version,
                guest: guest,
                again: applied != nil
            )
            guard isCurrent() else { throw CancellationError() }
            applied = target
            needsNewerGuestTools = result.missing
            failure = nil
            if result.written != settings.written { change { $0.written = result.written } }
            if result.resprung { logEvent("tweaks: SpringBoard restarted for \(settings.on.map(\.rawValue).sorted())") }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard isCurrent() else { throw CancellationError() }
            applied = target  // not again every poll: the next change, or the next start, tries again
            failure = error.localizedDescription
            logEvent("tweaks: \(error)")
        }
    }
}
