import Foundation
#if os(Linux)
import Glibc
// The struct stat's initializer is defined here, not in Glibc's overlay
// (the compiler's MemberImportVisibility diagnostic insists on it).
import CoreFoundation
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import HostServiceWire
#if os(Windows)
import HostRuntime  // winOpen (CreateFileW + _open_osfhandle); POSIX open() is broken on this toolchain.
#endif


/// Synchronous low-level writer shared by pipe readers. The lock protects the
/// entire rotate/write operation. The file stays open between appends and its
/// size is tracked here (an append is one write, not a stat, open, chmod and
/// close); it is reopened after a rotation, or when the path no longer names
/// the open file (deleted or replaced under it). This bounds disk usage without
/// truncating a live subprocess's file.
public nonisolated final class RotatingLog: @unchecked Sendable {
    public let url: URL
    private let limit: Int
    private let lock = NSLock()
    private var failed = false
    private var fd: Int32 = -1
    private var size = 0
    #if os(Windows)
    // No dev_t/ino_t or stat(2) on Windows: the file's identity is its volume
    // serial + file index (GetFileInformationByHandle).
    private var volumeSerial: DWORD = 0, fileIndex: UInt64 = 0
    #else
    private var device: dev_t = 0, inode: ino_t = 0
    #endif
    private static let logger = LTMLogger(subsystem: StorageLocations.bundleIdentifier, category: "log-storage")

    public init(url: URL, limit: Int = StorageLocations.logLimit) {
        self.url = url
        self.limit = limit
    }

    deinit { if fd >= 0 { close(fd) } }

    public func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !failed, !data.isEmpty else { return }
        do {
            let bounded = data.suffix(limit)
            if fd >= 0, !pathNamesOpenFile() { closeFile() }
            if fd < 0 { try openFile() }
            if size + bounded.count > limit {
                closeFile()
                try Self.rotate(url)
                try openFile()
            }
            try FileHandle(fileDescriptor: fd).write(contentsOf: bounded)
            size += bounded.count
        } catch {
            closeFile()
            failed = true
            Self.logger.error("Cannot write diagnostic log: \(error.localizedDescription)")
        }
    }

    /// Open (create) the file for appending: a regular file only, never through a symlink, owner-only.
    private func openFile() throws {
        try StorageLocations.privateDirectory(url.deletingLastPathComponent())
        // Checked before open: opening a FIFO for writing would block here.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let type = attributes?[.type] as? FileAttributeType, type != .typeRegular {
            throw CocoaError(.fileWriteUnknown)
        }
        #if os(Windows)
        // No O_CLOEXEC/O_NOFOLLOW/lstat(2)/fchmod(2) on Windows: refuse
        // reparse points (symlinks, junctions) up front, open append-only
        // without inheriting the descriptor, and identify the file by volume
        // serial + file index. A file the app creates in its own log
        // directory is owner-only by default ACL.
        let wide = Array(url.path.utf16) + [0]
        let fileAttributes: DWORD = wide.withUnsafeBufferPointer { GetFileAttributesW($0.baseAddress!) }
        if fileAttributes != DWORD(bitPattern: Int32(-1)),
            fileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0
        {
            throw CocoaError(.fileWriteUnknown)
        }
        let descriptor = winOpen(url.path, write: true, create: true, append: true)
        guard descriptor >= 0 else { throw StorageLocations.posixError() }
        let raw = _get_osfhandle(descriptor)
        guard raw != -1, let handle = UnsafeMutableRawPointer(bitPattern: raw) else {
            close(descriptor)
            throw StorageLocations.posixError()
        }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info),
            info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
        else {
            close(descriptor)
            throw CocoaError(.fileWriteUnknown)
        }
        fd = descriptor
        size = Int(UInt64(info.nFileSizeHigh) << 32 | UInt64(info.nFileSizeLow))
        volumeSerial = info.dwVolumeSerialNumber
        fileIndex = UInt64(info.nFileIndexHigh) << 32 | UInt64(info.nFileIndexLow)
        #else
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw StorageLocations.posixError() }
        var st = Glibc.stat()
        guard fstat(descriptor, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, fchmod(descriptor, 0o600) == 0 else {
            let error = StorageLocations.posixError()
            close(descriptor)
            throw error
        }
        fd = descriptor
        size = Int(st.st_size)
        device = st.st_dev
        inode = st.st_ino
        #endif
    }

    private func closeFile() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    private func pathNamesOpenFile() -> Bool {
        #if os(Windows)
        // The open file is still the path's file when a fresh open of the
        // path yields the same volume serial + file index.
        let descriptor = winOpen(url.path, read: true)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let raw = _get_osfhandle(descriptor)
        guard raw != -1, let handle = UnsafeMutableRawPointer(bitPattern: raw) else { return false }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else { return false }
        return info.dwVolumeSerialNumber == volumeSerial
            && (UInt64(info.nFileIndexHigh) << 32 | UInt64(info.nFileIndexLow)) == fileIndex
        #else
        var st = Glibc.stat()
        return lstat(url.path, &st) == 0 && st.st_dev == device && st.st_ino == inode
        #endif
    }

    public static func rotate(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let previous = url.appendingPathExtension("1")
        // POSIX rename replaces the previous generation atomically.
        guard rename(url.path, previous.path) == 0 else { throw StorageLocations.posixError() }
    }
}

/// Dispatch sources are the bridge to descriptors owned by native code. Each
/// callback drains at most one bounded chunk; no unbounded async Data queue or
/// per-line allocation can accumulate behind a noisy native writer.
public nonisolated final class LogPipeReader: @unchecked Sendable {
    #if os(Windows)
    // DispatchSource.read never fires for Windows pipes: libdispatch is handed
    // the CRT fd rather than a HANDLE, and pipe HANDLEs trip its known Windows
    // bugs (read-side spin, write-side block). A dedicated thread does blocking
    // reads instead; closing the descriptor unblocks it. `stopped` also guards
    // the idempotent close: finish() and deinit may both run.
    //
    // A class (not Synchronization.Mutex, which is non-copyable and cannot be
    // captured by the thread): the thread must not retain self, or a reader
    // dropped without finish() would leak the blocked thread.
    private final class ReaderState: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var watch: LogWatch?
        var isStopped: Bool {
            lock.lock(); defer { lock.unlock() }; return stopped
        }
        func setWatch(_ watch: LogWatch?) {
            lock.lock(); defer { lock.unlock() }; self.watch = watch
        }
        func scan(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }; watch?.scan(chunk)
        }
        /// Marks stopped; returns true for the first caller, which closes the
        /// descriptor to unblock the reader thread.
        func stopFirst() -> Bool {
            lock.lock(); defer { lock.unlock() }
            defer { stopped = true }
            return !stopped
        }
        func markStopped() {
            lock.lock(); defer { lock.unlock() }; stopped = true
        }
    }
    private let readerState = ReaderState()
    #else
    private let source: any DispatchSourceRead
    private let queue: DispatchQueue
    // Accessed only on queue, including EOF and explicit teardown.
    private var stopped = false
    /// Phrases to report the first time they pass through (LogWatch), on the reader's queue.
    private var watch: LogWatch?
    #endif
    private let descriptor: Int32
    private let cancellation = DispatchGroup()
    private let log: RotatingLog

    /// Bytes in, `onMatch(phrase)` once per phrase, across chunk boundaries.
    /// Thread-safe: on Windows the reader thread and flush() may scan concurrently.
    public nonisolated final class LogWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Data]
        private var tail = Data()
        private let onMatch: @Sendable (String) -> Void
        public init(phrases: [String], onMatch: @escaping @Sendable (String) -> Void) {
            pending = phrases.map { Data($0.utf8) }
            self.onMatch = onMatch
        }
        public func scan(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !pending.isEmpty else { return }
            let window = tail + chunk
            for phrase in pending where window.range(of: phrase) != nil {
                pending.removeAll { $0 == phrase }
                onMatch(String(decoding: phrase, as: UTF8.self))
            }
            let keep = pending.map(\.count).max() ?? 0
            tail = keep > 1 ? window.suffix(keep - 1) : Data()
        }
    }

    public init(descriptor: Int32, log: RotatingLog, watch: LogWatch? = nil, cleanup: (@Sendable () -> Void)? = nil)
        throws
    {
        #if os(Windows)
        // No fcntl O_NONBLOCK on Windows; the reader thread blocks in read().
        #else
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw StorageLocations.posixError()
        }
        #endif
        self.descriptor = descriptor
        self.log = log
        #if os(Windows)
        readerState.setWatch(watch)
        // Capture state piecemeal: the thread must not retain self, or a
        // reader dropped without finish() would leak the blocked thread.
        let readerState = self.readerState
        let cancellation = self.cancellation
        let log = self.log
        cancellation.enter()
        let thread = Thread {
            var bytes = [UInt8](repeating: 0, count: 32_768)
            while !readerState.isStopped {
                // UCRT read takes a UInt32 count and returns Int32; it blocks
                // until bytes arrive or the write end closes (EOF, count 0).
                let count = read(descriptor, &bytes, UInt32(bytes.count))
                guard count > 0 else { break }
                let chunk = Data(bytes.prefix(Int(count)))
                log.append(chunk)
                readerState.scan(chunk)
            }
            readerState.markStopped()
            cleanup?()
            cancellation.leave()
        }
        thread.name = "LightTouch.log.\(log.url.lastPathComponent)"
        thread.qualityOfService = .utility
        thread.start()
        #else
        self.watch = watch
        self.queue = DispatchQueue(label: "LightTouch.log.\(log.url.lastPathComponent)", qos: .utility)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readChunk() }
        let cancellation = self.cancellation
        cancellation.enter()
        source.setCancelHandler {
            close(descriptor)
            cleanup?()
            cancellation.leave()
        }
        source.resume()
        #endif
    }

    #if os(Windows)
    /// The first caller closes the descriptor, unblocking the reader thread's
    /// read(); later callers (finish() after deinit, or vice versa) no-op.
    private func stopReading() {
        if readerState.stopFirst() { close(descriptor) }
    }
    #endif

    #if os(Windows)
    /// Bytes waiting in the pipe: the non-blocking read check (no O_NONBLOCK
    /// on Windows).
    private func availableBytes() -> DWORD {
        let raw = _get_osfhandle(descriptor)
        guard raw != -1, let handle = UnsafeMutableRawPointer(bitPattern: raw) else { return 0 }
        var available: DWORD = 0
        guard PeekNamedPipe(handle, nil, 0, nil, &available, nil) else { return 0 }
        return available
    }
    #endif

    #if !os(Windows)
    private func readChunk() {
        guard !stopped else { return }
        var bytes = [UInt8](repeating: 0, count: 32_768)
        let count = read(descriptor, &bytes, bytes.count)
        if count > 0 {
            let chunk = Data(bytes.prefix(Int(count)))
            log.append(chunk)
            watch?.scan(chunk)
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            stopped = true
            source.cancel()
        }
    }
    #endif

    public func flush() {
        #if os(Windows)
        guard !readerState.isStopped else { return }
        var bytes = [UInt8](repeating: 0, count: 32_768)
        // Bounded drain: the reader thread drains concurrently, so bytes land
        // in the log either way; this just hurries stragglers along.
        for _ in 0..<32 {
            // No O_NONBLOCK on Windows: only read when the pipe holds bytes.
            guard availableBytes() > 0 else { break }
            let count = read(descriptor, &bytes, UInt32(bytes.count))
            guard count > 0 else { break }
            let chunk = Data(bytes.prefix(Int(count)))
            log.append(chunk)
            readerState.scan(chunk)
        }
        // Settle: the reader thread may be appending a chunk it read just
        // before this drain ran.
        Thread.sleep(forTimeInterval: 0.05)
        #else
        queue.sync {
            guard !stopped else { return }
            var bytes = [UInt8](repeating: 0, count: 32_768)
            // Bounded drain: a live writer cannot hold a UI flush forever.
            for _ in 0..<32 {
                let count = read(descriptor, &bytes, bytes.count)
                guard count > 0 else { break }
                let chunk = Data(bytes.prefix(Int(count)))
                log.append(chunk)
                watch?.scan(chunk)
            }
        }
        #endif
    }

    public func finish() {
        #if os(Windows)
        stopReading()
        #else
        flush()
        queue.sync {
            guard !stopped else { return }
            stopped = true
            source.cancel()
        }
        #endif
        cancellation.wait()
    }

    #if os(Windows)
    deinit {
        stopReading()
        // Don't wait: the thread exits on its own once the read unblocks.
    }
    #else
    deinit { source.cancel() }
    #endif
}

/// The owning subprocess task holds this until its child has stopped. stdout
/// and stderr share one pipe, preserving their kernel write ordering.
public nonisolated final class ProcessLogCapture: Sendable {
    public let writeDescriptor: Int32
    private let reader: LogPipeReader

    public init(url: URL) throws {
        var descriptors: [Int32] = [-1, -1]
        #if os(Windows)
        // No pipe(2) on Windows: _pipe makes the pipe; _O_BINARY keeps bytes
        // intact and _O_NOINHERIT keeps the descriptors out of children.
        guard _pipe(&descriptors, 65536, _O_BINARY | _O_NOINHERIT) == 0 else {
            throw StorageLocations.posixError()
        }
        #else
        guard pipe(&descriptors) == 0 else { throw StorageLocations.posixError() }
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        #endif
        do {
            reader = try LogPipeReader(descriptor: descriptors[0], log: RotatingLog(url: url))
            writeDescriptor = descriptors[1]
        } catch {
            close(descriptors[0])
            close(descriptors[1])
            throw error
        }
    }

    public func flush() { reader.flush() }
    deinit {
        close(writeDescriptor)
        reader.finish()
    }
}

/// QEMU's supported pipe backend opens <path>.in/.out. These are private,
/// session-owned FIFOs in the system temporary directory, never durable state.
public nonisolated final class SerialLogCapture: Sendable {
    public let argument: String
    private let directory: URL
    private let reader: LogPipeReader

    /// `watch`: phrases reported the first time the guest prints them (iBoot's
    /// "Entering recovery mode"), from the reader's queue.
    public init(
        url: URL,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        watch: [String] = [],
        onMatch: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        #if os(Windows)
        // No FIFOs on Windows, and QEMU's pipe chardev backend isn't wired up
        // there; nothing in the app constructs this on Windows.
        throw DeviceToolsError.failed("Serial pipe capture isn't supported on Windows.")
        #else
        let directory = temporaryRoot.appendingPathComponent(
            "LightTouch-serial-\(UUID().uuidString)",
            isDirectory: true
        )
        self.directory = directory
        try StorageLocations.privateDirectory(directory)
        var descriptor: Int32 = -1
        do {
            let path = directory.appendingPathComponent("serial").path
            guard mkfifo(path + ".in", 0o600) == 0, mkfifo(path + ".out", 0o600) == 0 else {
                throw StorageLocations.posixError()
            }
            descriptor = open(path + ".out", O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw StorageLocations.posixError() }
            reader = try LogPipeReader(
                descriptor: descriptor,
                log: RotatingLog(url: url),
                watch: watch.isEmpty ? nil : .init(phrases: watch, onMatch: onMatch)
            ) {
                try? FileManager.default.removeItem(at: directory)
            }
            argument = "pipe:" + path
        } catch {
            if descriptor >= 0 { close(descriptor) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        #endif
    }

    /// Normal app quit can leave QEMU running until process exit. Unlinking
    /// FIFO names is safe while its open descriptors remain usable; closing the
    /// reader here instead could deliver SIGPIPE to the still-running VM.
    public func removeEndpoints() { try? FileManager.default.removeItem(at: directory) }

    /// Use only after QEMU has returned and can no longer write serial data.
    public func finish() { reader.finish() }
}

@MainActor public enum NativeLogging {
    private static var capture: ProcessLogCapture?

    /// QEMU is linked into the app, so its C diagnostics share process stdout/stderr.
    /// Unified app events use Logger separately and are not mirrored here.
    public static func start() throws {
        guard capture == nil else { return }
        let pipe = try ProcessLogCapture(url: Bundled.logsDirectory.appendingPathComponent("native.log"))
        fflush(nil)
        let savedError = dup(STDERR_FILENO)
        guard savedError >= 0 else { throw StorageLocations.posixError() }
        defer { close(savedError) }
        guard dup2(pipe.writeDescriptor, STDERR_FILENO) >= 0 else { throw StorageLocations.posixError() }
        guard dup2(pipe.writeDescriptor, STDOUT_FILENO) >= 0 else {
            let error = StorageLocations.posixError()
            _ = dup2(savedError, STDERR_FILENO)
            throw error
        }
        capture = pipe
    }

    public static func flush() {
        fflush(nil)
        capture?.flush()
    }
}
