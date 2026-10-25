// Per-platform C library spelling used across DeviceRuntime.

#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif

/// close(2). (DeviceLink.close shadows the global; LinkChannel needs it too.)
public func ltmClose(_ fd: Int32) {
    #if os(Linux)
    Glibc.close(fd)
    #elseif os(Windows)
    WinSDK.close(fd)
    #else
    Darwin.close(fd)
    #endif
}

/// Reconstruct a Windows HANDLE from a C-layer truncated int (see ltm_shm.h:
/// callers pass values that fit). Nil unless the value is a plausible handle
/// (positive: -1 is the C "none" sentinel, 0 is NULL).
public func ltmHandleFromInt(_ fd: Int32) -> UnsafeMutableRawPointer? {
    #if os(Windows)
    guard fd > 0 else { return nil }
    return UnsafeMutableRawPointer(bitPattern: Int(fd))
    #else
    return nil
    #endif
}

/// Close a hello handle: a CRT fd on POSIX, a mapping HANDLE on Windows
/// (where WinSDK.close would be wrong — it closes CRT fds, not handles).
public func ltmCloseHandle(_ fd: Int32) {
    #if os(Windows)
    if let handle = ltmHandleFromInt(fd) { CloseHandle(handle) }
    #else
    ltmClose(fd)
    #endif
}

/// SOCK_STREAM as Int32 (Glibc types it as __socket_type, not Int32).
public var ltmSockStream: Int32 {
    #if os(Linux)
    Int32(SOCK_STREAM.rawValue)
    #elseif os(Windows)
    // Winsock has no socketpair; the Windows wave replaces the link socket
    // wholesale (see TRANSPORT_REDESIGN.md). This value is never used.
    Int32(1)
    #else
    SOCK_STREAM
    #endif
}

/// kill(2), spelled per platform.
@discardableResult
public func ltmKill(_ pid: Int32, _ signal: Int32) -> Int32 {
    #if os(Linux)
    Glibc.kill(pid, signal)
    #elseif os(Windows)
    // No POSIX signals on Windows: terminate the process outright (signal is
    // ignored — the only caller need is "stop this helper").
    guard pid > 0 else { return -1 }
    guard let process = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(pid)) else { return -1 }
    defer { CloseHandle(process) }
    return TerminateProcess(process, 1) ? 0 : -1
    #else
    Darwin.kill(pid, signal)
    #endif
}
