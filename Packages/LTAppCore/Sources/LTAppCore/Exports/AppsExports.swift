/// Apps inspector exports (ui/ABI.md §3.6).
import Foundation
import LTBridgeC
import LightTouchCore

@_cdecl("lt_apps_list")
public func lt_apps_list(
    _ device: lt_device_t, _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    queryDeviceSnapshot(device, "apps", what: "lt_apps_list", out: out)
}

/// lt_apps_refresh: re-reads the device; emits kLTEventAppsChanged.
@_cdecl("lt_apps_refresh")
public func lt_apps_refresh(_ device: lt_device_t) -> LTResult {
    withSession(device, what: "lt_apps_refresh") { core, session in
        Task {
            // The installed-apps read goes through the guest services; a
            // refresh is a fresh list + snapshot.
            await session.refreshAppsList()
            let session = session
            await MainActor.run {
                guard let core = appCore(), let handle = core.handle(for: session.instance.id) else { return }
                core.refreshAppsSnapshot(session: session, handle: handle)
                EventPump.shared.post(kind: kLTEventAppsChanged, device: handle)
            }
        }
    }
}

/// lt_apps_install: DeviceApps.install; progress via kLTEventInstallProgress,
/// outcome via kLTEventInstallDone.
@_cdecl("lt_apps_install")
public func lt_apps_install(
    _ device: lt_device_t, _ ipaPath: UnsafePointer<CChar>?
) -> LTResult {
    guard let pathStr = ltTakeString(ipaPath, what: "lt_apps_install: ipaPath") else { return kLTBadArgument }
    guard !pathStr.isEmpty else {
        LTLastError.set("lt_apps_install: empty ipaPath")
        return kLTBadArgument
    }
    let url = URL(fileURLWithPath: pathStr)
    guard url.pathExtension.lowercased() == "ipa" else {
        LTLastError.set("lt_apps_install: not an .ipa path")
        return kLTBadArgument
    }
    return withSession(device, what: "lt_apps_install") { core, session in
        guard let handle = core.handle(for: session.instance.id) else { return }
        Task {
            do {
                let bundleID = try await session.apps.install(url) { progress in
                    // Progress strings ("…MB of …MB"); the event carries them.
                    let handle = handle
                    Task { @MainActor in
                        EventPump.shared.post(kind: kLTEventInstallProgress, device: handle) { e in
                            e.u.installProgress.bundleId = ltCopyCString("")
                            e.u.installProgress.fraction = -1
                            e.u.installProgress.stage = ltCopyCString(progress)
                        }
                    }
                }
                await MainActor.run {
                    EventPump.shared.post(kind: kLTEventInstallDone, device: handle) { e in
                        e.u.installDone.bundleId = ltCopyCString(bundleID)
                        e.u.installDone.ok = 1
                        e.u.installDone.message = nil
                    }
                    if let core = appCore(), let session = core.fastSession(for: session.instance.id) {
                        core.refreshAppsSnapshot(session: session, handle: handle)
                    }
                    EventPump.shared.post(kind: kLTEventAppsChanged, device: handle)
                }
            } catch {
                await MainActor.run {
                    EventPump.shared.post(kind: kLTEventInstallDone, device: handle) { e in
                        e.u.installDone.bundleId = ltCopyCString("")
                        e.u.installDone.ok = 0
                        e.u.installDone.message = ltCopyCString(error.localizedDescription)
                    }
                }
            }
        }
    }
}

/// lt_apps_remove: uninstall via the device services.
@_cdecl("lt_apps_remove")
public func lt_apps_remove(
    _ device: lt_device_t, _ bundleId: UnsafePointer<CChar>?
) -> LTResult {
    guard let bundleIdStr = ltTakeString(bundleId, what: "lt_apps_remove: bundleId") else { return kLTBadArgument }
    guard !bundleIdStr.isEmpty else {
        LTLastError.set("lt_apps_remove: empty bundleId")
        return kLTBadArgument
    }
    return withSession(device, what: "lt_apps_remove") { core, session in
        guard let handle = core.handle(for: session.instance.id) else { return }
        Task {
            do {
                try await session.apps.services.uninstall(bundleIdStr)
                await MainActor.run {
                    if let core = appCore(), let session = core.fastSession(for: session.instance.id) {
                        core.refreshAppsSnapshot(session: session, handle: handle)
                    }
                    EventPump.shared.post(kind: kLTEventAppsChanged, device: handle)
                }
            } catch {
                await MainActor.run {
                    postToast(
                        title: "Couldn’t remove the app",
                        body: error.localizedDescription,
                        category: "apps"
                    )
                }
            }
        }
    }
}

/// lt_apps_cancel_install: dequeues a queued install.
@_cdecl("lt_apps_cancel_install")
public func lt_apps_cancel_install(
    _ device: lt_device_t, _ bundleId: UnsafePointer<CChar>?
) -> LTResult {
    guard let bundleIdStr = ltTakeString(bundleId, what: "lt_apps_cancel_install: bundleId") else {
        return kLTBadArgument
    }
    guard let uuid = ltResolveDevice(device) else { return kLTNoSuchDevice }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    Task { @MainActor in
        AppInstaller.cancel(deviceID: uuid, bundleID: bundleIdStr)
    }
    return kLTAccepted
}

/// lt_apps_restart_springboard: DeviceApps.restartSpringBoard().
@_cdecl("lt_apps_restart_springboard")
public func lt_apps_restart_springboard(_ device: lt_device_t) -> LTResult {
    withSession(device, what: "lt_apps_restart_springboard") { _, session in
        Task {
            do {
                try await session.apps.restartSpringBoard()
            } catch {
                await MainActor.run {
                    postToast(
                        title: "Couldn’t restart SpringBoard",
                        body: error.localizedDescription,
                        category: "apps"
                    )
                }
            }
        }
    }
}

/// lt_apps_import_media: DeviceApps.importMedia over PreparedMedia.
@_cdecl("lt_apps_import_media")
public func lt_apps_import_media(
    _ device: lt_device_t, _ pathsJson: UnsafePointer<CChar>?
) -> LTResult {
    guard let jsonStr = ltTakeString(pathsJson, what: "lt_apps_import_media: pathsJson") else {
        return kLTBadArgument
    }
    guard let paths = ltDecodeJSON(jsonStr, as: [String].self), !paths.isEmpty else {
        LTLastError.set("lt_apps_import_media: pathsJson must be a non-empty JSON array of paths")
        return kLTBadArgument
    }
    return withSession(device, what: "lt_apps_import_media") { core, session in
        guard let handle = core.handle(for: session.instance.id) else { return }
        Task {
            do {
                for path in paths {
                    let media = try await PreparedMedia.prepare(
                        URL(fileURLWithPath: path), profile: session.profile
                    )
                    try await session.apps.importMedia(
                        media,
                        progress: { fraction in
                            Task { @MainActor in
                                EventPump.shared.post(kind: kLTEventInstallProgress, device: handle) { e in
                                    e.u.installProgress.bundleId = ltCopyCString("")
                                    e.u.installProgress.fraction = fraction
                                    e.u.installProgress.stage = ltCopyCString(media.title)
                                }
                            }
                        },
                        willCommit: {}
                    )
                }
                await MainActor.run {
                    EventPump.shared.post(kind: kLTEventAppsChanged, device: handle)
                }
            } catch {
                await MainActor.run {
                    postToast(
                        title: "Couldn’t import media",
                        body: error.localizedDescription,
                        category: "apps"
                    )
                }
            }
        }
    }
}

/// lt_apps_store_search: the Legacy Store catalog search (CatalogClient,
/// portable). Runs synchronously with a bounded timeout — Qt calls it off the
/// UI thread.
@_cdecl("lt_apps_store_search")
public func lt_apps_store_search(
    _ device: lt_device_t, _ query: UnsafePointer<CChar>?,
    _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    guard let out else {
        LTLastError.set("lt_apps_store_search: null out")
        return kLTBadArgument
    }
    guard let queryStr = ltTakeString(query, what: "lt_apps_store_search: query") else { return kLTBadArgument }
    guard ltIsInitialized(), !ltIsShutDown() else { return kLTNotReady }
    guard let uuid = ltResolveDevice(device) else { return kLTNoSuchDevice }
    // Device/os for the server's compatibility verdict, read off @MainActor.
    let paramsBox = LTBox<(device: String, os: String)>()
    let paramsDone = LTBox<Bool>(false)
    Task { @MainActor in
        defer { paramsDone.value = true }
        guard let core = appCore(), let session = core.fastSession(for: uuid) else { return }
        paramsBox.value = (session.profile.rawValue, session.firmwareVersion)
    }
    let deadline = Date().addingTimeInterval(5)
    while paramsDone.value != true, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let params = paramsBox.value ?? ("unknown", "3.1.3")
    // Synchronous search, bounded: Qt calls this off the UI thread.
    let resultBox = LTBox<[CatalogApp]>()
    let errorBox = LTBox<String>()
    let done = LTBox<Bool>(false)
    Task {
        defer { done.value = true }
        do {
            resultBox.value = try await CatalogClient.search(queryStr, device: params.device, os: params.os)
        } catch {
            errorBox.value = error.localizedDescription
        }
    }
    let searchDeadline = Date().addingTimeInterval(20)
    while done.value != true, Date() < searchDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    if let error = errorBox.value {
        LTLastError.set("lt_apps_store_search: \(error)")
        return kLTFailed
    }
    guard done.value == true, let apps = resultBox.value else {
        LTLastError.set("lt_apps_store_search: timed out")
        return kLTFailed
    }
    guard let data = ltEncodeJSON(apps) else {
        LTLastError.set("lt_apps_store_search: encoding failed")
        return kLTFailed
    }
    out.pointee = ltCopyCString(data).map { UnsafePointer($0) }
    return out.pointee == nil ? kLTFailed : kLTOk
}
