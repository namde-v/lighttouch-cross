import LTBridgeC
/// Snapshot DTOs and @MainActor refresh builders: device library, sidebar,
/// storage work, firmware jobs, catalog (ui/ABI.md §3.2, §3.10; §6 gap 3).
///
/// These `Codable` snapshot types are the JSON documents the queries hand out.
/// The models expose live objects; the bridge snapshots them here, on
/// @MainActor, into `SnapshotStore` (lock-protected), from which the
/// nonisolated queries serve them without ever hopping to @MainActor.
import DeviceRuntime
import FirmwareSchema
import Foundation
import HostRuntime
import LightTouchCore

// MARK: - DTOs

/// One device-library row (lt_device_list / lt_device_row).
struct LTDeviceRowDTO: Codable {
    var id: String
    var name: String
    var board: String
    var firmware: String
    var status: Int32
    var statusText: String
    var busy: String?
    var firmwareNote: String?
}

/// lt_storage_busy: { "<uuid>": "deleting"|"erasing" }.
struct LTStorageBusyDTO: Codable {
    var busy: [String: String]
}

/// lt_sidebar_list.
struct LTSidebarDTO: Codable {
    var ids: [String]
    var names: [String: String]
    var labels: [LTSidebarLabelDTO]
}

struct LTSidebarLabelDTO: Codable {
    var id: String
    var title: String
    var subtitle: String
}

/// One firmware job (lt_jobs_list).
struct LTJobDTO: Codable {
    var entryId: String
    var kind: String // "download" | "prepare" | "thirdParty"
    var progress: Double?
    var preparation: LTPreparationDTO?
    var failed: String?
}

struct LTPreparationDTO: Codable {
    var step: Int
    var steps: Int
    var name: String
    var fraction: Double
    var detail: String?
    var remaining: Double?
}

/// One catalog entry (lt_catalog_list).
struct LTCatalogEntryDTO: Codable {
    var id: String
    var board: String
    var productType: String?
    var marketingName: String?
    var version: String
    var build: String
    var status: String
    var statusNote: String?
    var prereleaseBadge: String?
    var media: [String]
    var released: String?
    var managesApps: Bool
    var estimates: LTEstimatesDTO?
}

struct LTEstimatesDTO: Codable {
    var preparedBytes: Int64
    var peakBytes: Int64
    var seconds: Int
}

// MARK: - Refresh builders (AppCore @MainActor)

extension AppCore {
    /// Rebuilds the device-list, per-row, storage-busy and sidebar snapshots.
    func refreshLibrarySnapshots() {
        var rows: [LTDeviceRowDTO] = []
        for instance in library.instances {
            let session = sessions[instance.id]
            rows.append(deviceRowDTO(for: instance, session: session))
            if let handle = handle(for: instance.id),
                let data = ltEncodeJSON(rows.last!)
            {
                SnapshotStore.shared.setDevice(handle, key: "row", json: data)
            }
        }
        if let data = ltEncodeJSON(rows) {
            SnapshotStore.shared.setGlobal("deviceList", json: data)
        }
        var busy: [String: String] = [:]
        for (id, kind) in storageWork.busy {
            busy[id] = kind == .erasing ? "erasing" : "deleting"
        }
        if let data = ltEncodeJSON(LTStorageBusyDTO(busy: busy)) {
            SnapshotStore.shared.setGlobal("storageBusy", json: data)
        }
        let labels = sidebar.ids.compactMap { id -> LTSidebarLabelDTO? in
            guard let entry = catalog.entry(id: id) else { return nil }
            let label = sidebar.label(for: entry)
            return LTSidebarLabelDTO(id: id, title: label.title, subtitle: label.subtitle)
        }
        let dto = LTSidebarDTO(ids: sidebar.ids, names: sidebar.names, labels: labels)
        if let data = ltEncodeJSON(dto) {
            SnapshotStore.shared.setGlobal("sidebarList", json: data)
        }
    }

    private func deviceRowDTO(for instance: DeviceInstance, session: DeviceSession?) -> LTDeviceRowDTO {
        let busyKind = storageWork.busy[instance.id.uuidString.lowercased()]
        let (status, statusText): (Int32, String) = {
            if let busyKind {
                return busyKind == .erasing
                    ? (kLTDeviceRowStateErasing, "Erasing…")
                    : (kLTDeviceRowStateDeleting, "Deleting…")
            }
            guard let session else { return (kLTDeviceRowStateReady, "Ready") }
            switch session.state {
            case .notStarted, .poweredOff: return (kLTDeviceRowStateReady, "Ready")
            case .booting: return (kLTDeviceRowStateRunning, "Starting…")
            case .running, .paused: return (kLTDeviceRowStateRunning, "Running")
            case .dead: return (kLTDeviceRowStateError, "Stopped")
            }
        }()
        let entry = catalog.entry(id: instance.firmware)
        return LTDeviceRowDTO(
            id: instance.id.uuidString.lowercased(),
            name: instance.name,
            board: instance.board,
            firmware: instance.firmware,
            status: status,
            statusText: statusText,
            busy: busyKind == .erasing ? "erasing" : busyKind == .deleting ? "deleting" : nil,
            firmwareNote: entry?.statusNote ?? entry?.prereleaseBadge
        )
    }

    /// Rebuilds the jobs snapshot; also refreshes the aggregate taskbar progress event.
    func refreshJobsSnapshots() {
        let dtos = jobs.jobs.map { entryId, job in jobDTO(entryId: entryId, job: job) }
            .sorted { $0.entryId < $1.entryId }
        if let data = ltEncodeJSON(dtos) {
            SnapshotStore.shared.setGlobal("jobsList", json: data)
        }
        // Taskbar/dock badge: the aggregate progress (DeviceRow.dockProgress).
        let fraction = FirmwareJob.dockProgress(jobs.jobs.values) ?? -1
        EventPump.shared.post(kind: kLTEventTaskbarProgress) { e in
            e.u.taskbarProgress.fraction = fraction
        }
    }

    private func jobDTO(entryId: String, job: FirmwareJob) -> LTJobDTO {
        switch job {
        case .downloading(let fraction, let remaining, _, let mirror, _):
            let thirdParty = mirror.flatMap(FirmwareJob.thirdParty) != nil
            return LTJobDTO(
                entryId: entryId,
                kind: thirdParty ? "thirdParty" : "download",
                progress: fraction / 2,
                preparation: nil,
                failed: nil
            )
        case .preparing(let p):
            return LTJobDTO(
                entryId: entryId,
                kind: "prepare",
                progress: p.bar,
                preparation: LTPreparationDTO(
                    step: p.step, steps: p.steps, name: p.name,
                    fraction: p.fraction, detail: p.detail, remaining: p.remaining
                ),
                failed: nil
            )
        case .failed(let reason):
            return LTJobDTO(entryId: entryId, kind: "download", progress: nil, preparation: nil, failed: reason)
        }
    }

    /// Rebuilds the full catalog-entries snapshot. `lt_catalog_list` filters
    /// this in nonisolated Swift per call (the filter varies per call).
    func refreshCatalogSnapshot() {
        let dtos = catalog.entries.map { catalogEntryDTO($0) }
        if let data = ltEncodeJSON(dtos) {
            SnapshotStore.shared.setGlobal("catalogEntries", json: data)
        }
    }

    private func catalogEntryDTO(_ entry: FirmwareCatalog.Entry) -> LTCatalogEntryDTO {
        LTCatalogEntryDTO(
            id: entry.id,
            board: entry.board,
            productType: entry.productType,
            marketingName: entry.marketingName,
            version: entry.version,
            build: entry.build,
            status: entry.status.rawValue,
            statusNote: entry.statusNote,
            prereleaseBadge: entry.prereleaseBadge,
            media: entry.media,
            released: entry.released,
            managesApps: entry.managesApps,
            estimates: LTEstimatesDTO(
                preparedBytes: entry.estimates.preparedBytes,
                peakBytes: entry.estimates.peakBytes,
                seconds: entry.estimates.seconds
            )
        )
    }
}

// MARK: - Catalog filter (pure, nonisolated)

/// The lt_catalog_list filter document: { "text":…, "board":…|null, "status":…|null }.
struct LTCatalogFilter: Decodable {
    var text: String?
    var board: String?
    var status: String?
}

/// Applies the ABI's catalog filter to the snapshotted entries (pure).
func ltFilterCatalog(_ entries: [LTCatalogEntryDTO], filter: LTCatalogFilter) -> [LTCatalogEntryDTO] {
    entries.filter { entry in
        if let board = filter.board, entry.board != board { return false }
        if let status = filter.status, entry.status != status { return false }
        if let text = filter.text, !text.isEmpty {
            let hay = "\(entry.marketingName ?? "") \(entry.version) \(entry.build) \(entry.id)".lowercased()
            if !hay.contains(text.lowercased()) { return false }
        }
        return true
    }
}
