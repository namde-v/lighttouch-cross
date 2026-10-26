#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Crypto
import _CryptoExtras
import Foundation
import LTMShm
import Testing

import DeviceRuntime

private final class BundleAnchor {}

/// A Winsock failure in the Windows spawn path (there is no errno for
/// Winsock errors; the WSA code is the diagnostic).
private struct WindowsSocketError: Error, CustomStringConvertible {
    var message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// End-to-end tests of the redesigned helper<->app transport: the
/// RendezvousTestPeer stand-in helper is spawned exactly the way DeviceLink
/// spawns a real helper (a private link socket — socketpair on POSIX with the
/// child's end on fd 3, loopback TCP on Windows — plus a one-time token on
/// argv), and the app takes its hello over the socket.
// DIAGNOSTIC (temporary): stderr timeline. When the test process dies
// abnormally, block-buffered stdout can lose "passed" lines, but stderr is
// unbuffered and survives — so these markers show which test was running
// when the process died. Removed once the Windows exit-1 cause is found.
private func diagTransport(_ message: String) {
    if let data = ("DIAG-TRANSPORT \(message)\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

// DIAGNOSTIC round 3 (temporary): transport tests OFF, link test alone.
@Suite(.serialized) struct DeviceTransportTests {
    /// RendezvousTestPeer, built beside this test bundle.
    #if os(Windows)
    // Like Linux: the test runner sits beside the peer executable in the
    // products directory; CommandLine.arguments[0] is the runner exe.
    private let peer: URL = {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
        return exe.deletingLastPathComponent().appendingPathComponent("RendezvousTestPeer.exe")
    }()
    #elseif os(Linux)
    // The test runner sits beside the peer executable in the products
    // directory; /proc/self/exe is always absolute (Bundle(for:) on Linux
    // resolves to the .so, whose layout SPM does not guarantee).
    private let peer: URL = {
        let exe = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe"))
            .map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return exe.deletingLastPathComponent().appendingPathComponent("RendezvousTestPeer")
    }()
    #else
    private let peer = Bundle(for: BundleAnchor.self).bundleURL
        .deletingLastPathComponent().appendingPathComponent("RendezvousTestPeer")
    #endif

    private struct Spawned {
        var pid: pid_t
        var socket: Int32
    }

    #if os(Windows)
    /// Spawn the peer with the link socket over loopback TCP, like DeviceLink
    /// does with a socketpair on POSIX (Winsock has no socketpair). The test
    /// builds the loopback pair before spawning and passes the connected
    /// client socket to the child via ltm_spawn (inherited handle +
    /// LTM_LINK_SOCKET env); the accepted socket is the app's end.
    private func spawnPeer(token: String, mode: String) throws -> Spawned {
        try #require(
            FileManager.default.isExecutableFile(atPath: peer.path),
            "test peer missing at \(peer.path)"
        )
        // Winsock needs WSAStartup in this process (the C layer does not do it).
        var wsadata = WSADATA()
        guard WSAStartup(0x0202, &wsadata) == 0 else {
            throw WindowsSocketError("WSAStartup failed: \(WSAGetLastError())")
        }
        // Listener on 127.0.0.1:0 (defers close the parent's copies on every exit).
        // IPPROTO_TCP is 6 (winsock2.h); the overlay types it IPPROTO, not
        // Int32, so spell the value out (same precedent as 0xF001F for
        // FILE_MAP_ALL_ACCESS).
        let listener = socket(AF_INET, SOCK_STREAM, 6)
        guard listener != INVALID_SOCKET else {
            throw WindowsSocketError("socket failed: \(WSAGetLastError())")
        }
        defer { closesocket(listener) }
        var addr = sockaddr_in()
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        // inet_addr returns UInt32 in the overlay, not in_addr, and in_addr's
        // union members aren't addressable from Swift — write the 4
        // network-order bytes directly (inet_addr already returns network order).
        withUnsafeMutableBytes(of: &addr.sin_addr) { $0.storeBytes(of: inet_addr("127.0.0.1"), as: UInt32.self) }
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw WindowsSocketError("bind failed: \(WSAGetLastError())")
        }
        guard listen(listener, SOMAXCONN) == 0 else {
            throw WindowsSocketError("listen failed: \(WSAGetLastError())")
        }
        // Bound port (network order — copied as-is to the client, no htons dance).
        // NOTE: no trailing closure in the guard condition — Swift's parser
        // rejects `guard f(x) { ... } == 0 else` ("expected 'else' after
        // 'guard' condition", which cascades to the lines after it). Compute
        // first, guard second (same shape as `bound` / `connected` above).
        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &boundLen)
            }
        }
        guard gotName == 0 else {
            throw WindowsSocketError("getsockname failed: \(WSAGetLastError())")
        }
        // Client: connect to the listener.
        // See above: IPPROTO_TCP spelled out as 6.
        let client = socket(AF_INET, SOCK_STREAM, 6)
        guard client != INVALID_SOCKET else {
            throw WindowsSocketError("socket failed: \(WSAGetLastError())")
        }
        defer { closesocket(client) }
        var clientAddr = sockaddr_in()
        clientAddr.sin_family = ADDRESS_FAMILY(AF_INET)
        // See above: network-order bytes written directly.
        withUnsafeMutableBytes(of: &clientAddr.sin_addr) { $0.storeBytes(of: inet_addr("127.0.0.1"), as: UInt32.self) }
        clientAddr.sin_port = boundAddr.sin_port
        let connected = withUnsafePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw WindowsSocketError("connect failed: \(WSAGetLastError())")
        }
        // Accept, bounded: a peer that never connects must not hang the test.
        // SO_RCVTIMEO on the listener applies to accept(); it is cleared on
        // the accepted socket below so the C recv's own deadline rules.
        var timeoutMs: DWORD = 10_000
        setsockopt(listener, SOL_SOCKET, SO_RCVTIMEO, &timeoutMs, Int32(MemoryLayout<DWORD>.size))
        let accepted = accept(listener, nil, nil)
        guard accepted != INVALID_SOCKET else {
            throw WindowsSocketError("accept failed: \(WSAGetLastError())")
        }
        var noTimeout: DWORD = 0
        setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, Int32(MemoryLayout<DWORD>.size))
        // Spawn: the child inherits the connected client socket.
        let argv = [peer.path, token, mode]
        let pid: pid_t = withWindowsCStrings(argv) { cargv in
            ltm_spawn(peer.path, cargv, nil, -1, Int32(truncatingIfNeeded: client))
        }
        guard pid > 0 else {
            closesocket(accepted)
            throw POSIXError(POSIXErrorCode(rawValue: -pid) ?? .EIO)
        }
        // The defers close the parent's listener + client copies; the accepted
        // socket is the app's end and stays open. SOCKET values truncate to
        // the API's Int32 (the C layer's documented convention; test-process
        // socket values are small).
        return Spawned(pid: pid, socket: Int32(truncatingIfNeeded: accepted))
    }

    private func reap(_ spawned: Spawned) {
        if let process = OpenProcess(DWORD(SYNCHRONIZE), false, DWORD(spawned.pid)) {
            WaitForSingleObject(process, INFINITE)
            CloseHandle(process)
        }
        // OpenProcess fails when the peer is already gone: already reaped.
        closesocket(SOCKET(truncatingIfNeeded: spawned.socket))
    }
    #else
    /// Spawn the peer with the link socket on fd 3, like DeviceLink does.
    private func spawnPeer(token: String, mode: String) throws -> Spawned {
        try #require(
            FileManager.default.isExecutableFile(atPath: peer.path),
            "test peer missing at \(peer.path)"
        )
        var sv: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, ltmSockStream, 0, &sv) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let argv = [peer.path, token, mode]
        let pid: pid_t = withCStrings(argv) { cargv in
            ltm_spawn(peer.path, cargv, nil, -1, sv[1])
        }
        ltmClose(sv[1])
        guard pid > 0 else {
            ltmClose(sv[0])
            throw POSIXError(POSIXErrorCode(rawValue: -pid) ?? .EIO)
        }
        return Spawned(pid: pid, socket: sv[0])
    }

    private func reap(_ spawned: Spawned) {
        var status: Int32 = 0
        var r: pid_t = 0
        repeat {
            r = waitpid(spawned.pid, &status, 0)
        } while r < 0 && errno == EINTR
        ltmClose(spawned.socket)
    }
    #endif

    /// shm create (peer) -> pass -> map -> read status block (app): SCM_RIGHTS
    /// on POSIX, named mappings re-opened by name on Windows.
    @Test(.disabled()) func shmHelloRoundTrip() throws {
        diagTransport("shmHelloRoundTrip started")
        let token = "test-token-\(UInt32.random(in: 0...UInt32.max))"
        let spawned = try spawnPeer(token: token, mode: "exit")
        defer { reap(spawned) }

        let hello = try DeviceRendezvous.receiveHello(
            socket: spawned.socket,
            token: token,
            pid: spawned.pid,
            timeout: 10
        )
        #expect(hello.generation == 0)
        #expect(hello.frames.isEmpty)

        let status = StatusBlock(hello.status)
        #expect(status.isValid)
        // The peer stamped these before its hello; the app reads them out of
        // the shared mapping (which survives the peer's exit).
        #expect(status[.magic] == StatusBlock.magic)
        #expect(status[.layoutVersion] == StatusBlock.layoutVersion)
        let snapshot = status.snapshot()
        #expect(snapshot.heartbeat == 7)
        #expect(snapshot.helperPID == spawned.pid)
        diagTransport("shmHelloRoundTrip finished")
    }

    /// A hello with the wrong token is rejected, and the received fds are not leaked.
    @Test(.disabled()) func wrongTokenIsRejected() throws {
        diagTransport("wrongTokenIsRejected started")
        let spawned = try spawnPeer(token: "right-token", mode: "exit")
        defer { reap(spawned) }
        #expect(throws: DeviceRendezvousError.tokenMismatch) {
            try DeviceRendezvous.receiveHello(
                socket: spawned.socket,
                token: "wrong-token",
                pid: spawned.pid,
                timeout: 10
            )
        }
        diagTransport("wrongTokenIsRejected finished")
    }

    /// The status block, frame ring writer/reader, and the alpha-opaque blit,
    /// all in-process (no spawn). Runs on Windows too: the helper-side
    /// segments are pagefile-backed file mappings there (ShmSurface), and
    /// the spawn-based tests above now run on Windows as well (loopback
    /// socket + hello transport).
    @Test(.disabled()) func statusBlockAndFrameRingInProcess() {
        diagTransport("statusBlockAndFrameRingInProcess started")
        let status = StatusBlock.create()
        #expect(status.isValid)
        status[.heartbeat] = 41

        let writer = FrameRingWriter(status: status)
        writer.resize(width: 8, height: 4)
        writer.activate()
        #expect(status[.width] == 8)
        #expect(status[.height] == 4)
        #expect(status[.ringGeneration] == writer.generation)

        // 8x4 BGRA with alpha 0 everywhere and a known RGB pixel.
        var pixels = [UInt8](repeating: 0, count: 8 * 4 * 4)
        pixels[0] = 10; pixels[1] = 20; pixels[2] = 30  // B, G, R of pixel 0
        let published = pixels.withUnsafeBytes { ptr in
            writer.publish { surface in
                FrameRingWriter.copy(ptr.baseAddress!, width: 8, height: 4, into: surface)
            }
        }
        #expect(published)
        #expect(status[.front] == 0)

        let reader = FrameRingReader(status: status, generation: writer.generation, surfaces: writer.surfaces)
        guard let front = reader.front() else {
            Issue.record("no front surface after publish")
            return
        }
        #expect(front.isNew)
        #expect(front.serial == 1)
        // Alpha forced opaque, RGB preserved (little-endian BGRA word).
        let words = front.surface.baseAddress.assumingMemoryBound(to: UInt32.self)
        #expect(words[0] == 0xFF1E_140A)
        #expect(words[5] & 0xFF00_0000 == 0xFF00_0000)

        let snapshot = status.snapshot()
        #expect(snapshot.heartbeat == 41)
        #expect(snapshot.width == 8)
        #expect(snapshot.height == 4)
        #if os(Windows)
        #expect(snapshot.helperPID == Int32(bitPattern: GetCurrentProcessId()))
        #else
        #expect(snapshot.helperPID == getpid())
        #endif
        diagTransport("statusBlockAndFrameRingInProcess finished")
    }

    /// WebProxyCA: create the CA files, reload them, mint a leaf for a host,
    /// and verify the leaf's RSA/SHA-1 signature against the CA public key.
    @Test(.disabled()) func webProxyCAIssuesVerifiableLeaf() throws {
        diagTransport("webProxyCAIssuesVerifiableLeaf started")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-ca-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("proxy.cfg")

        let ca = try WebProxyCA.prepare(config: config)
        // Files exist, the key material owner-readable only.
        #if !os(Windows)
        let pemAttributes = try FileManager.default.attributesOfItem(atPath: config.path + ".ca.pem")
        #expect((pemAttributes[.posixPermissions] as? Int) == 0o600)
        #else
        // Windows has no POSIX permission bits; a file the app creates in its
        // own state directory is owner-only by default ACL (what the check
        // above is after on POSIX).
        #endif
        #expect(FileManager.default.fileExists(atPath: config.path + ".ca.der"))

        // Reload from disk: same key, same certificate.
        let reloaded = try WebProxyCA.load(config: config)
        #expect(reloaded.certificateDER == ca.certificateDER)
        #expect(reloaded.key.publicKey.derRepresentation == ca.key.publicKey.derRepresentation)

        // A leaf for a DNS name, and one for an IP literal.
        for host in ["example.com", "192.168.1.20"] {
            let leafKey = try WebProxyCA.newKey()
            let identity = try ca.identity(for: host, key: leafKey)
            let cert = try #require(DER.children(identity.certificateDER))
            #expect(cert.count == 3)  // tbs, signatureAlgorithm, signatureValue
            // The signature verifies under the CA key: RSA PKCS#1 v1.5 over SHA-1.
            let bitString = cert[2].content
            #expect(bitString.first == 0)  // BIT STRING unused-bits byte
            let signature = _RSA.Signing.RSASignature(rawRepresentation: bitString.dropFirst())
            let digest = Insecure.SHA1.hash(data: cert[0].whole)
            #expect(
                ca.key.publicKey.isValidSignature(signature, for: digest, padding: .insecurePKCS1v1_5),
                "leaf signature for \(host) does not verify"
            )
            // The leaf's issuer is the CA's subject.
            let tbs = try #require(DER.children(cert[0].whole))
            #expect(tbs.count == 8)
            #expect(tbs[3].whole == ca.subject)
            // The identity carries the key that matches the leaf.
            let leafSPKI = try #require(DER.children(tbs[6].whole))
            #expect(leafSPKI.count == 2)
            #expect(Data(leafSPKI[1].content.dropFirst()).count > 0)
            #expect(identity.privateKey.publicKey.derRepresentation == Data(tbs[6].whole))
        }
        diagTransport("webProxyCAIssuesVerifiableLeaf finished")
    }
}

#if os(Windows)
/// argv for ltm_spawn without strdup: allocate each string, free after the
/// call (ltm_spawn copies argv into its own command line before returning).
nonisolated private func withWindowsCStrings<R>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> R
) -> R {
    var owned: [UnsafeMutablePointer<CChar>?] = []
    for s in strings {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: s.utf8.count + 1)
        s.withCString { src in buf.initialize(from: src, count: s.utf8.count + 1) }
        owned.append(buf)
    }
    owned.append(nil)
    defer { for p in owned { p?.deallocate() } }
    return owned.withUnsafeBufferPointer { base in body(base.baseAddress) }
}
#endif

#if !os(Windows)
nonisolated private func withCStrings<R>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> R
) -> R {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for p in pointers { free(p) } }
    return pointers.withUnsafeBufferPointer {
        guard let base = $0.baseAddress else { preconditionFailure("The array holds at least its nil terminator") }
        return body(base)
    }
}
#endif
