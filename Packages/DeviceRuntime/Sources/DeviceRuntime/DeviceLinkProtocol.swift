#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation
import HostRuntime

// The app <-> LightTouchDevice wire protocol.
//
// Control travels over a socketpair (the helper's end is fd 3) as length-framed
// JSON: a 4-byte big-endian length, then one `AppMessage` or `HelperMessage`.
// Frames and status never cross it: they live in POSIX shared-memory segments
// (SharedStatus.swift) whose fds arrive in the hello (DeviceRendezvous.swift),
// which the helper sends as the first bytes on this socket.
//
// Imported by the GUI, helper and standalone clients through DeviceRuntime.

nonisolated public enum DeviceLinkWire {
    /// Bumped on any incompatible change to the messages below or the status
    /// block layout. (The old comment also named the Mach hello; the new
    /// hello rides over the link socket itself, so a cross-transport mismatch
    /// cannot happen.) The JSON framing and the status slots are byte-for-byte
    /// what they were on macOS, so the version stays 2.
    public static let protocolVersion = 2
    /// The helper's hello refusal when another helper holds the device's lease; the app shows it as is.
    public static let leaseRefusal = "This device is in use by another copy of Light Touch."
    /// Upper bound on one framed message, either direction. An agent request is
    /// at most ~350 KB of base64 and an audio event ~22 KB; anything bigger is
    /// a bug or an attack, and closes the link.
    public static let maxMessageBytes = 4 << 20
}

// MARK: - Messages

/// App -> helper.
nonisolated public enum AppMessage: Codable, Sendable {
    /// Fire-and-forget, applied in order.
    case command(LinkCommand)
    /// Answered by exactly one `HelperMessage.reply` with the same id.
    case request(id: UInt64, LinkRequest)
}

/// Helper -> app.
nonisolated public enum HelperMessage: Codable, Sendable {
    case reply(id: UInt64, LinkReply)
    case event(LinkEvent)
}

nonisolated public enum MachineOp: String, Codable, Sendable {
    /// `shutdown`: the guest powers itself off (qemu_ios_ui_shutdown; an older dylib: powerdown's gesture).
    case pause, resume, reset, powerdown, quit, shutdown
}

nonisolated public enum LinkCommand: Codable, Sendable, Equatable {
    /// qemu_ios_ui_touch; phase is QEMU_IOS_TOUCH_*; x, y normalized, y down.
    case touch(slot: Int, phase: Int, x: Double, y: Double)
    case touch2(phase: Int, x: Double, y: Double)
    /// QEMU_IOS_BUTTON_*.
    case button(Int, down: Bool)
    case key(macKeyCode: Int, down: Bool)
    case rotate(clockwise: Bool)
    case shake
    case attitude(pitch: Double, roll: Double, pose: Int)
    case paste(String)
    case machine(MachineOp)
    /// qemu_ios_snapshot_save2; poll `LinkRequest.snapshotStatus`.
    case snapshotSave(path: String)
    case snapshotResume
    case agentCancel(id: String)
    case audioStop(generation: UInt64)
    /// qemu_ios_ui_net_restrict on the wifi0 user netdev: flip slirp's restrict
    /// flag in place (false opens outbound networking after Setup, no link event).
    case netRestrict(Bool)
    /// qemu_ios_ui_net_lan on every user netdev (wifi0, an iPhone's cell0): allow (true) or refuse the guest's traffic to the Mac's local networks.
    case netLocalNetwork(Bool)
    /// Whether the app shows this device's screen (its window on screen: not occluded, minimized or hidden).
    /// Hidden, or with the guest's display asleep, the helper publishes frames at a few Hz and lets the Mac
    /// idle-sleep; shown again, the next frame goes at once. Until the first one, shown.
    case screenVisible(Bool)
}

nonisolated public enum LinkRequest: Codable, Sendable, Equatable {
    /// Always first. `board` (a board ID, "n72ap") selects the reply's `deviceInfo`.
    case hello(protocolVersion: Int, board: String?)
    /// Starts qemu_ios_main once; `.ok(true)` when the QEMU thread is running.
    case boot(BootConfig)
    /// -> `.snapshot(status:error:)`, QemuIosSnapshotStatus values.
    case snapshotStatus
    /// One qemu_ios_agent_request wire string ("<id> <op> <args>\n<base64>").
    /// The helper polls for the result with the same id, frees it and replies
    /// `.agent(result)`, or `.agent(nil)` after `deadline` seconds (and cancels it).
    /// `deadline <= 0` only submits: `.ok(submitted)` (the halt request).
    /// `.failure` if the queue refused it.
    case agent(request: String, deadline: Double)
    /// -> `.audio(generation:)`, then `.audio` events until `audioStop`.
    case audioStart
    case battery(level: Int, charging: Int)
    case usbConnection(Bool)
    case compass(Int)
    case orientation(Int)
    /// Generic automation in guest virtual milliseconds; optional dylib ABI.
    case inputSequence(id: UInt64, events: [VirtualInputEvent])
    case inputSequenceStatus(id: UInt64)
    case inputSequenceCancel(id: UInt64)
    /// qemu_ios_ui_modem_set: one modem property (CarrierSettings, the call and SMS actions) from its string form.
    /// `.ok(false)`: no modem, no such property, or an older dylib.
    case modemSet(property: String, value: String)
    /// -> `.modemStatus(json)`: qemu_ios_ui_modem_status (as of the previous poll); nil without a modem.
    case modemStatus
    /// qemu_ios_ui_hardware_keyboard (API 1.1): attach or detach the USB keyboard; `.ok(false)` where the machine
    /// can't, or an older dylib.
    case hardwareKeyboard(Bool)
}

nonisolated public enum LinkReply: Codable, Sendable, Equatable {
    case hello(HelperInfo)
    case ok(Bool)
    case snapshot(status: Int, error: String?)
    case agent(String?)
    case audio(generation: UInt64)
    case failure(String)
    case inputSequenceStatus(Int)
    case modemStatus(String?)
}

nonisolated public enum LinkEvent: Codable, Sendable, Equatable {
    /// qemu_ios_main returned; the helper exits with this code right after.
    case qemuExited(Int32)
    /// 44100 Hz stereo S16LE. Empty `pcm` with `seconds >= 0` marks silence through `seconds`.
    case audio(generation: UInt64, seconds: Double, pcm: Data)
    /// No more events for this generation: drained after `audioStop` (failed
    /// false), or the capture stopped or overflowed on its own (failed true).
    case audioEnded(generation: UInt64, failed: Bool)
}

nonisolated public struct HelperInfo: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var pid: Int32
    /// The libqemu-arm.dylib the helper loaded, and its mtime (seconds since 1970).
    public var dylibPath: String
    public var dylibModified: Double
    /// qemu_ios_build_id(): the loaded Mach-O's UUID.
    public var buildID: String?
    /// qemu_ios_device_info of hello.board's machine.
    public var deviceInfo: DeviceInfo?
    /// The helper rechecks admitted storage under its lease before boot.
    public var storageProofValidation: Bool?
    public init(
        protocolVersion: Int,
        pid: Int32,
        dylibPath: String,
        dylibModified: Double,
        buildID: String? = nil,
        deviceInfo: DeviceInfo? = nil,
        storageProofValidation: Bool? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.dylibPath = dylibPath
        self.dylibModified = dylibModified
        self.buildID = buildID
        self.deviceInfo = deviceInfo
        self.storageProofValidation = storageProofValidation
    }
}

// MARK: - Framing

nonisolated public enum DeviceLinkWireError: Error, Equatable {
    case oversized(Int)
    case malformed(String)
}

/// One end of the socketpair: framed messages in, framed messages out.
///
/// Reads run on a dispatch read source (Windows: a dedicated thread with
/// blocking recv — libdispatch-Windows makeReadSource on a SOCKET fd kills
/// the process, proven by diagnostic rounds 4-5); writes go through a private serial
/// queue, so a wedged peer can never block the caller (the app's main thread).
/// `onClose` fires once: EOF, a read error, or a protocol violation.
nonisolated public final class LinkChannel<
    Incoming: Decodable & SendableMetatype,
    Outgoing: Encodable & SendableMetatype
>: @unchecked Sendable {
    public let fd: Int32
    private let source: DispatchSourceRead?  // nil on Windows (read thread instead)
    private let writeQueue: DispatchQueue
    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false  // on `queue`
    private let lock = NSLock()
    private var writeFailed = false  // under lock

    public init(
        fd: Int32,
        queue: DispatchQueue,
        onMessage: @escaping (Incoming) -> Void,
        onClose: @escaping (Error?) -> Void
    ) {
        self.fd = fd
        self.queue = queue
        self.onMessage = onMessage
        writeQueue = DispatchQueue(label: "LightTouch.link.write.\(fd)")
        var size: Int32 = 1 << 20
        #if os(Windows)
        // WinSDK's SOCKET is UInt64; the link fd is a 32-bit socket value here.
        let sock = SOCKET(UInt64(bitPattern: Int64(fd)))
        setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        #else
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        #endif
        diagLinkChan("setsockopt done")
        // macOS suppresses SIGPIPE per descriptor; Linux has no SO_NOSIGPIPE,
        // so writes below use MSG_NOSIGNAL instead (Windows has no SIGPIPE).
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        #if os(Windows)
        // PROVEN by diagnostic rounds 4-5: libdispatch-Windows
        // DispatchSource.makeReadSource on a SOCKET fd kills the process
        // (death inside makeReadSource, no dump, exit 1). Windows therefore
        // reads on a dedicated thread with blocking recv. Bytes are handed
        // to `queue` for framing, preserving the single-queue invariant for
        // buffer state; the thread exits when recv fails, which finish()
        // forces by closing the socket (see below).
        source = nil
        let readQueue = DispatchQueue(label: "LightTouch.link.read.\(fd)")
        readQueue.async { [weak self] in
            guard let self else { return }
            let sock = SOCKET(UInt64(bitPattern: Int64(fd)))
            while true {
                var chunk = [UInt8](repeating: 0, count: 65536)
                let n = chunk.withUnsafeMutableBufferPointer { buf in
                    buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { ptr in
                        WinSDK.recv(sock, ptr, Int32(buf.count), 0)
                    }
                }
                if n <= 0 {
                    // EOF (peer closed) or error. The error value is
                    // diagnostic only here; EOF (the common path) is nil.
                    self.queue.async { self.finish(n == 0 ? nil : POSIXError(.EIO)) }
                    return
                }
                let data = Data(chunk[0..<Int(n)])
                self.queue.async {
                    self.buffer.append(contentsOf: data)
                    self.deliverFrames()
                }
            }
        }
        diagLinkChan("read thread started")
        #else
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        diagLinkChan("source created")
        source?.setEventHandler { [unowned self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            if n <= 0 {
                finish(n == 0 ? nil : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                return
            }
            buffer.append(contentsOf: chunk[0..<Int(n)])
            deliverFrames()
        }
        source?.setCancelHandler { ltmCloseSocket(fd) }
        diagLinkChan("cancel handler set")
        source?.resume()
        diagLinkChan("resumed")
        #endif
        onCloseHandler = onClose
    }

    private var onCloseHandler: ((Error?) -> Void)?
    private let onMessage: (Incoming) -> Void

    private func deliverFrames() {
        do {
            while let body = try Self.takeFrame(&buffer) {
                let message = try JSONDecoder().decode(Incoming.self, from: body)
                onMessage(message)
                if closed { return }
            }
        } catch {
            finish(error)
        }
    }

    /// The peer is gone: deliver what it wrote before exiting (its last messages may
    /// still sit in the socket, the reader not yet run) so they land before the
    /// channel closes. On `queue`; never blocks (reads only what poll reports ready).
    public func drainIncoming() {
        #if os(Windows)
        // No poll(2) for sockets on Windows: select() with a zero timeout
        // reports readability without blocking, then recv() consumes.
        // (fd_set is a fixed 64-entry array; one socket is all this needs.)
        let sock = SOCKET(UInt64(bitPattern: Int64(fd)))
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !closed {
            var readfds = fd_set()
            readfds.fd_count = 1
            readfds.fd_array.0 = sock
            var tv = timeval()
            tv.tv_sec = 0
            tv.tv_usec = 0
            let ready = WinSDK.select(0, &readfds, nil, nil, &tv)
            guard ready > 0 else { return }
            let n = chunk.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { ptr in
                    WinSDK.recv(sock, ptr, Int32(buf.count), 0)
                }
            }
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<Int(n)])
            deliverFrames()
        }
        #else
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !closed {
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 0) > 0, ready.revents & Int16(POLLIN | POLLHUP) != 0 else { return }
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<n])
            deliverFrames()
        }
        #endif
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        #if os(Windows)
        // No read source on Windows: close the socket directly, which
        // unblocks the read thread's recv (its redundant finish call is a
        // no-op via the guard above).
        ltmCloseSocket(fd)
        #else
        source?.cancel()
        #endif
        let handler = onCloseHandler
        onCloseHandler = nil
        handler?(error)
    }

    /// Close from any thread; `onClose` still fires once, on the channel's queue.
    public func close() { queue.async { self.finish(nil) } }

    /// Encode and enqueue. False if the message is over the bound (not sent).
    @discardableResult
    public func send(_ message: Outgoing) -> Bool {
        guard let frame = try? Self.frame(message) else { return false }
        writeQueue.async { [self] in
            lock.lock()
            let failed = writeFailed
            lock.unlock()
            guard !failed else { return }
            if !Self.writeAll(fd: fd, frame) {
                lock.lock()
                writeFailed = true
                lock.unlock()
            }
        }
        return true
    }

    /// Write the whole frame, suppressing SIGPIPE (Linux: MSG_NOSIGNAL;
    /// Darwin relies on the SO_NOSIGPIPE above; Windows has no SIGPIPE).
    /// EINTR retries; anything else fails the channel.
    private static func writeAll(fd: Int32, _ frame: Data) -> Bool {
        #if os(Linux)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        var sent = 0
        while sent < frame.count {
            let n = frame.withUnsafeBytes {
                Self.sendBytes(fd: fd, $0.baseAddress!.advanced(by: sent), frame.count - sent, flags)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            sent += n
        }
        return true
    }

    private static func sendBytes(fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int, _ flags: Int32) -> Int {
        #if os(Linux)
        Glibc.send(fd, buffer, count, flags)
        #elseif os(Windows)
        // A link fd is a SOCKET: WinSDK.send on the socket value (flags are
        // ignored on Windows — there is no MSG_NOSIGNAL, and no SIGPIPE).
        let sock = SOCKET(UInt64(bitPattern: Int64(fd)))
        let ptr = buffer?.assumingMemoryBound(to: CChar.self)
        let sent = WinSDK.send(sock, ptr, Int32(count), 0)
        return sent == -1 ? -1 : Int(sent)
        #else
        Darwin.send(fd, buffer, count, flags)
        #endif
    }

    /// Blocks until everything queued so far has been written (the helper's exit path).
    public func drain(timeout: TimeInterval = 2) {
        let done = DispatchSemaphore(value: 0)
        writeQueue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    public static func frame(_ message: Outgoing) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= DeviceLinkWire.maxMessageBytes else { throw DeviceLinkWireError.oversized(body.count) }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    /// The next whole frame's body, or nil if more bytes are needed.
    public static func takeFrame(_ buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        guard length <= DeviceLinkWire.maxMessageBytes else { throw DeviceLinkWireError.oversized(length) }
        guard buffer.count >= 4 + length else { return nil }
        let body = buffer.subdata(in: start + 4..<start + 4 + length)
        buffer.removeSubrange(start..<start + 4 + length)
        return body
    }
}

/// Host-authored physical input only. QEMU owns execution deadlines and pins.
nonisolated public struct VirtualInputEvent: Codable, Sendable, Equatable {
    public var atMilliseconds: Int64
    public var kind: Int32
    public var value: Int32
    public var phase: Int32
    public var x: Double
    public var y: Double

    public static func button(_ button: Int32, down: Bool, at: Int64) -> Self {
        .init(atMilliseconds: at, kind: 0, value: button, phase: down ? 1 : 0, x: 0, y: 0)
    }
    public static func touch(phase: Int32, x: Double, y: Double, at: Int64) -> Self {
        .init(atMilliseconds: at, kind: 1, value: 0, phase: phase, x: x, y: y)
    }
    public static func valid(_ events: [Self]) -> Bool {
        guard !events.isEmpty, events.count <= 256 else { return false }
        var buttons = [Bool](repeating: false, count: 4)
        var touch = false
        var previous: Int64 = 0
        for event in events {
            guard event.atMilliseconds >= previous, event.atMilliseconds <= 600_000 else { return false }
            previous = event.atMilliseconds
            if event.kind == 0 {
                guard (0...3).contains(event.value), (0...1).contains(event.phase),
                    buttons[Int(event.value)] != (event.phase == 1)
                else { return false }
                buttons[Int(event.value)] = event.phase == 1
            } else if event.kind == 1 {
                guard event.value == 0, (0...2).contains(event.phase),
                    event.x.isFinite, event.y.isFinite,
                    (0...1).contains(event.x), (0...1).contains(event.y),
                    event.phase == 0 ? !touch : touch
                else { return false }
                touch = event.phase != 2
            } else {
                return false
            }
        }
        return !touch && !buttons.contains(true)
    }
}

// DIAGNOSTIC (temporary, round 5): LinkChannel init stage markers. Same
// channel as the other DIAG markers (surfaces in test.log on Windows CI).
// Removed once the init step that kills the link test is found.
private func diagLinkChan(_ message: String) {
    if let data = ("DIAG-LINKCHAN \(message)\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
