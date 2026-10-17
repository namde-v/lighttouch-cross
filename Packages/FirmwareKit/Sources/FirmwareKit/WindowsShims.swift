// Windows shims for the POSIX-isms FirmwareKit uses on Apple/Linux.
//
// WinSDK has no mode_t/off_t/pread/pwrite/ftruncate/truncate/fsync, and the
// CZlibFK/CSQLite3 system-library targets are no-ops on Windows (see their
// shim.h). The functions below give the firmware I/O code the same names with
// the same contracts, implemented over the UCRT/Win32 API. They are only
// compiled on Windows, so they can never shadow a real POSIX symbol.

#if os(Windows)
import Foundation
import WinSDK

/// WinSDK has no mode_t; permission bits fit in UInt32 on every platform here.
typealias mode_t = UInt32
/// WinSDK has no off_t; file offsets are 64-bit.
typealias off_t = Int64
/// WinSDK has no pid_t; process IDs fit in Int32 (getpid() returns Int32).
typealias pid_t = Int32
/// O_CLOEXEC's Windows equivalent: the CRT descriptor is not inherited by
/// child processes.
let O_CLOEXEC: Int32 = 0x80  // _O_NOINHERIT

/// pread(2): positional read without moving the shared file offset's
/// observable state for other users of the descriptor. Implemented as
/// seek+read; FirmwareKit never shares one of these descriptors across
/// threads, so the non-atomicity vs. POSIX pread does not matter here.
func pread(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int, _ offset: off_t) -> Int {
    guard let buf, count >= 0 else { return -1 }
    guard _lseeki64(fd, offset, SEEK_SET) != -1 else { return -1 }
    // UCRT read takes a UInt32 count.
    let n = read(fd, buf, UInt32(count))
    return n < 0 ? -1 : Int(n)
}

/// pwrite(2): positional write; see pread for the atomicity note.
func pwrite(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int, _ offset: off_t) -> Int {
    guard let buf, count >= 0 else { return -1 }
    guard _lseeki64(fd, offset, SEEK_SET) != -1 else { return -1 }
    let n = write(fd, buf, UInt32(count))
    return n < 0 ? -1 : Int(n)
}

/// ftruncate(3): resize an open file.
func ftruncate(_ fd: Int32, _ length: off_t) -> Int32 {
    _chsize_s(fd, UInt64(bitPattern: length))
}

/// truncate(3): resize a file by path.
func truncate(_ path: UnsafePointer<CChar>?, _ length: off_t) -> Int32 {
    guard let path else { return -1 }
    let fd = open(path, O_WRONLY | _O_BINARY)
    guard fd >= 0 else { return -1 }
    defer { _ = close(fd) }
    return _chsize_s(fd, UInt64(bitPattern: length))
}

/// fsync(2): flush an open file's buffers to the OS.
func fsync(_ fd: Int32) -> Int32 {
    _commit(fd)
}

/// flock(LOCK_EX | LOCK_NB): non-blocking exclusive byte-range lock, the
/// same pattern HostRuntime's StorageLease uses. Closing the descriptor
/// releases the lock.
func flockTryLockExclusive(_ fd: Int32) -> Bool {
    let raw = _get_osfhandle(fd)
    guard raw != -1, let handle = UnsafeMutableRawPointer(bitPattern: raw) else { return false }
    var overlapped = OVERLAPPED()
    return LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY), 0, 1, 0, &overlapped)
}

/// flock(LOCK_EX): blocking exclusive byte-range lock.
func flockLockExclusive(_ fd: Int32) -> Bool {
    let raw = _get_osfhandle(fd)
    guard raw != -1, let handle = UnsafeMutableRawPointer(bitPattern: raw) else { return false }
    var overlapped = OVERLAPPED()
    return LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK), 0, 1, 0, &overlapped)
}

/// flock(LOCK_SH): blocking shared byte-range lock.
func flockLockShared(_ fd: Int32) -> Bool {
    let raw = _get_osfhandle(fd)
    guard raw != -1, let handle = UnsafeMutableRawPointer(bitPattern: raw) else { return false }
    var overlapped = OVERLAPPED()
    return LockFileEx(handle, 0, 0, 1, 0, &overlapped)
}

/// flock(LOCK_UN): release a byte-range lock.
func flockUnlock(_ fd: Int32) {
    let raw = _get_osfhandle(fd)
    guard raw != -1, let handle = UnsafeMutableRawPointer(bitPattern: raw) else { return }
    var overlapped = OVERLAPPED()
    UnlockFileEx(handle, 0, 1, 0, &overlapped)
}

#endif
