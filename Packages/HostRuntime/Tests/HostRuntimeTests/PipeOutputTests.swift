#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation
import Testing

import HostRuntime

struct PipeOutputTests {
    #if os(Windows)
    /// UCRT has no POSIX pipe(2): _pipe in binary mode, so no CRLF
    /// translation disturbs the byte counts below.
    private func checkPipe(_ fds: inout [Int32]) -> Bool { _pipe(&fds, 4096, _O_BINARY) == 0 }
    /// UCRT read(2) takes a UInt32 count, unlike POSIX size_t.
    private func checkRead(_ fd: Int32, _ bytes: inout [UInt8]) -> Bool {
        bytes.withUnsafeMutableBytes { ptr in
            read(fd, ptr.baseAddress, UInt32(ptr.count)) == Int32(ptr.count)
        }
    }
    #else
    private func checkPipe(_ fds: inout [Int32]) -> Bool { pipe(&fds) == 0 }
    private func checkRead(_ fd: Int32, _ bytes: inout [UInt8]) -> Bool {
        bytes.withUnsafeMutableBytes { ptr in
            read(fd, ptr.baseAddress, ptr.count) == ptr.count
        }
    }
    #endif

    @Test(.timeLimit(.seconds(60))) func orderedDeliveryAndClosedConsumerAreNativeErrors() async throws {
        var fds: [Int32] = [0, 0]
        #expect(checkPipe(&fds))
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
        #expect(checkRead(reader, &bytes))
        #expect(String(decoding: bytes, as: UTF8.self) == "first\nsecond\n")
        output.stop()

        var closed: [Int32] = [0, 0]
        #expect(checkPipe(&closed))
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
        #elseif os(Windows)
        // No SIGPIPE on Windows and no F_GETNOSIGPIPE: a write to a closed
        // pipe fails with an error, which is what the test asserts below.
        #else
        #expect(fcntl(closed[1], F_GETNOSIGPIPE) == 1)
        #endif
        lost.write(Data("no consumer\n".utf8))
        #expect(!(await lost.finish()), "EPIPE is a delivery failure, not a signal or Foundation exception")
        lost.stop()
    }

    @Test(.timeLimit(.seconds(60))) func stopJoinsQueuedWriteWithoutReadingFullPipe() async throws {
        var fds: [Int32] = [0, 0]
        #expect(checkPipe(&fds))
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
