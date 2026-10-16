import LTBridgeC
/// Snapshot DTOs and @MainActor refresh builders: tweaks, carrier, storage
/// (gap 6 model), web proxy, debug port, apps (ui/ABI.md §3.5, §3.6).
import DeviceRuntime
import Foundation
import HostRuntime
import HostServiceWire
import LightTouchCore

// MARK: - DTOs

struct LTTweakDTO: Codable {
    var id: String
    var caption: String
    var on: Bool
    var available: Bool
}

struct LTHiddenAppDTO: Codable {
    var name: String
    var bundleId: String
}

/// lt_tweaks_get.
struct LTTweaksDTO: Codable {
    var running: Bool
    var tweaks: [LTTweakDTO]
    var color: UInt32?
    var clock: Double?
    var status: String?
    var message: String?
    var hiddenApps: [LTHiddenAppDTO]?
}

struct LTModemStatusDTO: Codable {
    var carrier: String
    var mccMNC: String
    var callState: String
    var registered: Bool
    var simPresent: Bool
    var signalDBM: Int
    var hasGPS: Bool
    var error: String?
}

struct LTSentSMSDTO: Codable {
    var id: Int
    var number: String
    var text: String
}

/// lt_carrier_get.
struct LTCarrierDTO: Codable {
    var carrierName: String
    var mcc: String
    var mnc: String
    var settings: CarrierSettings
    var status: LTModemStatusDTO?
    var sent: [LTSentSMSDTO]
    var message: String?
    var networkValid: Bool
    var networkEdited: Bool
    var applyingNetwork: Bool
    var callNumber: String
    var smsNumber: String
    var smsText: String
    var callState: String
    var canRing: Bool
    var canAnswer: Bool
    var canHangUp: Bool
    var latitude: String
    var longitude: String
    var walking: Bool
    var reportedLocation: GPSLocation
}

/// lt_storage_get (ui/ABI.md §6 gap 6: the portable storage-settings model).
struct LTStorageDTO: Codable {
    var device: String
    var baseBytes: Int64
    var dataBytes: Int64
    var snapshotBytes: Int64
    var totalBytes: Int64
    var measuredAt: Double
}

/// lt_debug_port_get.
struct LTDebugPortDTO: Codable {
    var enabled: Bool
    var lldbCommand: String?
}

/// lt_apps_list.
struct LTAppsDTO: Codable {
    var banner: LTAppsBannerDTO
    var device: LTAppsDeviceDTO
    var rows: [LTAppRowDTO]
}

struct LTAppsBannerDTO: Codable {
    var text: String?
}

struct LTAppsDeviceDTO: Codable {
    var canQueueInstall: Bool
    var canReachDevice: Bool
    var installing: Bool
    var preparingDevice: Bool
    var hasFileTransfer: Bool
    var reconnecting: Bool
    var transfersPaused: Bool
}

struct LTAppRowDTO: Codable {
    var identity: String
    var title: String
    var subtitle: String
    var kind: String // "app" | "install" | "failed"
    var progress: Double?
    var enabled: Bool
}

// MARK: - Builders

extension AppCore {
    func refreshTweaksSnapshot(session: DeviceSession, handle: lt_device_t) {
        let panel = session.tweaksPanel
        let tweakDTOs = Tweak.allCases.map { tweak in
            LTTweakDTO(
                id: tweak.rawValue,
                caption: panel.caption(tweak),
                on: panel.isOn(tweak),
                available: panel.isAvailable(tweak)
            )
        }
        let settings = panel.settings
        let dto = LTTweaksDTO(
            running: panel.isRunning,
            tweaks: tweakDTOs,
            color: settings.coreAnimationColor.rawValue,
            clock: settings.clock.timeIntervalSince1970,
            status: panel.status,
            message: panel.message,
            hiddenApps: panel.hiddenApps?.map { LTHiddenAppDTO(name: $0.name, bundleId: $0.bundleID) }
        )
        if let data = ltEncodeJSON(dto) {
            SnapshotStore.shared.setDevice(handle, key: "tweaks", json: data)
        }
    }

    func refreshCarrierSnapshot(session: DeviceSession, handle: lt_device_t) {
        let panel = session.carrierPanel
        let dto = LTCarrierDTO(
            carrierName: panel.carrierName,
            mcc: panel.mcc,
            mnc: panel.mnc,
            settings: panel.settings,
            status: panel.status.map { s in
                LTModemStatusDTO(
                    carrier: s.carrier, mccMNC: s.mccMNC, callState: s.callState,
                    registered: s.registered, simPresent: s.simPresent,
                    signalDBM: s.signalDBM, hasGPS: s.hasGPS, error: s.error
                )
            },
            sent: panel.sent.map { LTSentSMSDTO(id: $0.id, number: $0.number, text: $0.text) },
            message: panel.message,
            networkValid: panel.networkValid,
            networkEdited: panel.networkEdited,
            applyingNetwork: panel.applyingNetwork,
            callNumber: panel.callNumber,
            smsNumber: panel.smsNumber,
            smsText: panel.smsText,
            callState: panel.callState,
            canRing: panel.canRing,
            canAnswer: panel.canAnswer,
            canHangUp: panel.canHangUp,
            latitude: panel.latitude,
            longitude: panel.longitude,
            walking: panel.walking,
            reportedLocation: panel.reportedLocation
        )
        if let data = ltEncodeJSON(dto) {
            SnapshotStore.shared.setDevice(handle, key: "carrier", json: data)
        }
    }

    /// Measures one device's storage (gap 6). Runs on @MainActor when the
    /// snapshots refresh — never on the query path.
    func refreshStorageSnapshot(session: DeviceSession, handle: lt_device_t) {
        let paths = session.paths
        let baseBytes = LTStorageUsage.size(of: paths.base)
        let dataBytes = LTStorageUsage.size(of: paths.overlay)
        let snapshotBytes = LTStorageUsage.size(of: paths.snapshot)
            + LTStorageUsage.size(of: paths.snapshotMeta)
        let dto = LTStorageDTO(
            device: session.instance.id.uuidString.lowercased(),
            baseBytes: baseBytes,
            dataBytes: dataBytes,
            snapshotBytes: snapshotBytes,
            totalBytes: baseBytes + dataBytes + snapshotBytes,
            measuredAt: Date().timeIntervalSince1970
        )
        if let data = ltEncodeJSON(dto) {
            SnapshotStore.shared.setDevice(handle, key: "storage", json: data)
        }
    }

    func refreshProxySnapshot(session: DeviceSession, handle: lt_device_t) {
        if let data = ltEncodeJSON(session.proxy.configuration) {
            SnapshotStore.shared.setDevice(handle, key: "proxy", json: data)
        }
    }

    func refreshDebugPortSnapshot(session: DeviceSession, handle: lt_device_t) {
        let dto = LTDebugPortDTO(
            enabled: session.options.debugPortEnabled,
            lldbCommand: session.options.lldbAttachCommand
        )
        if let data = ltEncodeJSON(dto) {
            SnapshotStore.shared.setDevice(handle, key: "debugPort", json: data)
        }
    }

    func refreshAppsSnapshot(session: DeviceSession, handle: lt_device_t) {
        let apps = session.apps
        let queue = AppInstaller.queue(for: session.instance.id)
        let device = LTAppsDeviceDTO(
            canQueueInstall: apps.canQueueInstall,
            canReachDevice: apps.canReachDevice,
            installing: apps.canReachDevice && AppInstaller.isUsingDevice(session.instance.id),
            preparingDevice: session.preparingDevice,
            hasFileTransfer: FilesConnection.shared.isTransferring(session.instance.id),
            reconnecting: false, // ConnectionRecovery is not wired in this pass
            transfersPaused: AppInstaller.isPaused(session.instance.id)
        )
        _ = queue
        // Rows: pending install jobs for this device. Installed-app rows need
        // a live device (installation_proxy); without one the list is the
        // pending queue plus a banner saying so.
        let rows: [LTAppRowDTO] = []
        var banner: String?
        if !apps.canReachDevice {
            banner = session.isRunning
                ? "Waiting for the device to answer…"
                : "Start the device to see its apps."
        }
        if let data = ltEncodeJSON(LTAppsDTO(
            banner: LTAppsBannerDTO(text: banner),
            device: device,
            rows: rows
        )) {
            SnapshotStore.shared.setDevice(handle, key: "apps", json: data)
        }
    }
}

// MARK: - Storage usage measurement (gap 6)

/// Portable storage measurement (Foundation only): allocated bytes of a
/// device's base, overlay and snapshots. The Mac app measured this in its app
/// target (StorageUsage); the bridge owns the portable version.
enum LTStorageUsage {
    /// Allocated bytes under `url` (files only, no traversal of symlinks out
    /// of the tree). Returns 0 for a missing tree.
    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
