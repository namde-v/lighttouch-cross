#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation
import Synchronization

/// close(2) qualified per platform: the class's own close() method shadows the
/// global, so the Darwin spelling cannot be used unqualified on any platform.
#if os(Linux)
private func posixClose(_ fd: Int32) -> Int32 { Glibc.close(fd) }
#elseif os(Windows)
private func posixClose(_ fd: Int32) -> Int32 { WinSDK.close(fd) }
#else
private func posixClose(_ fd: Int32) -> Int32 { Darwin.close(fd) }
#endif

/// Owns the stopped/live device exclusion descriptor, never the lease pathname.
/// Keep the inode in place: unlinking it permits another owner to lock a new file.
public nonisolated final class StorageLease: Sendable {
    public enum Failure: Error, Equatable {
        case openFailed(Int32)
        case inUse
        case pendingEdit
    }
    private let descriptor: Mutex<Int32?>

    /// Resume callers may allow a pending edit only while validating their exact
    /// durable session under this same lease; ordinary boot/export/maintenance deny it.
    public init(_ path: URL, allowPendingEdit: Bool = false) throws {
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #if os(Windows)
        // No O_NOFOLLOW in the CRT: refuse a lease through a reparse point, as
        // O_NOFOLLOW does on POSIX. No O_CLOEXEC either: _O_NOINHERIT.
        if Self.isReparsePoint(path) { throw Failure.openFailed(Int32(ERROR_CANT_RESOLVE_FILENAME)) }
        let fd = open(path.path, O_RDWR | O_CREAT | _O_NOINHERIT, 0o600)
        #else
        let fd = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        #endif
        guard fd >= 0 else { throw Failure.openFailed(errno) }
        do {
            #if os(Windows)
            guard Self.lockExclusive(fd) else { throw Failure.inUse }
            #else
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.inUse }
            #endif
            // Inspect durable intent after exclusion, so a previous editor's exit
            // cannot admit boot/export while its unfinished transaction remains.
            if !allowPendingEdit
                && FileManager.default.fileExists(atPath: directory.appendingPathComponent("edit.json").path)
            {
                throw Failure.pendingEdit
            }
            descriptor = Mutex(fd)
        } catch {
            // Refused for a pending edit, the lock was already taken: release it as close() does, since a child
            // being spawned at this moment shares the descriptor until its exec.
            #if os(Windows)
            Self.unlock(fd)
            #else
            flock(fd, LOCK_UN)
            #endif
            posixClose(fd)
            throw error
        }
    }
    public var isClosed: Bool { descriptor.withLock { $0 == nil } }

    /// End an explicitly shared ownership scope after all operations finish.
    /// Retained aliases are then closed owners; the inode remains in place.
    public func close() {
        descriptor.withLock { descriptor in
            guard let fd = descriptor else { return }
            descriptor = nil
            // Closing only this reference can leave a transient inherited
            // pre-exec alias holding flock despite FD_CLOEXEC. End the scope.
            #if os(Windows)
            Self.unlock(fd)
            #else
            flock(fd, LOCK_UN)
            #endif
            posixClose(fd)
        }
    }
    deinit { close() }
}

#if os(Windows)
extension StorageLease {
    /// No flock(2) on Windows: an exclusive, non-blocking byte-range lock via
    /// LockFileEx on the CRT descriptor's HANDLE. Closing the descriptor (or
    /// process exit) releases the lock, matching the flock contract above.
    fileprivate static func lockExclusive(_ fd: Int32) -> Bool {
        guard let handle = lockHandle(fd) else { return false }
        var overlapped = OVERLAPPED()
        // LockFileEx returns BOOL (Swift Bool); the flag #defines import as
        // Int32 and need a DWORD conversion for the DWORD parameters.
        return LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY), 0, 1, 0, &overlapped)
    }

    fileprivate static func unlock(_ fd: Int32) {
        guard let handle = lockHandle(fd) else { return }
        var overlapped = OVERLAPPED()
        UnlockFileEx(handle, 0, 1, 0, &overlapped)
    }

    private static func lockHandle(_ fd: Int32) -> UnsafeMutableRawPointer? {
        let raw = _get_osfhandle(fd)
        guard raw != -1 else { return nil }
        return UnsafeMutableRawPointer(bitPattern: raw)
    }

    /// The O_NOFOLLOW equivalent: refuse to open the lease through a reparse
    /// point (symlink, junction), so the lock can't be taken on another file.
    private static func isReparsePoint(_ url: URL) -> Bool {
        var wide = Array(url.path.utf16)
        wide.append(0)
        return wide.withUnsafeBufferPointer { buffer in
            guard let wpath = buffer.baseAddress else { return false }
            let attrs = GetFileAttributesW(wpath)
            return attrs != INVALID_FILE_ATTRIBUTES && attrs & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0
        }
    }
}
#endif
