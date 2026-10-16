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
    fatalError("ltmKill: the Windows transport is not implemented yet (see TRANSPORT_REDESIGN.md)")
    #else
    Darwin.kill(pid, signal)
    #endif
}
