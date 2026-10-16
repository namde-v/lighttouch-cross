#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation
import Testing

@testable import HostRuntime

struct PipeOutputTests {
    @Test func orderedDeliveryAndClosedConsumerAreNativeErrors() async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let reader = fds[0]
        let writer = fds[1]
        defer {
            _ = close(reader)
            _ = close(writer)
        }
        let output = PipeOutput(fileDescriptor: writer)
        output.write(Data("first\n".utf8))
        output.write(Data("second\n".utf8))
        #expect(await output.finish())
        var bytes = [UInt8](repeating: 0, count: 13)
        #expect(read(reader, &bytes, bytes.count) == bytes.count)
        #expect(String(decoding: bytes, as: UTF8.self) == "first\nsecond\n")
        output.stop()

        var closed: [Int32] = [0, 0]
        #expect(pipe(&closed) == 0)
        _ = close(closed[0])
        defer { _ = close(closed[1]) }
        let lost = PipeOutput(fileDescriptor: closed[1])
        #if os(Linux)
        // Linux has no F_GETNOSIGPIPE: PipeOutput ignores SIGPIPE process-wide
        // instead, so the EPIPE below surfaces as a delivery failure.
        var disposition = sigaction()
        sigaction(SIGPIPE, nil, &disposition)
        #expect(
            unsafeBitCast(disposition.__sigaction_handler.sa_handler, to: Int.self)
                == unsafeBitCast(SIG_IGN, to: Int.self),
            "SIGPIPE must stay ignored so EPIPE is a delivery failure, not a signal"
        )
        #else
        #expect(fcntl(closed[1], F_GETNOSIGPIPE) == 1)
        #endif
        lost.write(Data("no consumer\n".utf8))
        #expect(!(await lost.finish()), "EPIPE is a delivery failure, not a signal or Foundation exception")
        lost.stop()
    }

    @Test func stopJoinsQueuedWriteWithoutReadingFullPipe() async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer {
            _ = close(fds[0])
            _ = close(fds[1])
        }
        let output = PipeOutput(fileDescriptor: fds[1])
        // This exceeds the native pipe capacity, with no reader consuming data.
        output.write(Data(repeating: 0x61, count: 2 << 20))
        output.stop()
        #expect(await output.finish(), "cancelled delivery joins native callbacks without requiring a consumer")
        output.write(Data("after stop".utf8))
        #expect(await output.finish())
    }
}
