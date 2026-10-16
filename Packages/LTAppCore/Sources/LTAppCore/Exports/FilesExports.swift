/// Files browser exports (ui/ABI.md §3.7).
///
/// Fronts FilesConnection + DeviceServices file APIs. Transfers run as
/// cancellable Tasks tracked by id; progress and completion post events.
import Foundation
import LTBridgeC
import HostServiceWire
import HostServiceClient
import LightTouchCore

/// A file transfer's state, for lt_files_transfer / lt_files_cancel.
final class LTFileTransfer: @unchecked Sendable {
    let id: UInt64
    let device: lt_device_t
    var task: Task<Void, Never>?
    private let lock = NSLock()
    nonisolated(unsafe) private var _cancelled = false
    var cancelled: Bool {
        get { lock.withLock { _cancelled } }
        set { lock.withLock { _cancelled = newValue } }
    }
    init(id: UInt64, device: lt_device_t) {
        self.id = id
        self.device = device
    }
}

/// The transfer registry (the LTFilesAdapter's transfer side).
enum LTFileTransfers {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var nextId: UInt64 = 1
    nonisolated(unsafe) private static var transfers: [UInt64: LTFileTransfer] = [:]
    nonisolated(unsafe) private static var nextRequestId: UInt64 = 1

    static func mintTransferId() -> UInt64 {
        lock.withLock {
            let id = nextId
            nextId &+= 1
            return id
        }
    }

    static func mintRequestId() -> UInt64 {
        lock.withLock {
            let id = nextRequestId
            nextRequestId &+= 1
            return id
        }
    }

    static func add(_ transfer: LTFileTransfer) {
        lock.withLock { transfers[transfer.id] = transfer }
    }

    static func get(_ id: UInt64) -> LTFileTransfer? {
        lock.withLock { transfers[id] }
    }

    static func remove(_ id: UInt64) {
        lock.withLock { transfers[id] = nil }
    }

    static func cancel(_ id: UInt64) -> Bool {
        lock.withLock {
            guard let transfer = transfers[id] else { return false }
            transfer.cancelled = true
            transfer.task?.cancel()
            return true
        }
    }
}

@_cdecl("lt_files_follow")
public func lt_files_follow(_ device: lt_device_t, _ follow: Int32) -> LTResult {
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard let uuid = ltResolveDevice(device) else { return kLTNoSuchDevice }
    Task { @MainActor in
        guard let core = appCore(), let session = core.fastSession(for: uuid) else { return }
        let changed: Bool
        if follow != 0 {
            let endpoint = try? session.apps.filesEndpoint
            changed = FilesConnection.shared.follow(
                device: uuid, endpoint: endpoint, reachable: session.canReachDevice ? true : nil
            )
        } else {
            changed = FilesConnection.shared.follow(device: nil, endpoint: nil, reachable: false)
        }
        if changed {
            EventPump.shared.post(kind: kLTEventFilesConnectionChanged) { _ in }
        }
    }
    return kLTAccepted
}

@_cdecl("lt_files_state")
public func lt_files_state(_ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> LTResult {
    guard let out else {
        LTLastError.set("lt_files_state: null out")
        return kLTBadArgument
    }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    struct State: Codable {
        var state: String
        var device: String?
    }
    let state: State
    switch FilesConnection.shared.state {
    case .disconnected:
        state = State(state: "disconnected", device: nil)
    case .connected(let binding):
        state = State(state: "connected", device: binding.device.uuidString.lowercased())
    case .transferring(let binding):
        state = State(state: "transferring", device: binding.device.uuidString.lowercased())
    }
    guard let data = ltEncodeJSON(state) else {
        LTLastError.set("lt_files_state: encoding failed")
        return kLTFailed
    }
    out.pointee = ltCopyCString(data).map { UnsafePointer($0) }
    return out.pointee == nil ? kLTFailed : kLTOk
}

@_cdecl("lt_files_list")
public func lt_files_list(
    _ device: lt_device_t, _ path: UnsafePointer<CChar>?,
    _ requestIdOut: UnsafeMutablePointer<UInt64>?
) -> LTResult {
    guard let pathStr = ltTakeString(path, what: "lt_files_list: path") else { return kLTBadArgument }
    guard let requestIdOut else {
        LTLastError.set("lt_files_list: null requestIdOut")
        return kLTBadArgument
    }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard let uuid = ltResolveDevice(device) else { return kLTNoSuchDevice }
    let requestId = LTFileTransfers.mintRequestId()
    requestIdOut.pointee = requestId
    Task { @MainActor in
        guard let core = appCore(), let session = core.fastSession(for: uuid) else { return }
        let handle = device
        Task {
            do {
                let services = try session.apps.services
                let entries = try await services.files(in: pathStr)
                let json = (try? JSONEncoder().encode(entries)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                await MainActor.run {
                    EventPump.shared.post(kind: kLTEventFilesListed, device: handle) { e in
                        e.u.filesListed.requestId = requestId
                        e.u.filesListed.entriesJson = ltCopyCString(json)
                    }
                }
            } catch {
                await MainActor.run {
                    EventPump.shared.post(kind: kLTEventFilesListed, device: handle) { e in
                        e.u.filesListed.requestId = requestId
                        e.u.filesListed.entriesJson = ltCopyCString("[]")
                    }
                    postToast(
                        title: "Couldn’t list files",
                        body: error.localizedDescription,
                        category: "files"
                    )
                }
            }
        }
    }
    return kLTAccepted
}

/// lt_files_transfer: opJson = {op: upload|download|delete|move|mkdir, src, dst}.
/// File transfer operation (lt_files_transfer opJson).
private struct FileOpDTO: Codable {
    var op: String
    var src: String
    var dst: String?
}

@_cdecl("lt_files_transfer")
public func lt_files_transfer(
    _ device: lt_device_t, _ opJson: UnsafePointer<CChar>?,
    _ transferIdOut: UnsafeMutablePointer<UInt64>?
) -> LTResult {
    guard let jsonStr = ltTakeString(opJson, what: "lt_files_transfer: opJson") else { return kLTBadArgument }
    guard let transferIdOut else {
        LTLastError.set("lt_files_transfer: null transferIdOut")
        return kLTBadArgument
    }
    guard let op = ltDecodeJSON(jsonStr, as: FileOpDTO.self) else {
        LTLastError.set("lt_files_transfer: opJson must be {op, src, dst?}")
        return kLTBadArgument
    }
    guard ["upload", "download", "delete", "move", "mkdir"].contains(op.op) else {
        LTLastError.set("lt_files_transfer: unknown op “\(op.op)”")
        return kLTBadArgument
    }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard let uuid = ltResolveDevice(device) else { return kLTNoSuchDevice }
    let transferId = LTFileTransfers.mintTransferId()
    transferIdOut.pointee = transferId
    let transfer = LTFileTransfer(id: transferId, device: device)
    LTFileTransfers.add(transfer)
    Task { @MainActor in
        await runFileTransfer(transferId: transferId, device: device, uuid: uuid, op: op)
    }
    return kLTAccepted
}

/// Runs a file transfer on @MainActor (DeviceServices is @MainActor).
@MainActor
private func runFileTransfer(transferId: UInt64, device: lt_device_t, uuid: UUID, op: FileOpDTO) async {
    guard let core = appCore(), let session = core.session(for: uuid) else {
        LTFileTransfers.remove(transferId)
        return
    }
    guard let transfer = LTFileTransfers.get(transferId) else { return }
    let handle = device
    FilesConnection.shared.setTransferring(true)
    EventPump.shared.post(kind: kLTEventFilesConnectionChanged) { _ in }
    let done = await LTFileTransfers.runTransfer(op: (op.op, op.src, op.dst), session: session, transfer: transfer, handle: handle)
    FilesConnection.shared.setTransferring(false)
    EventPump.shared.post(kind: kLTEventFilesConnectionChanged) { _ in }
    EventPump.shared.post(kind: kLTEventFilesDone, device: handle) { e in
        e.u.filesDone.transferId = transferId
        e.u.filesDone.ok = done.ok ? 1 : 0
        e.u.filesDone.cancelled = done.cancelled ? 1 : 0
        e.u.filesDone.message = done.message.map(ltCopyCString) ?? nil
    }
    LTFileTransfers.remove(transferId)
}

extension LTFileTransfers {
    struct TransferResult { var ok: Bool; var cancelled: Bool; var message: String? }

    static func runTransfer(
        op: (op: String, src: String, dst: String?), session: DeviceSession,
        transfer: LTFileTransfer, handle: lt_device_t
    ) async -> TransferResult {
        do {
            let services = try await MainActor.run { try session.apps.services }
            switch op.op {
            case "upload":
                guard let dst = op.dst else {
                    return TransferResult(ok: false, cancelled: false, message: "upload needs dst")
                }
                try await services.uploadFile(
                    URL(fileURLWithPath: op.src), into: dst
                ) { fraction in
                    postTransferProgress(transfer: transfer, handle: handle, fraction: fraction, file: op.src)
                }
            case "download":
                guard let dst = op.dst else {
                    return TransferResult(ok: false, cancelled: false, message: "download needs dst")
                }
                // src is the device path; find the DeviceFile entry first.
                let dir = (op.src as NSString).deletingLastPathComponent
                let name = (op.src as NSString).lastPathComponent
                let entries = try await services.files(in: dir.isEmpty ? "" : dir)
                guard let entry = entries.first(where: { $0.name == name }) else {
                    return TransferResult(ok: false, cancelled: false, message: "file not found")
                }
                try await services.download(entry, to: URL(fileURLWithPath: dst)) { fraction in
                    postTransferProgress(transfer: transfer, handle: handle, fraction: fraction, file: op.src)
                }
            case "delete":
                try await services.delete(op.src)
            case "move":
                guard let dst = op.dst else {
                    return TransferResult(ok: false, cancelled: false, message: "move needs dst")
                }
                let name = (dst as NSString).lastPathComponent
                try await services.rename(op.src, to: name)
            case "mkdir":
                try await services.makeFolder(op.src)
            default:
                return TransferResult(ok: false, cancelled: false, message: "unknown op")
            }
            try Task.checkCancellation()
            return TransferResult(ok: true, cancelled: false, message: nil)
        } catch is CancellationError {
            return TransferResult(ok: false, cancelled: true, message: nil)
        } catch {
            let cancelled = transfer.cancelled || (error is CancellationError)
            return TransferResult(ok: false, cancelled: cancelled, message: error.localizedDescription)
        }
    }

    static func postTransferProgress(
        transfer: LTFileTransfer, handle: lt_device_t, fraction: Double, file: String
    ) {
        let transferId = transfer.id
        Task { @MainActor in
            EventPump.shared.post(kind: kLTEventFilesProgress, device: handle) { e in
                e.u.filesProgress.transferId = transferId
                e.u.filesProgress.fraction = fraction
                e.u.filesProgress.currentFile = ltCopyCString(file)
                e.u.filesProgress.bytesDone = -1
                e.u.filesProgress.bytesTotal = -1
            }
        }
    }
}

@_cdecl("lt_files_cancel")
public func lt_files_cancel(_ transferId: UInt64) -> LTResult {
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard LTFileTransfers.cancel(transferId) else {
        LTLastError.set("lt_files_cancel: unknown transfer \(transferId)")
        return kLTBadArgument
    }
    return kLTAccepted
}
