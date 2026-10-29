#if os(Windows)
import Foundation
import Testing

@testable import LightTouchDevice

// Phase 2 proof, LOAD-PATH ONLY: the DLL loads via the DEBUG LTM_QEMU_DLL
// override, reports C API major 2 (enforced by Qemu.load itself), and lists
// machines. NO mode tests here — machines/oneshot/headless/connect are
// Phase 3. buildID nil is tolerated: the Windows DLL's build_id is a stub
// returning NULL (run #11 smoke), so evaluating the lazy symbol must not
// trap, but its value carries no identity on Windows.
@Suite("QEMU DLL load path (Phase 2)")
struct QemuLoadTests {
    @Test("load via LTM_QEMU_DLL reports API 2 and lists machines")
    func loadPath() throws {
        let override = try #require(
            ProcessInfo.processInfo.environment["LTM_QEMU_DLL"],
            "LTM_QEMU_DLL must point at qemu-arm.dll (the proof step sets it)")
        try #require(!override.isEmpty, "LTM_QEMU_DLL is empty")
        let qemu = try Qemu.load()
        #expect(Qemu.apiMajor == 2)
        let machines = qemu.machines
        try #require(!machines.isEmpty, "qemu-arm.dll lists no machines (smoke listed n72ap at index 0)")
        try #require(!machines[0].board.isEmpty, "first machine has an empty board")
        if let buildID = qemu.buildID { _ = buildID() }
    }
}
#endif
