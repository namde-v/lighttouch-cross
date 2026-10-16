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
       let dto = ltDecodeJSON(CatalogFilterDTO.self, from: String(cString: filterJson)) {
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
    }.map { entry -> [String: Any] in
        [
            "id": entry.id,
            "board": entry.board,
            "productType": entry.productType,
            "marketingName": entry.marketingName,
            "version": entry.version,
            "build": entry.build,
            "status": "\(entry.status)",
            "statusNote": entry.statusNote as Any,
            "prereleaseBadge": entry.prereleaseBadge as Any,
            "media": entry.media,
            "released": entry.released as Any,
            "managesApps": entry.managesApps,
        ]
    }
    guard let json = ltEncodeJSON(entries) else { return kLTFailed }
    out.pointee = ltCopyCString(json).map { UnsafePointer($0) }
    return kLTOk
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
    let dto: [String: Any] = [
        "id": entry.id,
        "board": entry.board,
        "productType": entry.productType,
        "marketingName": entry.marketingName,
        "version": entry.version,
        "build": entry.build,
        "status": "\(entry.status)",
        "statusNote": entry.statusNote as Any,
        "keysPresent": !entry.keys.isEmpty,
        "hasRecipe": entry.recipe != nil,
        "offersJailbreak": FirmwareJobs.offersJailbreak(entry),
        "offersSkipSetup": FirmwareJobs.offersSkipSetup(entry),
        "managesApps": entry.managesApps,
        "media": entry.media,
    ]
    guard let json = ltEncodeJSON(dto) else { return kLTFailed }
    out.pointee = ltCopyCString(json).map { UnsafePointer($0) }
    return kLTOk
}

// MARK: - Jobs

@_cdecl("lt_jobs_list")
public func lt_jobs_list(_ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> LTResult {
    guard let out else { return kLTBadArgument }
    guard let core = appCore() else { return kLTFailed }
    // FirmwareJobs is @MainActor; snapshot on @MainActor.
    var jobsJson = "[]"
    let semaphore = DispatchSemaphore(value: 0)
    Task { @MainActor in
        let jobs = core.jobs.jobs.map { (entryId, job) -> [String: Any] in
            var d: [String: Any] = ["entryId": entryId]
            switch job {
            case .downloading(let fraction, let remaining, _, let mirror, _):
                d["kind"] = "download"
                d["progress"] = fraction
                d["remaining"] = remaining as Any
                d["mirror"] = mirror as Any
            case .preparing(let prep):
                d["kind"] = "prepare"
                d["progress"] = prep.bar as Any
            case .failed(let message):
                d["kind"] = "failed"
                d["failed"] = message
            }
            return d
        }
        jobsJson = ltEncodeJSON(jobs) ?? "[]"
        semaphore.signal()
    }
    semaphore.wait()
    out.pointee = ltCopyCString(jobsJson).map { UnsafePointer($0) }
    return kLTOk
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
    let opts = optionsJson.flatMap { ltDecodeJSON(JobOptionsDTO.self, from: String(cString: $0)) }
    Task { @MainActor in
        guard let entry = core.catalog.entry(id: id) else {
            LTLastError.set("lt_job_start: unknown entry '\(id)'")
            return
        }
        if let opts {
            if opts.jailbreak == true { core.jobs.jailbreaks.insert(id) }
            if opts.skipSetup == true { core.jobs.skipsSetup.insert(id) }
            if opts.keepStock == true { core.jobs.keepsStock.insert(id) }
        }
        core.jobs.downloadAndPrepare(entry)
    }
    return kLTOk
}

@_cdecl("lt_job_import_ipsw")
public func lt_job_import_ipsw(_ pathsJson: UnsafePointer<CChar>?) -> LTResult {
    guard let pathsJson else { return kLTBadArgument }
    guard let core = appCore() else { return kLTFailed }
    guard let paths = ltDecodeJSON([String].self, from: String(cString: pathsJson)) else {
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
    // FirmwareJobs is @MainActor; read on @MainActor.
    let semaphore = DispatchSemaphore(value: 0)
    var can = false
    var reason: String?
    Task { @MainActor in
        can = core.jobs.canDownload
        reason = core.jobs.unavailableReason
        semaphore.signal()
    }
    semaphore.wait()
    out.pointee = can ? 1 : 0
    if let reason {
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
    guard let paths = ltDecodeJSON([String].self, from: String(cString: pathsJson)) else {
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
    guard let paths = ltDecodeJSON([String].self, from: String(cString: pathsJson)) else {
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
    let detail: [String: Any]
    if kinds.contains(.ipsw) {
        let ipsws = DroppedFiles.ipsws(in: urls)
        action = "import-ipsw"
        detail = ["paths": ipsws.map { $0.path }, "target": targetStr]
        Task { @MainActor in
            core.jobs.importIPSWs(ipsws)
        }
    } else if kinds.contains(.ipa) {
        action = "install-ipa"
        detail = ["paths": urls.filter { DroppedFiles($0) == .ipa }.map { $0.path }, "target": targetStr]
    } else if kinds.contains(.media) {
        action = "import-media"
        detail = ["paths": urls.filter { DroppedFiles($0) == .media }.map { $0.path }, "target": targetStr]
    } else {
        action = "unsupported"
        detail = ["paths": paths, "target": targetStr]
    }
    let detailJson = ltEncodeJSON(detail) ?? "{}"
    EventPump.shared.post(kind: kLTEventDropAction) { e in
        e.u.dropAction.requestId = requestId
        e.u.dropAction.action = ltCopyCString(action)
        e.u.dropAction.detailJson = ltCopyCString(detailJson)
    }
    return kLTOk
}
