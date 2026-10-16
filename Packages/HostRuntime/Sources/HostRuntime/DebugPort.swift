// The per-device debug port: QEMU's gdbstub on a free loopback port, and the lldb command that attaches to it
// (qemu-ios docs/guest-debug.md: kernel and userland debugging through imgtools/lldb/xnu.py).

#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation

public nonisolated enum DebugPort {
    /// QEMU's argv for a gdbstub on 127.0.0.1:`port` (loopback only: the stub has no authentication).
    public static func arguments(port: Int) -> [String] { ["-gdb", "tcp:127.0.0.1:\(port)"] }

    /// A loopback port free right now (the kernel's pick for port 0). Racy by nature; QEMU fails to start on the
    /// rare collision and the next start picks again.
    public static func freePort() -> Int? {
        #if os(Linux)
        // Glibc imports SOCK_STREAM as __socket_type, not Int32.
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        #if canImport(Darwin)
        // BSD sockaddr_in carries its length; Linux and Windows do not.
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }

    /// What to paste into Terminal. KERNELCACHE stays a placeholder: the decrypted kernel lives in the firmware,
    /// not in the device (qemu-ios docs/guest-debug.md lists where each board's comes from).
    public static func lldbCommand(board: String, port: Int) -> String {
        "lldb -o 'target create --arch \(Board(rawValue: board)?.arch ?? "armv7")-apple-ios KERNELCACHE'"
            + " -o 'gdb-remote 127.0.0.1:\(port)'"
            + " -o 'command script import QEMU_IOS/imgtools/lldb/xnu.py'"
    }
}
