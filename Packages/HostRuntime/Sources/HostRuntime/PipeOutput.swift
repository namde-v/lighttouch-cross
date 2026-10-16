#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation
import Synchronization

/// Native stream I/O preserves JSON-line ordering without holding cancellation
/// state across a blocking pipe write or occupying a cooperative worker.
public final class PipeOutput: Sendable {
    private struct State {
        var cancelled = false
        var pending = 0
        var failure: Int32?
        var waiters: [CheckedContinuation<Bool, Never>] = []
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "host-runtime.pipe-output")
    private let channel: DispatchIO

    #if os(Linux)
    /// Linux has no F_SETNOSIGPIPE, and writes go through DispatchIO (not
    /// send(), so MSG_NOSIGNAL is unavailable): ignore SIGPIPE process-wide
    /// once, so a write to a dead reader surfaces EPIPE from the channel
    /// instead of killing the process. Process-global like every signal
    /// disposition; unlike Darwin's per-descriptor fcntl it is also inherited
    /// by spawned subprocesses.
    private static let ignoreSIGPIPE: Bool = {
        _ = Glibc.signal(SIGPIPE, SIG_IGN)
        return true
    }()
    #endif

    public init(fileDescriptor: Int32) {
        #if os(Linux)
        _ = Self.ignoreSIGPIPE
        let signalError: Int32 = 0
        #elseif os(Windows)
        // No SIGPIPE on Windows; a write to a closed pipe fails with an error.
        let signalError: Int32 = 0
        #else
        // Darwin supports suppressing SIGPIPE on this descriptor without changing
        // signal dispositions inherited by unrelated subprocess descriptors.
        let signalError: Int32 = fcntl(fileDescriptor, F_SETNOSIGPIPE, 1) == -1 ? errno : 0
        #endif
        #if os(Windows)
        // dispatch_fd_t is a HANDLE on Windows, not a CRT descriptor.
        let handle = _get_osfhandle(fileDescriptor)
        channel = DispatchIO(type: .stream, fileDescriptor: handle, queue: queue) { _ in }
        #else
        channel = DispatchIO(type: .stream, fileDescriptor: fileDescriptor, queue: queue) { _ in }
        #endif
        if signalError != 0 { state.withLock { $0.failure = signalError } }
    }
    public func stop() {
        state.withLock { $0.cancelled = true }
        channel.close(flags: .stop)
    }
    public func write(_ data: Data) {
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        // Submission is nonblocking; the native stream channel serializes writes.
        state.withLock { state in
            guard !state.cancelled else { return }
            state.pending += 1
            channel.write(offset: 0, data: bytes, queue: queue) { [self] done, _, error in
                guard done else { return }
                let (waiters, success) = self.state.withLock { current -> ([CheckedContinuation<Bool, Never>], Bool) in
                    current.pending -= 1
                    if error != 0 && !current.cancelled { current.failure = error }
                    guard current.pending == 0 else { return ([], false) }
                    let waiters = current.waiters
                    current.waiters.removeAll()
                    return (waiters, current.failure == nil)
                }
                for waiter in waiters { waiter.resume(returning: success) }
            }
        }
    }
    /// Joins every queued native callback. True means no recorded delivery
    /// error; after stop it does not certify that cancelled bytes were delivered.
    public func finish() async -> Bool {
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { state -> Bool? in
                guard state.pending != 0 else { return state.failure == nil }
                state.waiters.append(continuation)
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
}
