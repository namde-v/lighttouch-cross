// The devices in State/Devices, for the sidebar and the sessions it starts.
// Records are the files; this is a cache over them that says when it changes.
// It follows the files live: a device folder moved to the Trash or removed in
// Terminal leaves the list, and one put back returns (StateRootWatch).

import Foundation
import Observation

@MainActor @Observable
public final class DeviceLibrary {
    /// Posted on the main actor after `instances` changes. The object is the library.
    public static let didChangeNotification = Notification.Name("DeviceLibraryDidChange")

    public static let shared = DeviceLibrary(state: Bundled.stateDirectory)

    public let state: URL
    /// Oldest first.
    public private(set) var instances: [DeviceInstance]
    @ObservationIgnored private var watch: StateRootWatch?

    public init(state: URL) {
        self.state = state
        instances = DeviceInstance.all(state: state)
        watch = StateRootWatch(root: state) { [weak self] in self?.reload() }
    }

    public func instance(id: UUID) -> DeviceInstance? { instances.first { $0.id == id } }

    /// One per entry for now; the model allows more.
    public func instances(firmware: String) -> [DeviceInstance] { instances.filter { $0.firmware == firmware } }

    /// Writes the record atomically; also how an existing record is updated.
    public func save(_ instance: DeviceInstance) throws {
        try instance.write(state: state)
        reload()
    }

    /// Deletes Devices/<uuid> (the record and whatever the device keeps
    /// there), the read-only base included (DeviceStateStorage.removeDevice).
    public func remove(id: UUID) throws {
        defer { reload() }
        try DeviceStateStorage.removeDevice(id, state: state)
    }

    public func reload() {
        let current = DeviceInstance.all(state: state)
        guard current != instances else { return }
        instances = current
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

/// FSEvents on the state root, by path, so Devices/ (or the root) removed and
/// made again is still seen, and Finder's move to the Trash and Terminal's rm
/// both are, which a file presenter (coordinated writers only) and a vnode
/// source on Devices/ (lost with the directory) are not. The latency debounces
/// a burst into one reload. Only the root, Devices/ and each device folder's own
/// entries count: a running device's page writes deeper down, and Preparing/,
/// never reload the library (FirmwareJobs reloads it on publishing).
nonisolated final class StateRootWatch: @unchecked Sendable {
    private let root: String
    private let onChange: @MainActor () -> Void
    #if os(Linux)
    private let queue = DispatchQueue(label: "LightTouch.statewatch")
    private var watch: FileEventWatch?
    private var pending: DispatchWorkItem?
    private let latency: TimeInterval
    #elseif os(Windows)
    // No FSEvents/inotify on Windows, and FileEventWatch is a never-firing
    // stub there: the watcher is a no-op; the library reloads on demand.
    #else
    private var stream: FSEventStreamRef?
    #endif

    init(root: URL, latency: TimeInterval = 0.2, onChange: @escaping @MainActor () -> Void) {
        #if os(Windows)
        self.root = root.path
        #else
        // FSEvents reports real paths (/private/var/..., which resolvingSymlinksInPath would undo).
        if let real = realpath(root.path, nil) {
            self.root = String(cString: real)
            free(real)
        } else {
            self.root = root.path
        }
        #endif
        self.onChange = onChange
        #if os(Linux)
        self.latency = latency
        // inotify isn't recursive: watch the root, Devices/ and each device
        // folder's own entries — the same set `matters` admits on macOS.
        watch = makeWatch()
        #elseif os(Windows)
        // No-op (see above).
        #else
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watch = Unmanaged<StateRootWatch>.fromOpaque(info).takeUnretainedValue()
            let paths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            guard (0..<count).contains(where: { watch.matters(String(cString: paths[$0]), flags[$0]) }) else { return }
            MainActor.assumeIsolated { watch.onChange() }
        }
        guard
            let stream = FSEventStreamCreate(
                nil,
                callback,
                &context,
                [self.root] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
            )
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        #endif
    }

    #if os(Linux)
    /// The watched set: the root, Devices/ and each device folder's own
    /// entries, mirroring what `matters` admits on macOS.
    func watchedPaths() -> [(path: String, events: FileWatchEvent)] {
        var paths: [(path: String, events: FileWatchEvent)] = [(root, .write)]
        let fm = FileManager.default
        let devices = (root as NSString).appendingPathComponent("Devices")
        paths.append((devices, .write))
        for name in (try? fm.contentsOfDirectory(atPath: devices)) ?? [] where !name.hasPrefix(".") {
            let dir = (devices as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            paths.append((dir, .write))
        }
        return paths
    }

    private func makeWatch() -> FileEventWatch {
        FileEventWatch(paths: watchedPaths(), queue: queue) { [weak self] _ in
            self?.fired()
        }
    }

    /// A burst becomes one reload after `latency`; the watch set is rebuilt so
    /// a newly created device folder is picked up (and a deleted one's watch,
    /// already dropped by inotify, is not resurrected while it's gone).
    private func fired() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.watch?.cancel()
            self.watch = self.makeWatch()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onChange()
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + latency, execute: work)
    }
    #else
    func matters(_ path: String, _ flags: FSEventStreamEventFlags) -> Bool {
        let rescan = kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs
        if flags & FSEventStreamEventFlags(rescan) != 0 { return true }
        guard path == root || path.hasPrefix(root + "/") else { return false }
        let below = path.dropFirst(root.count).split(separator: "/")
        return below.isEmpty || (below[0] == "Devices" && below.count <= 2)
    }
    #endif

    deinit {
        #if os(Linux)
        pending?.cancel()
        watch?.cancel()
        #elseif os(Windows)
        // No-op (see above).
        #else
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        #endif
    }
}

extension DeviceInstance {
    /// This device's paths under the app's state and log roots.
    public nonisolated var paths: Paths { paths(state: Bundled.stateDirectory, logs: Bundled.logsDirectory) }
}
