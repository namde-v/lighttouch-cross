#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation
import HostRuntime
import LTMShm

#if os(Windows)
// UCRT's signal.h has no SIGKILL (a Windows process can't be killed by
// signal); the value is documentation only: ltmKill terminates the process
// outright on Windows (see PlatformLibc.swift), so terminate() and kill()
// both terminate there — there is no SIGTERM/SIGKILL distinction.
private let SIGKILL: Int32 = 9
#endif

// The app's handle on one running LightTouchDevice helper.
//
// (Linux redesign; macOS used a bootstrap rendezvous + IOSurface Mach ports.)
//
//     let link = DeviceLink(configuration: .init(instance: id, outputDescriptor: capture.writeDescriptor))
//     link.onEvent = { event in … }                  // .qemuExited, .audio…
//     link.onInvalidated = { error in … }            // link lost (EOF, bad hello, protocol)
//     link.onTerminated = { termination in … }       // the helper process is gone
//     link.start { result in                          // spawn + shm hello + hello
//         guard case .success(let info) = result else { … }
//         link.request(.boot(config)) { … }
//     }
//     link.send(.touch(slot: 0, phase: 0, x: 0.5, y: 0.5))
//     let status = link.status                        // SharedStatus?, synchronous
//     if let frame = link.frontSurface(), frame.isNew { /* composite frame.surface's shm pixels */ }
//
// Every callback runs on `queue` (main by default). All methods may be called
// from any thread except `frontSurface()`, which belongs to one reader.

nonisolated public enum DeviceLinkError: Error, Equatable, CustomStringConvertible {
    case spawnFailed(Int32)
    case rendezvous(String)
    case rejected(String)
    case timedOut
    case protocolMismatch(helper: Int)
    case helperFailure(String)
    case closed(String)

    public var description: String {
        switch self {
        case .spawnFailed(let e): "could not start the device helper (\(String(cString: strerror(e))))"
        case .rendezvous(let s): "device helper rendezvous failed: \(s)"
        case .rejected(let s): "device helper rejected: \(s)"
        case .timedOut: "the device helper did not answer in time"
        case .protocolMismatch(let v): "device helper speaks protocol \(v), expected \(DeviceLinkWire.protocolVersion)"
        case .helperFailure(let s): s
        case .closed(let s): "device helper link closed: \(s)"
        }
    }
}

nonisolated public enum DeviceTermination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    /// Someone else reaped it; the status is lost.
    case unknown
}

nonisolated public final class DeviceLink: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// The helper beside the running executable.
        public static let bundledHelper: URL = {
            guard let executable = Bundle.main.executableURL else {
                preconditionFailure("A running process has an executable")
            }
            #if os(Windows)
            // Windows executables carry the .exe suffix: the extensionless
            // macOS name never matches the staged LightTouchDevice.exe beside
            // the running executable (LightTouch/), so boot lookup missed
            // exactly like the app-helper path and CLI sibling fallback did
            // before their fixes.
            return executable.deletingLastPathComponent().appendingPathComponent("LightTouchDevice.exe")
            #else
            return executable.deletingLastPathComponent().appendingPathComponent("LightTouchDevice")
            #endif
        }()
        public var helper: URL = bundledHelper
        public var instance: Foundation.UUID
        /// The helper's stdout + stderr, e.g. ProcessLogCapture.writeDescriptor
        /// for Devices/<uuid>/native.log. -1: /dev/null.
        public var outputDescriptor: Int32 = -1
        /// Development: the libqemu-arm.dylib to load (LTM_QEMU_DYLIB). nil: the
        /// helper's own @executable_path/../Frameworks, then its build rpath.
        public var dylib: String? = nil
        /// Extra environment for the helper process (QEMU's boot env goes in BootConfig).
        public var environment: [String: String] = [:]
        /// The board ID for hello's deviceInfo.
        public var board: String? = nil
        /// Spawn -> shm hello + hello reply.
        public var connectTimeout: TimeInterval = 15
        /// The device's lease (HelperLaunch.lease).
        public var lease: URL?

        public init(instance: Foundation.UUID, outputDescriptor: Int32 = -1) {
            self.instance = instance
            self.outputDescriptor = outputDescriptor
        }
    }

    public let configuration: Configuration
    public let queue: DispatchQueue

    public var onEvent: ((LinkEvent) -> Void)?
    /// The link is unusable (fires once). The process may still be exiting.
    public var onInvalidated: ((DeviceLinkError) -> Void)?
    /// The helper process is gone (fires once, after onInvalidated if the link was up).
    public var onTerminated: ((DeviceTermination) -> Void)?

    private let lock = NSLock()
    private var _pid: pid_t = 0
    private var channel: LinkChannel<HelperMessage, AppMessage>?
    private var statusBlock: StatusBlock?
    private var ring: FrameRingReader?
    private var _info: HelperInfo?
    private var nextID: UInt64 = 1
    public typealias Reply = @Sendable (Result<LinkReply, DeviceLinkError>) -> Void
    private struct Pending: @unchecked Sendable {
        let timer: DispatchWorkItem
        let reply: Reply
    }
    private var pending: [UInt64: Pending] = [:]
    private var invalidated = false
    private var startCompletion: (@Sendable (Result<HelperInfo, DeviceLinkError>) -> Void)?

    public init(configuration: Configuration, queue: DispatchQueue = .main) {
        self.configuration = configuration
        self.queue = queue
    }

    /// Dropping the link closes the socket: EOF asks the helper to halt QEMU.
    /// The bounded host halt does not imply a guest filesystem shutdown.
    /// (The exit watcher thread still reaps the child, so no zombie is left.)
    deinit {
        channel?.close()
    }

    public var pid: pid_t { lock.withLock { _pid } }
    /// The hello reply: protocol, dylib path + mtime, build id, device info.
    public var info: HelperInfo? { lock.withLock { _info } }
    /// The status block, read now. nil until the helper's hello.
    public var status: SharedStatus? { lock.withLock { statusBlock }?.snapshot() }

    /// The front frame segment. `isNew` when it changed since the last call.
    /// Call from one thread only (the display link); hold the surface, not the tuple.
    /// The pixels are BGRA, sRGB, at `surface.baseAddress` (see SharedStatus.swift).
    public func frontSurface() -> (surface: ShmSurface, serial: UInt64, isNew: Bool)? {
        lock.withLock { ring }?.front()
    }

    // MARK: - Start

    /// Spawn the helper and connect. Completes once, on `queue`.
    ///
    /// The helper is spawned with a private link socket (a socketpair on POSIX,
    /// a loopback TCP pair on Windows; the child's end is fd 3 on POSIX, the
    /// inherited client socket on Windows) and a one-time token on its argv. Its first bytes on the socket are the shm
    /// hello (DeviceRendezvous); only then does the JSON control channel come
    /// up. There is no shared rendezvous namespace and no code-signing
    /// attestation: a process the app did not spawn cannot hold the socket.
    public func start(completion: @escaping @Sendable (Result<HelperInfo, DeviceLinkError>) -> Void) {
        #if os(Windows)
        // Windows has no socketpair (Winsock has none). Build the loopback
        // pair exactly like the spawn tests do (DeviceTransportTests.spawnPeer):
        // listener on 127.0.0.1:0, client connects, accept gives the app's end.
        // The child inherits the CONNECTED client socket (ltm_spawn +
        // LTM_LINK_SOCKET); the app reads the hello on the accepted socket.
        // WSAStartup is refcounted and process-wide; no WSACleanup here —
        // other links share Winsock for the life of the app, same as the
        // spawn tests.
        var wsadata = WSADATA()
        guard WSAStartup(0x0202, &wsadata) == 0 else {
            return queue.async { completion(.failure(.spawnFailed(WSAGetLastError()))) }
        }
        // IPPROTO_TCP is 6 (winsock2.h); the overlay types it IPPROTO, not
        // Int32, so spell the value out (same precedent as 0xF001F for
        // FILE_MAP_ALL_ACCESS in SharedStatus.swift).
        let listener = socket(AF_INET, SOCK_STREAM, 6)
        guard listener != INVALID_SOCKET else {
            return queue.async { completion(.failure(.spawnFailed(WSAGetLastError()))) }
        }
        var addr = sockaddr_in()
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        // inet_addr returns UInt32 in the overlay, not in_addr, and in_addr's
        // union members aren't addressable from Swift — write the 4
        // network-order bytes directly (same as the spawn tests).
        withUnsafeMutableBytes(of: &addr.sin_addr) { $0.storeBytes(of: inet_addr("127.0.0.1"), as: UInt32.self) }
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, SOMAXCONN) == 0 else {
            let e = WSAGetLastError()
            closesocket(listener)
            return queue.async { completion(.failure(.spawnFailed(e))) }
        }
        // Bound port (network order — copied as-is to the client, no htons dance).
        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &boundLen)
            }
        }
        guard gotName == 0 else {
            let e = WSAGetLastError()
            closesocket(listener)
            return queue.async { completion(.failure(.spawnFailed(e))) }
        }
        let client = socket(AF_INET, SOCK_STREAM, 6)
        guard client != INVALID_SOCKET else {
            let e = WSAGetLastError()
            closesocket(listener)
            return queue.async { completion(.failure(.spawnFailed(e))) }
        }
        var clientAddr = sockaddr_in()
        clientAddr.sin_family = ADDRESS_FAMILY(AF_INET)
        withUnsafeMutableBytes(of: &clientAddr.sin_addr) { $0.storeBytes(of: inet_addr("127.0.0.1"), as: UInt32.self) }
        clientAddr.sin_port = boundAddr.sin_port
        let connected = withUnsafePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let e = WSAGetLastError()
            closesocket(client)
            closesocket(listener)
            return queue.async { completion(.failure(.spawnFailed(e))) }
        }
        // The client already connected, so a connection is queued: accept
        // returns at once (no timeout needed here, unlike the spawn tests'
        // defensive accept bound — the queue is never empty).
        let accepted = accept(listener, nil, nil)
        guard accepted != INVALID_SOCKET else {
            let e = WSAGetLastError()
            closesocket(client)
            closesocket(listener)
            return queue.async { completion(.failure(.spawnFailed(e))) }
        }
        // SOCKET values truncate to the API's Int32 (the C layer's documented
        // convention; test-process socket values are small).
        let childSocket = Int32(truncatingIfNeeded: client)
        let appSocket = Int32(truncatingIfNeeded: accepted)
        #else
        var sv: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, ltmSockStream, 0, &sv) == 0 else {
            let e = errno
            return queue.async { completion(.failure(.spawnFailed(e))) }
        }
        _ = fcntl(sv[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(sv[1], F_SETFD, FD_CLOEXEC)  // the child gets it via dup2 onto 3
        let childSocket = sv[1]
        let appSocket = sv[0]
        #endif
        let token = (0..<4).map { _ in String(format: "%08x", UInt32.random(in: UInt32.min...UInt32.max)) }.joined()
        // HelperLaunch.Mode.connect.service is vestigial on the new transport
        // (no bootstrap namespace); the token on argv is the authentication.
        let launch = HelperLaunch(
            .connect(service: "", token: token, instance: configuration.instance),
            lease: configuration.lease?.path
        )
        var argv = [configuration.helper.path] + launch.arguments
        var environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { $1 }
        if let dylib = configuration.dylib { environment["LTM_QEMU_DYLIB"] = dylib }
        let envp = environment.map { "\($0)=\($1)" }
        lock.withLock { startCompletion = completion }

        let pid: pid_t = withCStrings(argv) { cargv in
            withCStrings(envp) { cenv in
                ltm_spawn(configuration.helper.path, cargv, cenv, configuration.outputDescriptor, childSocket)
            }
        }
        argv.removeAll()
        // Parent's copies of the child's end: the child holds its own
        // inherited copies, so closing these does not affect it.
        #if os(Windows)
        closesocket(listener)
        closesocket(client)
        #else
        ltmCloseSocket(sv[1])
        #endif
        guard pid > 0 else {
            ltmCloseSocket(appSocket)
            lock.withLock { startCompletion = nil }
            return queue.async { completion(.failure(.spawnFailed(-pid))) }
        }
        lock.withLock { _pid = pid }
        watchForExit(pid)

        // The hello must be taken before the LinkChannel starts framing JSON:
        // it is the first bytes on the socket. Off the calling thread, with
        // the connect timeout.
        let connectTimeout = configuration.connectTimeout
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { ltmCloseSocket(appSocket); return }
            do {
                let hello = try DeviceRendezvous.receiveHello(
                    socket: appSocket,
                    token: token,
                    pid: pid,
                    timeout: connectTimeout
                )
                self.queue.async { self.helloArrived(hello, socket: appSocket) }
            } catch {
                ltmCloseSocket(appSocket)
                self.queue.async { self.helloFailed(error, pid: pid) }
            }
        }
        queue.asyncAfter(deadline: .now() + configuration.connectTimeout) { [weak self] in
            guard let self, lock.withLock({ self.startCompletion != nil }) else { return }
            invalidate(.timedOut, kill: true)
        }
    }

    /// One thread per link, blocked until the helper is gone (waitpid on
    /// POSIX — no kqueue/EVFILT_PROC on Linux, and a blocking waitpid has no
    /// exit race; WaitForSingleObject on a process handle on Windows).
    private func watchForExit(_ pid: pid_t) {
        #if os(Windows)
        // Windows has no waitpid/signals: wait on the process handle, then
        // read the exit code. A process killed with TerminateProcess reports
        // its termination code as its exit code; there is no signaled state.
        // The wait return is ignored deliberately: with INFINITE it only
        // returns on exit except for a near-impossible invalid-handle failure,
        // in which case GetExitCodeProcess failing reports .unknown below.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // GetExitCodeProcess needs query access, not just synchronize:
            // with SYNCHRONIZE alone it fails and termination reports
            // .unknown (caught by the link test: expected .exited(0)).
            guard let process = OpenProcess(DWORD(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else {
                // Already gone (its process object vanished with no handle
                // held): report unknown, same as a lost reap.
                self.queue.async { self.finishTermination(.unknown) }
                return
            }
            WaitForSingleObject(process, INFINITE)
            var code: DWORD = 0
            let ok = GetExitCodeProcess(process, &code)
            CloseHandle(process)
            // Compute the termination as a let first: queue.async takes a
            // @Sendable closure, which may not capture the var `code`
            // (Swift 6 error, caught by Windows CI on c44246d).
            let termination: DeviceTermination = ok ? .exited(Int32(bitPattern: code)) : .unknown
            self.queue.async { self.finishTermination(termination) }
        }
        #else
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            var waited: pid_t = 0
            repeat {
                waited = waitpid(pid, &status, 0)
            } while waited < 0 && errno == EINTR
            guard let self else { return }  // the waitpid above still reaped it: no zombie
            let result = waited
            let code = status
            self.queue.async { self.reaped(waitResult: result, status: code) }
        }
        #endif
    }

    private func helloArrived(_ hello: DeviceRendezvous.Hello, socket: Int32) {
        guard lock.withLock({ startCompletion != nil }) else {
            // Start already finished another way (timeout, exit); the mapped
            // segments die with `hello`, but the socket still needs closing.
            ltmCloseSocket(socket)
            return
        }
        let status = StatusBlock(hello.status)
        lock.withLock {
            ring?.release()
            statusBlock = status
            if hello.generation > 0 {
                ring = FrameRingReader(
                    status: status,
                    generation: hello.generation,
                    surfaces: hello.frames
                )
            }
        }
        let channel = LinkChannel<HelperMessage, AppMessage>(
            fd: socket,
            queue: queue,
            onMessage: { [weak self] in self?.received($0) },
            onClose: { [weak self] error in
                self?.invalidate(.closed(error.map { "\($0)" } ?? "end of file"), kill: false)
            }
        )
        lock.withLock { self.channel = channel }

        request(
            .hello(protocolVersion: DeviceLinkWire.protocolVersion, board: configuration.board),
            timeout: configuration.connectTimeout
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.hello(let info)):
                guard info.protocolVersion == DeviceLinkWire.protocolVersion else {
                    return invalidate(.protocolMismatch(helper: info.protocolVersion), kill: true)
                }
                lock.withLock { self._info = info }
                finishStartIfReady()
            case .success(.failure(let message)): invalidate(.helperFailure(message), kill: true)
            case .success(let other): invalidate(.helperFailure("unexpected hello reply \(other)"), kill: true)
            case .failure(let error): invalidate(error, kill: true)
            }
        }
    }

    private func helloFailed(_ error: Error, pid: pid_t) {
        guard lock.withLock({ startCompletion != nil }) else { return }
        let description = (error as? DeviceRendezvousError)?.description ?? "\(error)"
        // Don't leave a hello-less helper running.
        if pid > 0, self.pid == pid { _ = ltmKill(pid, SIGKILL) }
        invalidate(.rendezvous(description), kill: false)
    }

    private func finishStartIfReady() {
        let ready: (HelperInfo, (Result<HelperInfo, DeviceLinkError>) -> Void)? = lock.withLock {
            guard let info = self._info, self.statusBlock != nil, let c = self.startCompletion else { return nil }
            self.startCompletion = nil
            return (info, c)
        }
        if let (info, completion) = ready { completion(.success(info)) }
    }

    // MARK: - Messages

    /// Fire-and-forget, ordered. Dropped once the link is invalid.
    public func send(_ command: LinkCommand) {
        lock.withLock { channel }?.send(.command(command))
    }

    /// One request; `reply` runs once on `queue` (a reply, or .timedOut / .closed).
    public func request(_ request: LinkRequest, timeout: TimeInterval = 10, reply: @escaping Reply) {
        let (id, channel, dead): (UInt64, LinkChannel<HelperMessage, AppMessage>?, Bool) = lock.withLock {
            let id = nextID
            nextID += 1
            return (id, self.channel, invalidated)
        }
        guard let channel, !dead else { return queue.async { reply(.failure(.closed("not connected"))) } }
        let timer = DispatchWorkItem { [weak self] in
            guard let entry = self?.lock.withLock({ self?.pending.removeValue(forKey: id) }) else { return }
            entry.reply(.failure(.timedOut))
        }
        lock.withLock { pending[id] = Pending(timer: timer, reply: reply) }
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        if !channel.send(.request(id: id, request)) {
            if let entry = lock.withLock({ pending.removeValue(forKey: id) }) {
                entry.timer.cancel()
                queue.async { entry.reply(.failure(.helperFailure("request too large"))) }
            }
        }
    }

    public func request(_ request: LinkRequest, timeout: TimeInterval = 10) async throws -> LinkReply {
        try await withCheckedThrowingContinuation { continuation in
            self.request(request, timeout: timeout) { continuation.resume(with: $0) }
        }
    }

    private func received(_ message: HelperMessage) {
        switch message {
        case .reply(let id, let reply):
            guard let entry = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
            entry.timer.cancel()
            entry.reply(.success(reply))
        case .event(let event):
            onEvent?(event)
        }
    }

    // MARK: - Teardown

    /// SIGTERM: the helper runs its clean shutdown (bounded) and exits.
    public func terminate() {
        let p = pid
        if p > 0 { _ = ltmKill(p, SIGTERM) }
    }
    /// SIGKILL.
    public func kill() {
        let p = pid
        if p > 0 { _ = ltmKill(p, SIGKILL) }
    }

    private func invalidate(_ error: DeviceLinkError, kill shouldKill: Bool) {
        let (fire, channel, waiting, completion):
            (
                Bool, LinkChannel<HelperMessage, AppMessage>?, [Pending],
                (@Sendable (Result<HelperInfo, DeviceLinkError>) -> Void)?
            ) = lock.withLock {
                guard !invalidated else { return (false, nil, [], nil) }
                invalidated = true
                let waiting = Array(pending.values)
                pending.removeAll()
                let c = startCompletion
                startCompletion = nil
                ring?.release()
                return (true, self.channel, waiting, c)
            }
        guard fire else { return }
        if shouldKill { self.kill() }
        channel?.close()
        queue.async { [self] in
            for entry in waiting {
                entry.timer.cancel()
                entry.reply(.failure(error))
            }
            completion?(.failure(error))
            onInvalidated?(error)
        }
    }

    private func reaped(waitResult: pid_t, status: Int32) {
        let p = pid
        let termination: DeviceTermination
        if waitResult == p {
            if status & 0x7f == 0 {
                termination = .exited((status >> 8) & 0xff)
            } else {
                termination = .signaled(status & 0x7f)
            }
        } else {
            termination = .unknown
        }
        finishTermination(termination)
    }

    /// Shared tail of every reap path (POSIX waitpid, Windows handle wait):
    /// zero the pid, drain last messages, invalidate, report. Runs on `queue`
    /// (drainIncoming requires it).
    private func finishTermination(_ termination: DeviceTermination) {
        // Zero the pid now: a late terminate() or kill() must not signal a reused one.
        lock.withLock { _pid = 0 }
        // Its last messages (qemuExited) may still be unread: deliver them before the close.
        lock.withLock { channel }?.drainIncoming()
        invalidate(.closed("helper exited"), kill: false)
        queue.async { [self] in onTerminated?(termination) }
    }
}

nonisolated private func withCStrings<R>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
) -> R {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for p in pointers { free(p) } }
    return pointers.withUnsafeBufferPointer {
        guard let base = $0.baseAddress else { preconditionFailure("The array holds at least its nil terminator") }
        return body(base)
    }
}
