/// Device library & rows exports (ui/ABI.md §3.2).
import Foundation
import LTBridgeC
import LightTouchCore

// MARK: - Queries (snapshots)

// ui/ABI.md §4.2: a query reads a snapshot — lock, copy, return. It never
// hops to @MainActor. A missing snapshot (core still starting) is kLTNotReady.
func querySnapshot(
    _ key: String, what: String, out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    guard let out else {
        LTLastError.set("\(what): null out")
        return kLTBadArgument
    }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard let data = SnapshotStore.shared.global(key) else {
        LTLastError.set("\(what): snapshot not ready")
        return kLTNotReady
    }
    out.pointee = ltCopyCString(data).map { UnsafePointer($0) }
    return out.pointee == nil ? kLTFailed : kLTOk
}

func queryDeviceSnapshot(
    _ device: lt_device_t, _ key: String, what: String,
    out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    guard let out else {
        LTLastError.set("\(what): null out")
        return kLTBadArgument
    }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard HandleRegistry.shared.uuid(for: device) != nil else { return kLTNoSuchDevice }
    guard let data = SnapshotStore.shared.device(device, key: key) else {
        LTLastError.set("\(what): snapshot not ready")
        return kLTNotReady
    }
    out.pointee = ltCopyCString(data).map { UnsafePointer($0) }
    return out.pointee == nil ? kLTFailed : kLTOk
}

@_cdecl("lt_device_list")
public func lt_device_list(_ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> LTResult {
    querySnapshot("deviceList", what: "lt_device_list", out: out)
}

@_cdecl("lt_device_find")
public func lt_device_find(
    _ uuid: UnsafePointer<CChar>?, _ out: UnsafeMutablePointer<lt_device_t>?
) -> LTResult {
    guard let uuidStr = ltTakeString(uuid, what: "lt_device_find: uuid") else { return kLTBadArgument }
    guard let out else {
        LTLastError.set("lt_device_find: null out")
        return kLTBadArgument
    }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard let id = UUID(uuidString: uuidStr) else {
        LTLastError.set("lt_device_find: malformed UUID")
        return kLTBadArgument
    }
    guard let handle = HandleRegistry.shared.handle(for: id) else { return kLTNoSuchDevice }
    out.pointee = handle
    return kLTOk
}

@_cdecl("lt_device_uuid")
public func lt_device_uuid(
    _ device: lt_device_t, _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    guard let out else {
        LTLastError.set("lt_device_uuid: null out")
        return kLTBadArgument
    }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard let uuid = HandleRegistry.shared.uuid(for: device) else { return kLTNoSuchDevice }
    out.pointee = ltCopyCString(uuid.uuidString.lowercased()).map { UnsafePointer($0) }
    return out.pointee == nil ? kLTFailed : kLTOk
}

@_cdecl("lt_device_row")
public func lt_device_row(
    _ device: lt_device_t, _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    queryDeviceSnapshot(device, "row", what: "lt_device_row", out: out)
}

@_cdecl("lt_storage_busy")
public func lt_storage_busy(_ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> LTResult {
    querySnapshot("storageBusy", what: "lt_storage_busy", out: out)
}

@_cdecl("lt_sidebar_list")
public func lt_sidebar_list(_ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> LTResult {
    querySnapshot("sidebarList", what: "lt_sidebar_list", out: out)
}

// MARK: - Commands

@_cdecl("lt_device_create")
public func lt_device_create(
    _ entryId: UnsafePointer<CChar>?, _ name: UnsafePointer<CChar>?,
    _ out: UnsafeMutablePointer<lt_device_t>?
) -> LTResult {
    guard let entryIdStr = ltTakeString(entryId, what: "lt_device_create: entryId") else { return kLTBadArgument }
    guard let nameStr = ltTakeString(name, what: "lt_device_create: name") else { return kLTBadArgument }
    guard let out else {
        LTLastError.set("lt_device_create: null out")
        return kLTBadArgument
    }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard !nameStr.isEmpty else {
        LTLastError.set("lt_device_create: empty name")
        return kLTBadArgument
    }
    // The handle is minted synchronously (the row exists immediately);
    // storage preparation is enqueued on @MainActor.
    let handleBox = LTBox<lt_device_t>()
    let failureBox = LTBox<String>()
    let done = LTBox<Bool>(false)
    Task { @MainActor in
        defer { done.value = true }
        guard let core = appCore() else { failureBox.value = "The core isn’t initialized."; return }
        guard let entry = core.catalog.entry(id: entryIdStr) else {
            failureBox.value = "Unknown catalog entry “\(entryIdStr)”."
            return
        }
        let id = UUID()
        let relative = "Devices/\(id.uuidString)"
        let instance = DeviceInstance(
            id: id,
            name: nameStr,
            board: entry.board,
            firmware: entry.id,
            created: Date(),
            base: .init(kind: .prepared, path: "\(relative)/base"),
            storage: .init(
                key: "",
                overlay: "\(relative)/overlay",
                snapshot: "\(relative)/snapshot",
                usbmuxConf: "\(relative)/usbmuxd-conf"
            )
        )
        do {
            try core.library.save(instance)
        } catch {
            failureBox.value = "Couldn’t create the device: \(error.localizedDescription)"
            return
        }
        handleBox.value = HandleRegistry.shared.register(id)
        // The firmware behind the new device prepares as a job (the Add-device
        // flow); the row shows its progress until the base is ready.
        core.jobs.downloadAndPrepare(entry)
        core.refreshLibrarySnapshots()
        EventPump.shared.postDeviceListChanged()
    }
    let deadline = Date().addingTimeInterval(10)
    while done.value != true, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    if let failure = failureBox.value {
        LTLastError.set(failure)
        return kLTFailed
    }
    guard done.value == true, let handle = handleBox.value, handle != 0 else {
        LTLastError.set("lt_device_create: timed out")
        return kLTFailed
    }
    out.pointee = handle
    return kLTAccepted
}

// MARK: - Device mutation commands

@_cdecl("lt_device_delete")
public func lt_device_delete(_ device: lt_device_t) -> LTResult {
    guard let uuid = ltResolveDevice(device) else { return kLTNoSuchDevice }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    Task { @MainActor in
        guard let core = appCore() else { return }
        if core.session(for: uuid)?.isRunning == true || core.session(for: uuid)?.state == .booting {
            postToast(
                title: "Can’t delete the device",
                body: "It’s running. Shut it down first.",
                category: "device-delete"
            )
            return
        }
        let lower = uuid.uuidString.lowercased()
        let stateDir = core.library.state
        do {
            try await core.storageWork.run(lower, as: .deleting) {
                if let session = core.session(for: uuid), !session.state.isDead, session.state != .notStarted {
                    // A stopped session still owns the tree; drop it.
                    core.dropSession(for: uuid)
                    return true
                }
                return true
            } _: {
                // Background thread: the record + device tree are just files.
                // (DeviceLibrary.remove is @MainActor; this is its file half,
                // DeviceStateStorage being nonisolated.)
                try DeviceStateStorage.removeDevice(uuid, state: stateDir)
            }
            await MainActor.run { core.library.reload() }
            HandleRegistry.shared.unregister(uuid)
            core.refreshLibrarySnapshots()
            EventPump.shared.postDeviceListChanged()
        } catch {
            postToast(title: "Couldn’t delete the device", body: error.localizedDescription, category: "device-delete")
        }
    }
    return kLTAccepted
}

@_cdecl("lt_device_rename")
public func lt_device_rename(_ device: lt_device_t, _ name: UnsafePointer<CChar>?) -> LTResult {
    guard let uuid = ltResolveDevice(device) else { return kLTNoSuchDevice }
    guard let nameStr = ltTakeString(name, what: "lt_device_rename: name") else { return kLTBadArgument }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard !nameStr.isEmpty else {
        LTLastError.set("lt_device_rename: empty name")
        return kLTBadArgument
    }
    Task { @MainActor in
        guard let core = appCore(), var instance = core.library.instance(id: uuid) else { return }
        instance.name = nameStr
        do {
            try core.library.save(instance)
        } catch {
            postToast(title: "Couldn’t rename the device", body: error.localizedDescription, category: "device-rename")
            return
        }
        core.refreshLibrarySnapshots()
        EventPump.shared.postDeviceListChanged()
    }
    return kLTAccepted
}

@_cdecl("lt_device_duplicate")
public func lt_device_duplicate(
    _ device: lt_device_t, _ out: UnsafeMutablePointer<lt_device_t>?
) -> LTResult {
    guard let uuid = ltResolveDevice(device) else { return kLTNoSuchDevice }
    guard let out else {
        LTLastError.set("lt_device_duplicate: null out")
        return kLTBadArgument
    }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    // Like lt_device_create, the handle is returned synchronously: the
    // directory copy happens on @MainActor with a bounded pump.
    let handleBox = LTBox<lt_device_t>()
    let failureBox = LTBox<String>()
    let done = LTBox<Bool>(false)
    Task { @MainActor in
        defer { done.value = true }
        guard let core = appCore() else { failureBox.value = "The core isn’t initialized."; return }
        guard let source = core.library.instance(id: uuid) else {
            failureBox.value = "Device not found."
            return
        }
        if core.session(for: uuid)?.isRunning == true {
            failureBox.value = "Shut the device down before duplicating it."
            return
        }
        let newId = UUID()
        let oldPrefix = "Devices/\(uuid.uuidString)"
        let newPrefix = "Devices/\(newId.uuidString)"
        func remap(_ path: String) -> String {
            path.hasPrefix(oldPrefix) ? newPrefix + path.dropFirst(oldPrefix.count) : path
        }
        var newStorage = source.storage
        newStorage.overlay = remap(source.storage.overlay)
        newStorage.writableNOR = source.storage.writableNOR.map(remap)
        newStorage.snapshot = remap(source.storage.snapshot)
        newStorage.usbmuxConf = remap(source.storage.usbmuxConf)
        var newBase = source.base
        newBase.path = remap(source.base.path)
        // id is immutable; build the copy through the public init.
        let copy = DeviceInstance(
            format: source.format,
            id: newId,
            name: "\(source.name) copy",
            board: source.board,
            firmware: source.firmware,
            created: Date(),
            base: newBase,
            storage: newStorage,
            identity: nil,
            provenance: source.provenance,
            guest: nil,
            panel: source.panel
        )
        let fm = FileManager.default
        let oldDir = core.directories.stateDir.appendingPathComponent(oldPrefix, isDirectory: true)
        let newDir = core.directories.stateDir.appendingPathComponent(newPrefix, isDirectory: true)
        do {
            if fm.fileExists(atPath: oldDir.path) {
                try fm.copyItem(at: oldDir, to: newDir)
            }
            try core.library.save(copy)
        } catch {
            try? fm.removeItem(at: newDir)
            failureBox.value = "Couldn’t duplicate the device: \(error.localizedDescription)"
            return
        }
        handleBox.value = HandleRegistry.shared.register(newId)
        core.refreshLibrarySnapshots()
        EventPump.shared.postDeviceListChanged()
    }
    let deadline = Date().addingTimeInterval(30)
    while done.value != true, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    if let failure = failureBox.value {
        LTLastError.set(failure)
        return kLTFailed
    }
    guard done.value == true, let handle = handleBox.value, handle != 0 else {
        LTLastError.set("lt_device_duplicate: timed out")
        return kLTFailed
    }
    out.pointee = handle
    return kLTAccepted
}

@_cdecl("lt_device_erase")
public func lt_device_erase(_ device: lt_device_t) -> LTResult {
    guard let uuid = ltResolveDevice(device) else { return kLTNoSuchDevice }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    Task { @MainActor in
        guard let core = appCore() else { return }
        let session = core.session(for: uuid)
        let lower = uuid.uuidString.lowercased()
        guard await core.storageWork.claim(lower, as: .erasing, release: {
            if let session, session.isRunning || session.state == .booting { return false }
            return true
        }) else {
            postToast(
                title: "Can’t erase the device",
                body: "Its storage is busy.",
                category: "device-erase"
            )
            return
        }
        session?.eraser.request()
        // The busy entry clears when the erase completes: poll the session's
        // isErasing from the session poll (DeviceSession+Poll refreshEraseBusy).
    }
    return kLTAccepted
}

// MARK: - Sidebar commands

@_cdecl("lt_sidebar_add")
public func lt_sidebar_add(_ idsJson: UnsafePointer<CChar>?) -> LTResult {
    guard let jsonStr = ltTakeString(idsJson, what: "lt_sidebar_add: idsJson") else { return kLTBadArgument }
    guard let ids = ltDecodeJSON(jsonStr, as: [String].self), !ids.isEmpty else {
        LTLastError.set("lt_sidebar_add: idsJson must be a non-empty JSON array of entry ids")
        return kLTBadArgument
    }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    let failureBox = LTBox<String>()
    let done = LTBox<Bool>(false)
    Task { @MainActor in
        defer { done.value = true }
        guard let core = appCore() else { failureBox.value = "The core isn’t initialized."; return }
        core.sidebar.add(ids)
        core.sidebar.save(core.prefs)
        core.refreshLibrarySnapshots()
        EventPump.shared.post(kind: kLTEventSidebarChanged)
    }
    let deadline = Date().addingTimeInterval(5)
    while done.value != true, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    if let failure = failureBox.value {
        LTLastError.set(failure)
        return kLTFailed
    }
    guard done.value == true else {
        LTLastError.set("lt_sidebar_add: timed out")
        return kLTFailed
    }
    return kLTAccepted
}

@_cdecl("lt_sidebar_remove")
public func lt_sidebar_remove(_ id: UnsafePointer<CChar>?) -> LTResult {
    guard let idStr = ltTakeString(id, what: "lt_sidebar_remove: id") else { return kLTBadArgument }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    Task { @MainActor in
        guard let core = appCore() else { return }
        core.sidebar.remove(idStr)
        core.sidebar.save(core.prefs)
        core.refreshLibrarySnapshots()
    }
    return kLTAccepted
}

@_cdecl("lt_sidebar_rename")
public func lt_sidebar_rename(_ id: UnsafePointer<CChar>?, _ title: UnsafePointer<CChar>?) -> LTResult {
    guard let idStr = ltTakeString(id, what: "lt_sidebar_rename: id") else { return kLTBadArgument }
    guard let titleStr = ltTakeString(title, what: "lt_sidebar_rename: title") else { return kLTBadArgument }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    Task { @MainActor in
        guard let core = appCore() else { return }
        core.sidebar.rename(idStr, to: titleStr, defaultTitle: "")
        core.sidebar.save(core.prefs)
        core.refreshLibrarySnapshots()
    }
    return kLTAccepted
}
