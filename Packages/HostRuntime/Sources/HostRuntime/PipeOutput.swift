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
    #if os(Windows)
    /// Our own duplicate of the pipe's write HANDLE (from the fd via
    /// _get_osfhandle). stop() closes the duplicate to interrupt a blocked
    /// WriteFile, leaving the caller's fd untouched.
    private let handle: UnsafeMutableRawPointer?
    private let handleClosed = Mutex(false)
    #else
    private let channel: DispatchIO
    #endif

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
        #if os(Windows)
        // dispatch_fd_t is a HANDLE on Windows, not a CRT descriptor.
        // Duplicate it so stop() can close our copy (interrupting a blocked
        // WriteFile) without touching the caller's fd.
        var dup: HANDLE? = nil
        let raw = _get_osfhandle(fileDescriptor)
        if raw != -1,
           DuplicateHandle(
               GetCurrentProcess(), UnsafeMutableRawPointer(bitPattern: raw),
               GetCurrentProcess(), &dup, 0, false, DWORD(DUPLICATE_SAME_ACCESS))
        {
            handle = dup
        } else {
            handle = nil
        }
        // No SIGPIPE on Windows; a write to a closed pipe fails with an error.
        #else
        #if os(Linux)
        _ = Self.ignoreSIGPIPE
        let signalError: Int32 = 0
        #else
        // Darwin supports suppressing SIGPIPE on this descriptor without changing
        // signal dispositions inherited by unrelated subprocess descriptors.
        let signalError: Int32 = fcntl(fileDescriptor, F_SETNOSIGPIPE, 1) == -1 ? errno : 0
        #endif
        channel = DispatchIO(type: .stream, fileDescriptor: fileDescriptor, queue: queue) { _ in }
        if signalError != 0 { state.withLock { $0.failure = signalError } }
        #endif
    }
    public func stop() {
        state.withLock { $0.cancelled = true }
        #if os(Windows)
        // Interrupt a WriteFile blocked on a full pipe (no reader): closing our
        // duplicate handle fails it with ERROR_INVALID_HANDLE. Closing is
        // persistent state (unlike CancelIoEx, which is edge-triggered), so
        // there is no race with a write that hasn't started yet — it will see
        // `cancelled`. The caller's fd is untouched.
        let closeIt = handleClosed.withLock { closed -> Bool in
            if closed { return false }
            closed = true
            return true
        }
        if closeIt, let handle { CloseHandle(handle) }
        #else
        channel.close(flags: .stop)
        #endif
    }
    public func write(_ data: Data) {
        #if os(Windows)
        let enqueue = state.withLock { state -> Bool in
            guard !state.cancelled else { return false }
            state.pending += 1
            return true
        }
        guard enqueue else { return }
        // Copy: the blocking write happens on the queue's thread.
        let bytes = Array(data)
        queue.async { [self] in self.performWrite(bytes) }
        #else
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
        #endif
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

    #if os(Windows)
    /// One ordered blocking write on the serial queue. A write aborted by
    /// stop() (ERROR_INVALID_HANDLE from the closed handle) is cancellation,
    /// not a delivery failure.
    private func performWrite(_ bytes: [UInt8]) {
        var error: Int32?
        let cancelled = state.withLock { $0.cancelled }
        if !cancelled {
            if let handle {
                error = writeAll(handle, bytes)
            } else {
                error = Int32(ERROR_INVALID_HANDLE)
            }
        }
        let (waiters, success) = state.withLock { current -> ([CheckedContinuation<Bool, Never>], Bool) in
            current.pending -= 1
            if let error, !current.cancelled { current.failure = error }
            guard current.pending == 0 else { return ([], false) }
            let waiters = current.waiters
            current.waiters.removeAll()
            return (waiters, current.failure == nil)
        }
        for waiter in waiters { waiter.resume(returning: success) }
    }

    /// Blocking WriteFile loop; nil on full delivery, the Win32 error else.
    /// A WriteFile blocked on a full pipe is interrupted by stop()'s
    /// CloseHandle, which fails it with ERROR_INVALID_HANDLE.
    private func writeAll(_ handle: UnsafeMutableRawPointer, _ bytes: [UInt8]) -> Int32? {
        var offset = 0
        while offset < bytes.count {
            let chunk = min(bytes.count - offset, 1 << 20)
            var written = DWORD(0)
            let ok: Bool = bytes.withUnsafeBytes { ptr in
                WriteFile(
                    handle,
                    ptr.baseAddress!.advanced(by: offset),
                    DWORD(chunk),
                    &written,
                    nil
                )
            }
            guard ok else { return Int32(GetLastError()) }
            // A blocking pipe WriteFile delivers all-or-fails; advance by what
            // it reports and loop defensively anyway.
            offset += Int(written)
            if written == 0 { return Int32(ERROR_NO_DATA) }
        }
        return nil
    }
    #endif
}
