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

/// End-to-end tests of the redesigned (POSIX shm + SCM_RIGHTS) helper<->app
/// transport: the RendezvousTestPeer stand-in helper is spawned exactly the way
/// DeviceLink spawns a real helper (socketpair, the child's end on fd 3, a
/// one-time token on argv), and the app takes its hello over the socket.
struct DeviceTransportTests {
    #if !os(Windows)
    /// RendezvousTestPeer, built beside this test bundle.
    #if os(Linux)
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
    #endif

    private struct Spawned {
        var pid: pid_t
        var socket: Int32
    }

    #if !os(Windows)
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

    #if !os(Windows)
    /// shm create (peer) -> fd pass (SCM_RIGHTS) -> map -> read status block (app).
    @Test func shmHelloRoundTrip() throws {
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
    }

    /// A hello with the wrong token is rejected, and the received fds are not leaked.
    @Test func wrongTokenIsRejected() throws {
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
    }
    #endif

    /// The status block, frame ring writer/reader, and the alpha-opaque blit,
    /// all in-process (no spawn). Runs on Windows too: the helper-side
    /// segments are pagefile-backed file mappings there (ShmSurface).
    /// Only the spawn-based tests above stay POSIX-gated (the Windows
    /// transport — loopback socket + hello — is not implemented yet).
    @Test func statusBlockAndFrameRingInProcess() {
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
    }

    /// WebProxyCA: create the CA files, reload them, mint a leaf for a host,
    /// and verify the leaf's RSA/SHA-1 signature against the CA public key.
    @Test func webProxyCAIssuesVerifiableLeaf() throws {
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
    }
}

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
