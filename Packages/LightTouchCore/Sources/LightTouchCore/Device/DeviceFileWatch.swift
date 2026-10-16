// Notices a running device's files being pulled out from under its helper:
// base/, overlay/ and the overlay's files (the pages and NOR QEMU has open)
// deleted, renamed or replaced. Only what the guest owns: never Devices/<uuid>
// itself, where the app rewrites device.plist, web-proxy.*, work/ and IPAs/ while
// the device runs (those fired the notice on every boot and proxy toggle). The
// helper keeps running on the unlinked inodes and the guest never notices; the
// app says so, and Stop skips flushing into a dead inode. Foundation only:
// tests/drivers/helper-driver compiles it.
//
// macOS watches with kqueue vnode sources; Linux with inotify
// (see FileEventWatch.swift).

import Foundation

public nonisolated final class DeviceFileWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LightTouch.files")
    private let watch: FileEventWatch

    /// What the notice says once anything under the device moved.
    public static func notice(shortName: String) -> String {
        "Files of this \(shortName) were changed while it was running. Shut it down and start it again; unsaved changes may be lost."
    }

    /// `directories` and each of their direct children, and `files` (a NOR kept
    /// outside the overlay), are watched for delete, rename and revoke; `base`
    /// also for writes (nothing may add or remove an entry there).
    /// `onChange(path)` once per event, on a private queue.
    public init(directories: [URL], files: [URL] = [], base: URL?, onChange: @escaping @Sendable (String) -> Void) {
        let fm = FileManager.default
        var watched: [(path: String, events: FileWatchEvent)] = (directories + files).map {
            ($0.path, [.delete, .rename, .revoke])
        }
        for directory in directories {
            for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where !name.hasPrefix(".") {
                watched.append((directory.appendingPathComponent(name).path, [.delete, .rename, .revoke]))
            }
        }
        if let base { watched.append((base.path, [.delete, .rename, .revoke, .write])) }
        watch = FileEventWatch(paths: watched, queue: queue, onEvent: onChange)
    }

    public var count: Int { watch.count }

    deinit { watch.cancel() }
}
