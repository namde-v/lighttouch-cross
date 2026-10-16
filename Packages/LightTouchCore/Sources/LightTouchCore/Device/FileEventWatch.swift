// Path watching without DispatchSource's file-system object source (kqueue's
// vnode monitoring, absent from swift-corelibs-libdispatch on Linux).
//
// Linux: inotify. One fd per watch set, one reader thread blocked in poll()
// with a short timeout so cancel() (which flips a flag) never has to unblock
// a read from another thread. Darwin keeps the DispatchSource implementation;
// Windows gets a stub that never fires (see SHIM_NOTES.md).
import Foundation
import Synchronization

#if os(Linux)
import Glibc
#endif

/// Events of interest on a watched path.
nonisolated struct FileWatchEvent: OptionSet, Sendable {
    let rawValue: Int
    static let delete = FileWatchEvent(rawValue: 1 << 0)
    static let rename = FileWatchEvent(rawValue: 1 << 1)
    static let revoke = FileWatchEvent(rawValue: 1 << 2)
    static let write = FileWatchEvent(rawValue: 1 << 3)
}

/// Watches paths for delete/rename/revoke/write, calling `onEvent` with the
/// path once per event. `count` is the watches actually installed.
/// Nonisolated: it hops to `queue` itself.
nonisolated final class FileEventWatch: @unchecked Sendable {
    private let queue: DispatchQueue
    private let onEvent: @Sendable (String) -> Void
    #if os(Linux)
    private let fd: Int32
    private let watches = Mutex([Int32: String]())
    private let cancelled = Mutex(false)
    #else
    private var sources: [AnyObject] = []
    #endif

    init(
        paths: [(path: String, events: FileWatchEvent)],
        queue: DispatchQueue,
        onEvent: @escaping @Sendable (String) -> Void
    ) {
        self.queue = queue
        self.onEvent = onEvent
        #if os(Linux)
        fd = inotify_init1(Int32(IN_CLOEXEC))
        guard fd >= 0 else { return }
        for (path, events) in paths {
            var mask: UInt32 = 0
            if events.contains(.delete) { mask |= UInt32(IN_DELETE_SELF) }
            if events.contains(.rename) { mask |= UInt32(IN_MOVE_SELF) }
            // No inotify equivalent of NOTE_REVOKE. IN_ATTRIB is not one:
            // attribute changes (and the unlink path) fire it spuriously,
            // which would double-report unlinks.
            if events.contains(.write) {
                mask |= UInt32(IN_MODIFY | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO)
            }
            let wd = path.withCString { inotify_add_watch(fd, $0, mask) }
            guard wd >= 0 else { continue }
            watches.withLock { $0[wd] = path }
        }
        Thread.detachNewThread { [weak self] in self?.readLoop() }
        #elseif os(Windows)
        // No kqueue/inotify on Windows: the stub installs no watches.
        #else
        for (path, events) in paths {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            var mask = DispatchSource.FileSystemEvent()
            if events.contains(.delete) { mask.insert(.delete) }
            if events.contains(.rename) { mask.insert(.rename) }
            if events.contains(.revoke) { mask.insert(.revoke) }
            if events.contains(.write) { mask.insert(.write) }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: mask,
                queue: queue
            )
            let handler = onEvent
            source.setEventHandler { handler(path) }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
        #endif
    }

    var count: Int {
        #if os(Linux)
        watches.withLock { $0.count }
        #elseif os(Windows)
        0
        #else
        sources.count
        #endif
    }

    func cancel() {
        #if os(Linux)
        cancelled.withLock { $0 = true }
        // The reader thread's poll() times out and exits on its own.
        #elseif os(Windows)
        #else
        for source in sources { (source as? DispatchSource)?.cancel() }
        sources = []
        #endif
    }

    deinit { cancel() }

    #if os(Linux)
    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        // inotify_event: wd(4) mask(4) cookie(4) len(4) name[len].
        while !cancelled.withLock({ $0 }) {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 250)
            guard ready > 0 else { continue }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { continue }
            var i = 0
            while i + 16 <= n {
                let wd = buffer.withUnsafeBytes { $0.load(fromByteOffset: i, as: Int32.self) }
                let mask = buffer.withUnsafeBytes { $0.load(fromByteOffset: i + 4, as: UInt32.self) }
                let len = Int(buffer.withUnsafeBytes { $0.load(fromByteOffset: i + 12, as: UInt32.self) })
                if mask & UInt32(IN_IGNORED) == 0, let path = watches.withLock({ $0[wd] }) {
                    let handler = onEvent
                    let q = queue
                    q.async { handler(path) }
                }
                // A watched path deleted or moved away: the watch is gone.
                if mask & UInt32(IN_DELETE_SELF | IN_MOVE_SELF | IN_IGNORED) != 0 {
                    watches.withLock { $0.removeValue(forKey: wd) }
                }
                i += 16 + len
            }
        }
        close(fd)
    }
    #endif
}
