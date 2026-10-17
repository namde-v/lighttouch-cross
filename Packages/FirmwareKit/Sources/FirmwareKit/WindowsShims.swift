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
/// Public because FirmwareKit's public API uses it (e.g. SystemEdits.put's mode parameter).
public typealias mode_t = UInt32
/// WinSDK has no off_t; file offsets are 64-bit.
public typealias off_t = Int64
/// WinSDK has no pid_t; process IDs fit in Int32 (getpid() returns Int32).
public typealias pid_t = Int32
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
    // _chsize_s takes a signed __int64 size; off_t is already Int64.
    _chsize_s(fd, length)
}

/// open(2) for Windows. The POSIX `open` spelling imports into Swift but
/// CRASHES swift-frontend 6.2.4's Windows overlay at runtime, and `_open` is
/// variadic (unavailable in Swift) — proven by the BuildTools Vendor.lock
/// work (commit 1890a52). Build the HANDLE with CreateFileW and wrap it as
/// a CRT descriptor with _open_osfhandle, so every caller can keep using
/// read/write/pread/pwrite/close/_commit/ftruncate on the returned fd and
/// the existing `fd >= 0` error checks keep working. Mode bits are ignored
/// (Windows permissions are ACLs). The descriptor is always _O_BINARY (no
/// CRLF translation) and _O_NOINHERIT (the O_CLOEXEC equivalent).
/// Returns -1 on failure; errno is NOT set (it is not safely assignable from
/// Swift on Windows), so failure diagnostics should not use strerror here.
func winOpen(
    _ path: String,
    read: Bool = false,
    write: Bool = false,
    create: Bool = false,
    truncate truncateExisting: Bool = false,
    exclusive: Bool = false
) -> Int32 {
    var access = DWORD(0)
    if read { access |= DWORD(GENERIC_READ) }
    if write { access |= DWORD(GENERIC_WRITE) }
    let creation: DWORD
    switch (create, truncateExisting, exclusive) {
    case (_, _, true): creation = DWORD(CREATE_NEW) // O_CREAT|O_EXCL
    case (true, true, _): creation = DWORD(CREATE_ALWAYS) // O_CREAT|O_TRUNC
    case (true, false, _): creation = DWORD(OPEN_ALWAYS) // O_CREAT
    case (false, true, _): creation = DWORD(TRUNCATE_EXISTING) // O_TRUNC
    default: creation = DWORD(OPEN_EXISTING)
    }
    let wide = Array(path.utf16) + [0]
    let handle: UnsafeMutableRawPointer? = wide.withUnsafeBufferPointer { buf in
        CreateFileW(
            buf.baseAddress,
            access,
            DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
            nil,
            creation,
            DWORD(FILE_ATTRIBUTE_NORMAL),
            nil
        )
    }
    guard let handle, handle != INVALID_HANDLE_VALUE else { return -1 }
    // _O_RDONLY is 0; _O_WRONLY/_O_RDWR from fcntl.h. _O_NOINHERIT is 0x80
    // (hardcoded: the O_CLOEXEC shim above documents the same value).
    var osfFlags = Int32(_O_BINARY) | 0x80
    if read, write { osfFlags |= Int32(_O_RDWR) } else if write { osfFlags |= Int32(_O_WRONLY) }
    let fd = _open_osfhandle(Int(bitPattern: handle), osfFlags)
    if fd == -1 { CloseHandle(handle) }
    return fd
}

/// truncate(3): resize a file by path.
func truncate(_ path: UnsafePointer<CChar>?, _ length: off_t) -> Int32 {
    guard let path else { return -1 }
    // winOpen: the POSIX open spelling crashes Swift 6.2.4's Windows overlay.
    let fd = winOpen(String(cString: path), write: true)
    guard fd >= 0 else { return -1 }
    defer { _ = close(fd) }
    return _chsize_s(fd, length)
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
