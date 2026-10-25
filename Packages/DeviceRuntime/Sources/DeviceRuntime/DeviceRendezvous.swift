// How a spawned LightTouchDevice hands its shared-memory segments to the app.
//
// (Linux redesign; macOS used a bootstrap rendezvous + IOSurface Mach ports +
// code-signing attestation.)
//
// There is no shared namespace here to squat: the app spawns the helper
// itself, with a private socketpair whose helper end is fd 3. The helper's
// first act is one `sendmsg` on that socket: a small header (the one-time
// token from its argv, the protocol version, the ring generation, each
// segment's size) with the shm fds attached as SCM_RIGHTS. The app takes the
// hello before the control channel starts framing JSON, and validates:
//   1. the header arrived first on the private socket (anything else first is
//      a broken helper, and the link fails);
//   2. the token matches the one-time token on the helper's argv;
//   3. the protocol version matches DeviceLinkWire.protocolVersion;
//   4. the hello's SCM_CREDENTIALS pid is the pid the app spawned
//      (SO_PASSCRED on the receiving socket; SO_PEERCRED would report the
//      socketpair's creator, not the child).
// A random process cannot hold the socket's other end, so no code-signing
// attestation is needed. Control never leaves the socketpair either: it
// carries the length-framed JSON from DeviceLinkProtocol.swift after the hello.
//
// Windows: the same header over a loopback TCP socket (Winsock has no
// socketpair, no SCM_RIGHTS). Segments are named file mappings
// ("LTMShm_<token>_<index>"); the app re-opens them by name inside
// ltm_recv_hello, so the hello carries no handles. There is no
// SCM_CREDENTIALS equivalent for loopback sockets, so the pid check is
// skipped and the one-time token is the authentication (the socket is still
// private to this spawn).

#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation
import LTMShm

nonisolated public enum DeviceRendezvousError: Error, Equatable, CustomStringConvertible {
    /// Nothing arrived within the timeout.
    case timeout
    /// The helper died before saying hello.
    case helperDied
    /// The token did not match the one on the helper's argv.
    case tokenMismatch
    /// The helper's protocol version did not match DeviceLinkWire.protocolVersion.
    case protocolMismatch
    /// The hello's SCM_CREDENTIALS pid is not the pid the app spawned.
    case senderMismatch
    case malformed(String)
    /// An errno from poll/recvmsg/mmap.
    case system(Int32)

    public var description: String {
        switch self {
        case .timeout: "the device helper did not send its hello in time"
        case .helperDied: "the device helper exited before its hello"
        case .tokenMismatch: "the device helper's hello had the wrong token"
        case .protocolMismatch:
            "device helper speaks another protocol version, expected \(DeviceLinkWire.protocolVersion)"
        case .senderMismatch: "the hello came from a process this app did not spawn"
        case .malformed(let s): "malformed device helper hello: \(s)"
        case .system(let e): "device helper hello failed: \(String(cString: strerror(e)))"
        }
    }
}

nonisolated public enum DeviceRendezvous {
    /// What the app mapped from one hello: the status block, and (generation >
    /// 0) the three frame segments, sized from the status block's width/height.
    public struct Hello: Sendable {
        public var generation: UInt64
        public var status: ShmSurface
        public var frames: [ShmSurface]
    }

    /// Helper side: send the status block (and the ring, once there is one) as
    /// the first bytes on the link socket. Generation 0 takes exactly one
    /// segment (the status block); otherwise exactly three frame segments.
    /// Moves the segments' fds to the app; the mappings stay with the caller.
    /// Returns 0, or a positive errno.
    public static func sendHello(
        socket: Int32,
        token: String,
        generation: UInt64,
        segments: [ShmSurface]
    ) -> Int32 {
        let expected = generation == 0 ? 1 : Int(LTM_SHM_MAX_SEGMENTS)
        guard segments.count == expected else { return EINVAL }
        let counts = segments.map { UInt64($0.byteCount) }
        #if os(Windows)
        // Windows: the C layer ignores fds (segments are re-opened by name),
        // and the helper MUST keep its mapping handles alive until the app
        // opens them — so never takeFD here (takeFD would hand the fd off and
        // the mapping would die with the helper's last handle).
        let fds = [Int32](repeating: -1, count: segments.count)
        #else
        let fds = segments.map { $0.takeFD() }
        defer { for fd in fds where fd >= 0 { ltmClose(fd) } }
        #endif
        let rc = fds.withUnsafeBufferPointer { fdsPtr in
            counts.withUnsafeBufferPointer { countsPtr in
                token.withCString { tokenPtr in
                    ltm_send_hello(
                        socket,
                        tokenPtr,
                        UInt32(DeviceLinkWire.protocolVersion),
                        generation,
                        fdsPtr.baseAddress,
                        countsPtr.baseAddress,
                        Int32(fds.count)
                    )
                }
            }
        }
        return rc == 0 ? 0 : -rc
    }

    /// App side: block up to `timeout` for the helper's hello on the link
    /// socket, validate it, and map the segments. `pid` is the pid the app
    /// spawned (checked against the hello's SCM_CREDENTIALS).
    public static func receiveHello(
        socket: Int32,
        token: String,
        pid: pid_t,
        timeout: TimeInterval
    ) throws -> Hello {
        var hello = ltm_shm_hello()
        let rc = token.withCString { tokenPtr in
            ltm_recv_hello(
                socket,
                Int32((timeout * 1000).rounded(.towardZero)),
                tokenPtr,
                UInt32(DeviceLinkWire.protocolVersion),
                pid,
                &hello
            )
        }
        if rc != 0 {
            switch -rc {
            case ETIMEDOUT: throw DeviceRendezvousError.timeout
            case ECONNRESET: throw DeviceRendezvousError.helperDied
            case EACCES: throw DeviceRendezvousError.tokenMismatch
            case EPROTOTYPE: throw DeviceRendezvousError.protocolMismatch
            case ESRCH: throw DeviceRendezvousError.senderMismatch
            case EBADMSG: throw DeviceRendezvousError.malformed("header or control data")
            default: throw DeviceRendezvousError.system(-rc)
            }
        }
        let n = Int(hello.nsegments)
        let fds: [Int32] = withUnsafeBytes(of: hello.fds) { Array($0.bindMemory(to: Int32.self).prefix(n)) }
        let counts: [UInt64] = withUnsafeBytes(of: hello.byte_counts) {
            Array($0.bindMemory(to: UInt64.self).prefix(n))
        }
        guard n == 1 || n == 4, fds.count == n, counts.count == n else {
            throw DeviceRendezvousError.malformed("nsegments \(n)")
        }
        func abandon(_ from: Int) {
            // ltmCloseHandle, not ltmClose: on Windows these are mapping
            // HANDLEs from ltm_recv_hello, not CRT fds (identical to ltmClose
            // on POSIX).
            for fd in fds.dropFirst(from) where fd >= 0 { ltmCloseHandle(fd) }
        }
        guard
            let statusSurface = ShmSurface.open(
                fd: fds[0],
                byteCount: Int(counts[0]),
                width: StatusBlock.bytes / 8,
                height: 1,
                bytesPerRow: StatusBlock.bytes
            )
        else {
            abandon(0)
            throw DeviceRendezvousError.system(ENOMEM)
        }
        let status = StatusBlock(statusSurface)
        guard status.isValid else {
            abandon(1)
            throw DeviceRendezvousError.malformed("bad status block")
        }
        var frames: [ShmSurface] = []
        if n == 4 {
            // The helper activates the ring (publishing width/height) before
            // the hello goes out, so the app can size the segments.
            let width = Int(status[.width])
            let height = Int(status[.height])
            guard width > 0, height > 0, width <= 16384, height <= 16384 else {
                abandon(1)
                throw DeviceRendezvousError.malformed("bad ring size \(width)x\(height)")
            }
            for i in 1..<4 {
                guard counts[i] == UInt64(width * height * 4),
                    let frame = ShmSurface.open(
                        fd: fds[i],
                        byteCount: Int(counts[i]),
                        width: width,
                        height: height,
                        bytesPerRow: width * 4
                    )
                else {
                    abandon(i)  // fds[i] is still open: open() only closes on success
                    throw DeviceRendezvousError.malformed("frame segment \(i)")
                }
                frames.append(frame)
            }
        }
        return Hello(generation: hello.generation, status: statusSurface, frames: frames)
    }
}
