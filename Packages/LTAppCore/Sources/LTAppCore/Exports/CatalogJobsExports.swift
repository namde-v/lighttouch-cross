// CatalogJobsExports.swift — ABI.md §3.10: firmware catalog & jobs, drops.
//
// Fronts FirmwareCatalog, FirmwareJobs, DroppedFiles. Job progress posts
// kLTEventJobProgress / kLTEventJobDone.

import Foundation
import LTBridgeC
import LightTouchCore

// MARK: - Catalog

private struct CatalogFilterDTO: Codable {
    var text: String?
    var board: String?
    var status: String?
}

@_cdecl("lt_catalog_list")
public func lt_catalog_list(
    _ filterJson: UnsafePointer<CChar>?,
    _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    guard let out else { return kLTBadArgument }
    guard let core = appCore() else { return kLTFailed }
    var text = ""
    var board: String?
    var status: String?
    if let filterJson,
       let dto = ltDecodeJSON(String(cString: filterJson), as: CatalogFilterDTO.self) {
        text = dto.text ?? ""
        board = dto.board
        status = dto.status
    }
    let entries = core.catalog.entries.filter { entry in
        if let board, entry.board != board { return false }
        if let status, "\(entry.status)" != status { return false }
        if !text.isEmpty {
            let hay = "\(entry.marketingName) \(entry.version) \(entry.build) \(entry.productType)".lowercased()
            if !hay.contains(text.lowercased()) { return false }
        }
        return true
    }.map { entry in
        CatalogEntryDTO(
            id: entry.id,
            board: entry.board,
            productType: entry.productType,
            marketingName: entry.marketingName,
            version: entry.version,
            build: entry.build,
            status: "\(entry.status)",
            statusNote: entry.statusNote,
            prereleaseBadge: entry.prereleaseBadge,
            media: entry.media,
            released: entry.released,
            managesApps: entry.managesApps
        )
    }
    guard let json = ltEncodeJSON(entries) else { return kLTFailed }
    out.pointee = ltCopyCString(json)
    return kLTOk
}

/// The `lt_catalog_list` row shape (ui/ABI.md §3.10).
private struct CatalogEntryDTO: Encodable {
    var id, board, productType, marketingName, version, build, status: String
    var statusNote, prereleaseBadge: String?
    var media: [String]
    var released: String?
    var managesApps: Bool
}

@_cdecl("lt_catalog_details")
public func lt_catalog_details(
    _ entryId: UnsafePointer<CChar>?,
    _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    guard let entryId, let out else { return kLTBadArgument }
    guard let core = appCore() else { return kLTFailed }
    let id = String(cString: entryId)
    guard let entry = core.catalog.entry(id: id) else {
        LTLastError.set("lt_catalog_details: unknown entry '\(id)'")
        return kLTBadArgument
    }
    // Build the details snapshot from the entry (ABI.md §3.10).
    let dto = CatalogDetailsDTO(
        id: entry.id,
        board: entry.board,
        productType: entry.productType,
        marketingName: entry.marketingName,
        version: entry.version,
        build: entry.build,
        status: "\(entry.status)",
        statusNote: entry.statusNote,
        keysPresent: !entry.keys.isEmpty,
        hasRecipe: entry.recipe != nil,
        offersJailbreak: FirmwareJobs.offersJailbreak(entry),
        offersSkipSetup: FirmwareJobs.offersSkipSetup(entry),
        managesApps: entry.managesApps,
        media: entry.media
    )
    guard let json = ltEncodeJSON(dto) else { return kLTFailed }
    out.pointee = ltCopyCString(json)
    return kLTOk
}

/// The `lt_catalog_details` payload (ui/ABI.md §3.10).
private struct CatalogDetailsDTO: Encodable {
    var id, board, productType, marketingName, version, build, status: String
    var statusNote: String?
    var keysPresent, hasRecipe, offersJailbreak, offersSkipSetup, managesApps: Bool
    var media: [String]
}

// MARK: - Jobs

@_cdecl("lt_jobs_list")
public func lt_jobs_list(_ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> LTResult {
    guard let out else { return kLTBadArgument }
    guard let core = appCore() else { return kLTFailed }
    // FirmwareJobs is @MainActor; snapshot on @MainActor. The box carries the
    // value across the actor boundary (region isolation).
    let jobsJsonBox = LTBox("[]")
    let semaphore = DispatchSemaphore(value: 0)
    Task { @MainActor in
        let jobs = core.jobs.jobs.map { (entryId, job) in
            switch job {
            case .downloading(let fraction, let remaining, _, let mirror, _):
                JobDTO(
                    entryId: entryId, kind: "download", progress: fraction,
                    remaining: remaining, mirror: mirror, message: nil
                )
            case .preparing(let prep):
                JobDTO(
                    entryId: entryId, kind: "prepare", progress: prep.bar,
                    remaining: nil, mirror: nil, message: nil
                )
            case .failed(let message):
                JobDTO(
                    entryId: entryId, kind: "failed", progress: nil,
                    remaining: nil, mirror: nil, message: message
                )
            }
        }
        if let data = ltEncodeJSON(jobs), let str = String(data: data, encoding: .utf8) {
            jobsJsonBox.set(str)
        }
        semaphore.signal()
    }
    // Pump the main runloop while waiting: the @MainActor task above can
    // only run when the main runloop is pumped (see lt_init), and this
    // export is called on the UI thread — FirmwareJobsWindow's
    // Component.onCompleted runs jobs.refresh() at startup. A bare
    // semaphore.wait() here blocks the UI thread forever: the task never
    // runs, the semaphore never signals, QML creation never finishes and
    // the window is never painted (white window, 0% CPU, Not Responding).
    // 10 s backstop; on timeout the caller keeps its previous state
    // (LTJobsAdapter::refresh checks the result and returns early).
    let deadline = Date().addingTimeInterval(10)
    while semaphore.wait(timeout: .now()) != .success, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard semaphore.wait(timeout: .now()) == .success else {
        LTLastError.set("lt_jobs_list: timed out waiting for @MainActor")
        return kLTFailed
    }
    out.pointee = ltCopyCString(jobsJsonBox.get())
    return kLTOk
}

/// One row of the `lt_jobs_list` payload (ui/ABI.md §3.10).
private struct JobDTO: Encodable {
    var entryId: String
    var kind: String // "download" | "prepare" | "failed"
    var progress: Double?
    var remaining: Double?
    var mirror: String?
    var message: String?
}

private struct JobOptionsDTO: Codable {
    var jailbreak: Bool?
    var skipSetup: Bool?
    var keepStock: Bool?
}

@_cdecl("lt_job_start")
public func lt_job_start(
    _ entryId: UnsafePointer<CChar>?,
    _ optionsJson: UnsafePointer<CChar>?
) -> LTResult {
    guard let entryId else { return kLTBadArgument }
    guard let core = appCore() else { return kLTFailed }
    let id = String(cString: entryId)
    let opts = optionsJson.flatMap { ltDecodeJSON(String(cString: $0), as: JobOptionsDTO.self) }
    Task { @MainActor in
        guard let entry = core.catalog.entry(id: id) else {
            LTLastError.set("lt_job_start: unknown entry '\(id)'")
            return
        }
        if let opts {
            // FirmwareJobs keeps "stock" (no jailbreak) as the opt-out set;
            // jailbreak is on unless the entry is in keepsStock.
            if opts.jailbreak == true { core.jobs.keepsStock.remove(id) }
            if opts.jailbreak == false { core.jobs.keepsStock.insert(id) }
            if opts.skipSetup == true { core.jobs.skipsSetup.insert(id) }
            if opts.skipSetup == false { core.jobs.skipsSetup.remove(id) }
            if opts.keepStock == true { core.jobs.keepsStock.insert(id) }
            if opts.keepStock == false { core.jobs.keepsStock.remove(id) }
        }
        core.jobs.downloadAndPrepare(entry)
    }
    return kLTOk
}

@_cdecl("lt_job_import_ipsw")
public func lt_job_import_ipsw(_ pathsJson: UnsafePointer<CChar>?) -> LTResult {
    guard let pathsJson else { return kLTBadArgument }
    guard let core = appCore() else { return kLTFailed }
    guard let paths = ltDecodeJSON(String(cString: pathsJson), as: [String].self) else {
        LTLastError.set("lt_job_import_ipsw: invalid JSON")
        return kLTBadArgument
    }
    Task { @MainActor in
        core.jobs.importIPSWs(paths.map { URL(fileURLWithPath: $0) })
    }
    return kLTOk
}

@_cdecl("lt_job_cancel")
public func lt_job_cancel(_ entryId: UnsafePointer<CChar>?) -> LTResult {
    guard let entryId else { return kLTBadArgument }
    guard let core = appCore() else { return kLTFailed }
    let id = String(cString: entryId)
    Task { @MainActor in
        if let entry = core.catalog.entry(id: id) {
            core.jobs.cancel(entry)
        }
    }
    return kLTOk
}

@_cdecl("lt_job_cancel_all")
public func lt_job_cancel_all() -> LTResult {
    guard let core = appCore() else { return kLTFailed }
    Task { @MainActor in
        core.jobs.cancelAll()
    }
    return kLTOk
}

@_cdecl("lt_job_dismiss_failure")
public func lt_job_dismiss_failure(_ entryId: UnsafePointer<CChar>?) -> LTResult {
    guard let entryId else { return kLTBadArgument }
    guard let core = appCore() else { return kLTFailed }
    let id = String(cString: entryId)
    Task { @MainActor in
        if let entry = core.catalog.entry(id: id) {
            core.jobs.dismissFailure(entry)
        }
    }
    return kLTOk
}

@_cdecl("lt_jobs_can_download")
public func lt_jobs_can_download(_ out: UnsafeMutablePointer<Int32>?) -> LTResult {
    guard let out else { return kLTBadArgument }
    guard let core = appCore() else { return kLTFailed }
    // FirmwareJobs is @MainActor; read on @MainActor. The box carries the
    // values across the actor boundary (region isolation).
    let box = LTBox((can: false, reason: nil as String?))
    let semaphore = DispatchSemaphore(value: 0)
    Task { @MainActor in
        box.set((can: core.jobs.canDownload, reason: core.jobs.unavailableReason))
        semaphore.signal()
    }
    // Same pump+timeout as lt_jobs_list above: this export is also called
    // on the UI thread at startup (FirmwareJobsWindow onCompleted calls
    // jobs.refreshCanDownload()), and a bare wait() blocks it forever.
    let deadline = Date().addingTimeInterval(10)
    while semaphore.wait(timeout: .now()) != .success, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard semaphore.wait(timeout: .now()) == .success else {
        LTLastError.set("lt_jobs_can_download: timed out waiting for @MainActor")
        return kLTFailed
    }
    let result = box.get()
    out.pointee = result.can ? 1 : 0
    if let reason = result.reason {
        LTLastError.set(reason)
    }
    return kLTOk
}

// MARK: - Drops (surface 12)

@_cdecl("lt_drop_classify")
public func lt_drop_classify(_ path: UnsafePointer<CChar>?, _ out: UnsafeMutablePointer<Int32>?) -> LTResult {
    guard let path, let out else { return kLTBadArgument }
    let kind = DroppedFiles(URL(fileURLWithPath: String(cString: path)))
    out.pointee = switch kind {
    case .ipsw: kLTDropIPSW
    case .ipa: kLTDropIPA
    case .media: kLTDropMedia
    case .unsupported: kLTDropUnsupported
    }
    return kLTOk
}

@_cdecl("lt_drop_ipsws")
public func lt_drop_ipsws(
    _ pathsJson: UnsafePointer<CChar>?,
    _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    guard let pathsJson, let out else { return kLTBadArgument }
    guard let paths = ltDecodeJSON(String(cString: pathsJson), as: [String].self) else {
        LTLastError.set("lt_drop_ipsws: invalid JSON")
        return kLTBadArgument
    }
    // Synchronous; Qt calls this off the UI thread for large drops.
    let urls = DroppedFiles.ipsws(in: paths.map { URL(fileURLWithPath: $0) })
    guard let json = ltEncodeJSON(urls.map { $0.path }) else { return kLTFailed }
    out.pointee = ltCopyCString(json).map { UnsafePointer($0) }
    return kLTOk
}

private nonisolated(unsafe) var dropRequestId: UInt64 = 0
private let dropRequestLock = NSLock()

@_cdecl("lt_drop_route")
public func lt_drop_route(
    _ pathsJson: UnsafePointer<CChar>?,
    _ target: UnsafePointer<CChar>?,
    _ requestIdOut: UnsafeMutablePointer<UInt64>?
) -> LTResult {
    guard let pathsJson, let target, let requestIdOut else { return kLTBadArgument }
    guard let core = appCore() else { return kLTFailed }
    guard let paths = ltDecodeJSON(String(cString: pathsJson), as: [String].self) else {
        LTLastError.set("lt_drop_route: invalid JSON")
        return kLTBadArgument
    }
    let targetStr = String(cString: target)
    let requestId = dropRequestLock.withLock { () -> UInt64 in
        dropRequestId += 1
        return dropRequestId
    }
    requestIdOut.pointee = requestId

    // Classify and route: IPSWs go to the catalog, IPAs/media to a device.
    let urls = paths.map { URL(fileURLWithPath: $0) }
    let kinds = urls.map { DroppedFiles($0) }
    let action: String
    let detail: DropDetailDTO
    if kinds.contains(.ipsw) {
        let ipsws = DroppedFiles.ipsws(in: urls)
        action = "import-ipsw"
        detail = DropDetailDTO(paths: ipsws.map { $0.path }, target: targetStr)
        Task { @MainActor in
            core.jobs.importIPSWs(ipsws)
        }
    } else if kinds.contains(.ipa) {
        action = "install-ipa"
        detail = DropDetailDTO(
            paths: urls.filter { DroppedFiles($0) == .ipa }.map { $0.path }, target: targetStr
        )
    } else if kinds.contains(.media) {
        action = "import-media"
        detail = DropDetailDTO(
            paths: urls.filter { DroppedFiles($0) == .media }.map { $0.path }, target: targetStr
        )
    } else {
        action = "unsupported"
        detail = DropDetailDTO(paths: paths, target: targetStr)
    }
    let detailJson: String = {
        guard let data = ltEncodeJSON(detail), let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }()
    EventPump.shared.post(kind: kLTEventDropAction) { e in
        e.u.dropAction.requestId = requestId
        e.u.dropAction.action = ltCopyCString(action)
        e.u.dropAction.detailJson = ltCopyCString(detailJson)
    }
    return kLTOk
}

/// The `detailJson` of a `kLTEventDropAction` (ui/ABI.md §2).
private struct DropDetailDTO: Encodable {
    var paths: [String]
    var target: String
}
