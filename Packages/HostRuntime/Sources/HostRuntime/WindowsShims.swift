// Windows shims for the POSIX-isms HostRuntime uses on Apple/Linux.
//
// The POSIX `open` spelling imports into Swift but CRASHES swift-frontend
// 6.2.4's Windows overlay at runtime, and `_open` is variadic (unavailable in
// Swift) — proven by the BuildTools Vendor.lock work (commit 1890a52) and
// adopted by FirmwareKit's winOpen. They are only compiled on Windows, so
// they can never shadow a real POSIX symbol.

#if os(Windows)
import Foundation
import WinSDK

/// open(2) for Windows. Builds the HANDLE with CreateFileW and wraps it as a
/// CRT descriptor with _open_osfhandle, so callers can keep using
/// read/write/close/LockFileEx on the returned fd and the existing
/// `fd >= 0` error checks keep working. The descriptor is always _O_BINARY
/// (no CRLF translation) and _O_NOINHERIT (the O_CLOEXEC equivalent).
/// Returns -1 on failure; errno is NOT set (it is not safely assignable from
/// Swift on Windows), so failure diagnostics should use GetLastError().
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
    // (the same value the O_CLOEXEC-equivalent shim documents elsewhere).
    var osfFlags = Int32(_O_BINARY) | 0x80
    if read, write { osfFlags |= Int32(_O_RDWR) } else if write { osfFlags |= Int32(_O_WRONLY) }
    let fd = _open_osfhandle(Int(bitPattern: handle), osfFlags)
    if fd == -1 { CloseHandle(handle) }
    return fd
}
#endif
