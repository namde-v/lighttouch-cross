// Windows shims for the POSIX-isms HostRuntime uses on Apple/Linux.
//
// The POSIX `open` spelling imports into Swift but crashes (or returns
// unusable descriptors with EBADF) on swift-frontend 6.2.4's Windows overlay;
// `_open` is variadic (unavailable in Swift). winOpen() builds the HANDLE
// with CreateFileW and wraps it as a CRT descriptor with _open_osfhandle.

#if os(Windows)
import Foundation
import WinSDK

/// open(2) for Windows. See the file header. Mode bits are ignored (Windows
/// permissions are ACLs). The descriptor is always _O_BINARY (no CRLF
/// translation) and _O_NOINHERIT (the O_CLOEXEC equivalent). Returns -1 on
/// failure.
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
    // Match BuildTools' proven pattern: pass the O_* access mode directly.
    let osfFlags: Int32
    if read, write { osfFlags = O_RDWR } else if write { osfFlags = O_WRONLY } else { osfFlags = O_RDONLY }
    let fd = _open_osfhandle(Int(bitPattern: handle), osfFlags)
    if fd == -1 { CloseHandle(handle) }
    return fd
}

#endif
