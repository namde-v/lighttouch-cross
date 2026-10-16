import Testing

@testable import HostRuntime

struct DebugPortTests {
    @Test func freeLoopbackPortAndArguments() throws {
        let port = try #require(DebugPort.freePort())
        #expect((1024...65535).contains(port))
        #expect(DebugPort.arguments(port: port) == ["-gdb", "tcp:127.0.0.1:\(port)"])
    }

    @Test func lldbCommandPerBoard() {
        #expect(DebugPort.lldbCommand(board: "m68ap", port: 4321).contains("--arch armv6-apple-ios"))
        #expect(DebugPort.lldbCommand(board: "k48ap", port: 4321).contains("--arch armv7-apple-ios"))
        #expect(DebugPort.lldbCommand(board: "n81ap", port: 4321).contains("gdb-remote 127.0.0.1:4321"))
    }
}
