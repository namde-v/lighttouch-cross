import Foundation
import Testing

import DeviceRuntime

// DeviceLink.start() end to end against RendezvousTestPeer: the peer speaks
// the shm hello but NOT the JSON control protocol, so a link start must fail
// cleanly (no hang, no crash) once the peer exits, and report termination.
// This exercises, on every platform: spawn (socketpair on POSIX, loopback
// pair on Windows) -> hello -> LinkChannel up -> peer exit -> invalidate +
// reap. The success path (JSON hello reply) needs a JSON-speaking helper,
// which does not exist in-repo yet; it is NOT covered here (see
// TRANSPORT_REDESIGN.md).

// Anchor for the test-bundle directory on Darwin; named differently from
// DeviceTransportTests' BundleAnchor (a duplicate definition in the same
// module would fail to compile).
private final class DeviceLinkTestAnchor {}

// DIAGNOSTIC (temporary): same stderr-timeline rationale as diagTransport.
private func diagLink(_ message: String) {
    if let data = ("DIAG-LINK \(message)\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

@Suite(.serialized) struct DeviceLinkTests {
    /// RendezvousTestPeer, built beside this test bundle (same layout as
    /// DeviceTransportTests.peer).
    #if os(Windows)
    private let peer: URL = {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
        return exe.deletingLastPathComponent().appendingPathComponent("RendezvousTestPeer.exe")
    }()
    #elseif os(Linux)
    private let peer: URL = {
        let exe = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe"))
            .map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return exe.deletingLastPathComponent().appendingPathComponent("RendezvousTestPeer")
    }()
    #else
    private let peer = Bundle(for: DeviceLinkTestAnchor.self).bundleURL
        .deletingLastPathComponent().appendingPathComponent("RendezvousTestPeer")
    #endif

    /// Link start against the test peer fails cleanly and reports termination.
    /// The peer sends a valid shm hello, then exits (it speaks no JSON), so
    /// start() must: complete with .failure, never hang, and report the
    /// peer's exit (0) via onTerminated. The link's status block must be set
    /// (the hello was mapped) even though the link then failed.
    // DIAGNOSTIC round 3 (temporary): mirror of round 2. Round 2 proved
    // transport tests pass alone on Windows (4/4 green, link skipped), so
    // the death REQUIRES the link test's presence. This round runs the link
    // test ALONE: if it dies alone, the link path itself is broken; if it
    // passes alone, the death was the parallel-suite interaction. Revert
    // once determined.
    @Test func linkStartWithNonJSONPeerFailsCleanlyAndReportsTermination() throws {
        diagLink("link test started")
        try #require(
            FileManager.default.isExecutableFile(atPath: peer.path),
            "test peer missing at \(peer.path)"
        )
        diagLink("peer executable ok")
        // Dedicated queue: never .main — a CLI test process has no pumped
        // main queue on Linux or Windows, so main-queue callbacks would stall.
        let linkQueue = DispatchQueue(label: "test.deviceLink")
        var config = DeviceLink.Configuration(instance: Foundation.UUID(), outputDescriptor: -1)
        config.helper = peer
        let link = DeviceLink(configuration: config, queue: linkQueue)

        // Locked boxes: callbacks arrive on linkQueue, assertions run here.
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var _result: Result<HelperInfo, DeviceLinkError>?
            private var _termination: DeviceTermination?
            var result: Result<HelperInfo, DeviceLinkError>? { lock.withLock { _result } }
            var termination: DeviceTermination? { lock.withLock { _termination } }
            func setResult(_ r: Result<HelperInfo, DeviceLinkError>) { lock.withLock { _result = r } }
            func setTermination(_ t: DeviceTermination) { lock.withLock { _termination = t } }
        }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        group.enter()
        link.onTerminated = { termination in
            diagLink("terminated fired: \(termination)")
            box.setTermination(termination)
            group.leave()
        }
        link.start { result in
            diagLink("completion fired: \(result)")
            box.setResult(result)
            group.leave()
        }
        diagLink("start called")
        // The peer exits on its own (immediately on POSIX, after the 2 s
        // Windows linger), so 30 s is a generous bound: a hang here is a
        // failure, not a slow test.
        let completed = group.wait(timeout: .now() + 30) == .success
        diagLink("wait done: completed=\(completed) result=\(String(describing: box.result)) termination=\(String(describing: box.termination))")
        #expect(completed, "link start + termination did not complete in 30 s")
        guard let result = box.result else {
            Issue.record("link start never completed")
            return
        }
        if case .success = result {
            Issue.record("expected link start to fail (peer speaks no JSON), got success")
        }
        #expect(box.termination == .exited(0), "expected peer exit 0, got \(String(describing: box.termination))")
        #expect(link.status != nil, "status block should be set from the hello even though the link then failed")
    }
}
