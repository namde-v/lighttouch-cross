import Foundation
import Testing

import DeviceRuntime

// Connect-mode proof against the REAL helper (not RendezvousTestPeer).
// Env-gated: skipped in the matrix Test step (no helper staged there);
// the LTD proof step sets LTM_CONNECT_HELPER_EXE to the built release
// helper with qemu-arm.dll beside it, then runs this test filtered.
// Tier-1 (ASSERTED): start() completes with a real HelperInfo (DLL path)
// + hello-request reply carrying host.info (LinkChannel JSON round-trip
// through the real helper, not the peer — the peer speaks no JSON).
// Tier-2 (RECORDED, NOT asserted): helper exits after terminate() —
// exit-on-link-close exercises onClose -> main.async shutdown; if the
// helper does not exit, the outcome is printed and the helper is killed,
// and the test still passes on Tier-1 (halt-on-idle semantics are a
// separate diagnostic, not a Tier-1 failure).

struct RealHelperConnectTests {
    @Test func realHelperConnectStartAndHelloReply() async throws {
        guard let helperPath = ProcessInfo.processInfo.environment["LTM_CONNECT_HELPER_EXE"],
              !helperPath.isEmpty
        else {
            print("CONNECT TEST SKIPPED: LTM_CONNECT_HELPER_EXE not set (matrix step runs without a staged helper)")
            return
        }
        try #require(
            FileManager.default.isExecutableFile(atPath: helperPath),
            "real helper missing at \(helperPath)"
        )
        // Dedicated queue: never .main — a CLI test process has no pumped
        // main queue on Linux or Windows, so main-queue callbacks would stall.
        let linkQueue = DispatchQueue(label: "test.realHelperConnect")
        var config = DeviceLink.Configuration(instance: Foundation.UUID(), outputDescriptor: -1)
        config.helper = URL(fileURLWithPath: helperPath)
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
        // Never leave a stray helper behind on any exit path (Tier-1 early
        // return included); killing an already-exited helper is a no-op.
        defer {
            if box.termination == nil { link.kill() }
        }
        let startGroup = DispatchGroup()
        let termGroup = DispatchGroup()
        startGroup.enter()
        termGroup.enter()
        link.onTerminated = { termination in
            box.setTermination(termination)
            termGroup.leave()
        }
        link.start { result in
            box.setResult(result)
            startGroup.leave()
        }
        // Tier-1a: start() completes. The real helper speaks JSON and stays
        // parked serving the link (unlike the peer, which exits), so only
        // the start leg is awaited here — termination is Tier-2 below.
        #expect(startGroup.wait(timeout: .now() + 30) == .success, "link start did not complete in 30 s")
        guard let result = box.result else {
            Issue.record("link start never completed")
            return
        }
        guard case .success(let info) = result else {
            Issue.record("link start failed: \(result)")
            return
        }
        #expect(info.protocolVersion == DeviceLinkWire.protocolVersion, "start HelperInfo protocol \(info.protocolVersion)")
        #expect(info.dylibPath.hasSuffix("qemu-arm.dll"), "start HelperInfo dylib should be the Windows DLL, got \(info.dylibPath)")
        #expect(link.status != nil, "status block should be set from the hello")

        // Tier-1b: hello-request reply through the real helper's LinkChannel.
        let reply = try await link.request(
            .hello(protocolVersion: DeviceLinkWire.protocolVersion, board: nil),
            timeout: 10
        )
        guard case .hello(let replyInfo) = reply else {
            Issue.record("expected .hello reply, got \(reply)")
            return
        }
        #expect(replyInfo.protocolVersion == DeviceLinkWire.protocolVersion, "reply protocol \(replyInfo.protocolVersion)")
        #expect(replyInfo.dylibPath.hasSuffix("qemu-arm.dll"), "reply dylib should be the Windows DLL, got \(replyInfo.dylibPath)")

        // Tier-2 (recorded, NOT asserted): terminate, wait bounded, print.
        link.terminate()
        if termGroup.wait(timeout: .now() + 15) == .success {
            print("TIER-2: helper terminated: \(String(describing: box.termination))")
        } else {
            print("TIER-2: helper did NOT exit within 15 s of terminate() — killing (halt-on-idle diagnostic, NOT a Tier-1 failure)")
            link.kill()
        }
    }
}
