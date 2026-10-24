// The status block and frame ring the helper shares with the app.
//
// (Linux redesign; macOS used IOSurfaces + Mach ports.)
//
// Segment #0 is a 4 KB block of UInt64 slots, written by the helper at 20 Hz
// (frames at 60 Hz) with atomics and read synchronously by the app. Segments
// #1...#3 are BGRA pixel buffers of the current screen size. The writer copies
// each new qemu_ios_ui_frame into a surface that is neither `front`, nor the
// reader's `held`, nor locked, then publishes `front` and `frameSerial`
// (seq-cst). The reader stores `held` and re-reads the serial. A stalled
// heartbeat means the helper is wedged; stalled frames, the guest.
//
// Transport: POSIX shm (shm_open + mmap) on POSIX; pagefile-backed file
// mappings (CreateFileMapping/MapViewOfFile) on Windows, helper-side only so
// far — the app-side open() by name and the hello path are still the future
// Windows wave (see TRANSPORT_REDESIGN.md). Each segment is unlinked
// immediately after creation on POSIX, so no name outlives a crashed helper;
// on Windows the mapping dies with its last handle. The app maps the fds
// the helper's hello carries over the link socket (DeviceRendezvous.swift).
// Pixel data is assumed sRGB throughout: the macOS build tagged the surfaces
// with an sRGB ICC profile so Core Animation would not reinterpret the guest's
// pixels in the display's space; there is no color management on this path, so
// every consumer must treat the bytes as sRGB (see SHIM_NOTES.md).

#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation
import LTMShm

nonisolated public enum StatusSlot: Int, CaseIterable {
    case magic = 0
    case layoutVersion, heartbeat, frameSerial, front, width, height,
        ringGeneration, held,  // held: 1 + the ring index the app is reading, 0 none
        uiReady, storageFailed, shutdownConfirmed, displaySleeping, agentStatus,
        glesContexts, iconGeneration,  // retired icon counter slot: zero; preserve ABI offsets
        qemuState,  // QemuState
        exitCode, publishTicks, helperPID,
        // layout 2: it_boot's QC_PKG_REPORT and the GL shim's QC_GLES_HELLO
        guestPackageReported, guestPackage, guestPackageState,  // serial, it_boot R_* (Int64 bit patterns)
        glesProtocol, glesSerial,
        guestPackageSupported,  // the dylib has the guest-package= property (set before boot)
        backlightLevel,  // qemu_ios_ui_backlight_level (Int64 bit pattern)
        vibrating, vibratorPulses  // qemu_ios_ui_vibrator: the motor runs; its starts so far
}

nonisolated public enum QemuState: UInt64, Sendable {
    case notStarted = 0
    case running = 1
    case exited = 2
}

/// One synchronous read of the status block.
nonisolated public struct SharedStatus: Sendable, Equatable {
    public var heartbeat: UInt64
    public var frameSerial: UInt64
    public var width: Int
    public var height: Int
    public var ringGeneration: UInt64
    public var uiReady: Bool
    public var storageFailed: Bool
    public var shutdownConfirmed: Bool
    public var displaySleeping: Bool
    /// qemu_ios_agent_status: 0 absent/not running, 1 alive, 2 stale.
    public var agentStatus: Int
    public var glesContexts: Int
    /// Retired NAND content-sniffing counter; zero in current helpers. ABI only.
    public var iconGeneration: UInt64
    public var qemuState: QemuState
    public var exitCode: Int32
    public var helperPID: Int32
    /// it_boot's last report since the guest reset: the serial now current and
    /// its result (R_*: 0 unchanged, 1 installed, 2 switched, 3/4 reverted,
    /// 5 refused; negative: an install failed). Nil: no loader, or no offer yet.
    public var guestPackage: GuestPackageReport?
    /// QC_GLES_HELLO's wire protocol and package serial; 0 when no hello came.
    public var glesProtocol: Int32 = 0
    public var glesSerial: Int64 = 0
    /// The loaded dylib serves guest-package offers (older ones reject the property).
    public var guestPackageSupported = false
    /// The level the guest last programmed into the backlight driver (its raw code; 0 off), -1 where not decoded.
    public var backlightLevel = -1
    /// The vibration motor runs (an iPhone's; the iPods and the iPad have none).
    public var vibrating = false
    /// How many times the motor has started since the helper loaded the emulator: a buzz shorter than a poll
    /// still shows here.
    public var vibratorPulses: UInt64 = 0
    public init(
        heartbeat: UInt64,
        frameSerial: UInt64,
        width: Int,
        height: Int,
        ringGeneration: UInt64,
        uiReady: Bool,
        storageFailed: Bool,
        shutdownConfirmed: Bool,
        displaySleeping: Bool,
        agentStatus: Int,
        glesContexts: Int,
        iconGeneration: UInt64,
        qemuState: QemuState,
        exitCode: Int32,
        helperPID: Int32,
        guestPackage: GuestPackageReport? = nil,
        glesProtocol: Int32 = 0,
        glesSerial: Int64 = 0,
        guestPackageSupported: Bool = false,
        backlightLevel: Int = -1,
        vibrating: Bool = false,
        vibratorPulses: UInt64 = 0
    ) {
        self.heartbeat = heartbeat
        self.frameSerial = frameSerial
        self.width = width
        self.height = height
        self.ringGeneration = ringGeneration
        self.uiReady = uiReady
        self.storageFailed = storageFailed
        self.shutdownConfirmed = shutdownConfirmed
        self.displaySleeping = displaySleeping
        self.agentStatus = agentStatus
        self.glesContexts = glesContexts
        self.iconGeneration = iconGeneration
        self.qemuState = qemuState
        self.exitCode = exitCode
        self.helperPID = helperPID
        self.guestPackage = guestPackage
        self.glesProtocol = glesProtocol
        self.glesSerial = glesSerial
        self.guestPackageSupported = guestPackageSupported
        self.backlightLevel = backlightLevel
        self.vibrating = vibrating
        self.vibratorPulses = vibratorPulses
    }
}

nonisolated public struct GuestPackageReport: Sendable, Equatable {
    public var serial: Int64
    public var result: Int32
    public init(serial: Int64, result: Int32) {
        self.serial = serial
        self.result = result
    }
}

/// One shared-memory segment: the status block or one BGRA frame buffer.
///
/// The helper creates segments (`createStatus` / `createFrame`); the app maps
/// the fds from the hello (`open`). The fd's lifetime is separate from the
/// mapping's: `takeFD` hands the fd to the hello (which moves it to the app),
/// and deinit unmaps. The segment's shm name is unlinked at creation, so a
/// crashed helper leaves no named segment behind.
nonisolated public final class ShmSurface: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let byteCount: Int
    public private(set) var baseAddress: UnsafeMutableRawPointer

    private var fd: Int32 = -1
    // Windows only: the file-mapping handle for this segment (pagefile-backed,
    // see makeSegment). Nil on POSIX, where the fd owns the segment.
    private var mapping: UnsafeMutableRawPointer? = nil
    private let stateLock = NSLock()
    private var locked = false  // under stateLock; the writer's lock only

    private init(
        fd: Int32,
        base: UnsafeMutableRawPointer,
        byteCount: Int,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        mapping: UnsafeMutableRawPointer? = nil
    ) {
        self.fd = fd
        self.baseAddress = base
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.mapping = mapping
    }

    deinit {
        #if os(Windows)
        // The mapping handle is the segment's only owner (fd is -1): unmap,
        // then close. A mapping dies with its last handle, so a crashed
        // helper leaves nothing behind.
        UnmapViewOfFile(baseAddress)
        if let mapping = mapping { CloseHandle(mapping) }
        #else
        munmap(baseAddress, byteCount)
        if fd >= 0 { ltmClose(fd) }
        #endif
    }

    /// Hand the shm fd to the caller (-1: none held). The mapping stays valid;
    /// the caller owns (closes) the fd. `DeviceRendezvous.sendHello` uses this
    /// to move the fds to the app.
    func takeFD() -> Int32 {
        stateLock.withLock {
            defer { fd = -1 }
            return fd
        }
    }

    /// Whether the writer currently holds this surface. (On macOS this also
    /// reflected Core Animation's asynchronous use; here there is no external
    /// consumer, so it is the writer's lock only.)
    public var isInUse: Bool { stateLock.withLock { locked } }
    public func lock() { stateLock.lock(); locked = true }
    public func unlock() { locked = false; stateLock.unlock() }

    // MARK: - Helper side

    private static let idLock = NSLock()
    // Protected by idLock (the shm name only needs process-uniqueness).
    nonisolated(unsafe) private static var nextID: UInt64 = 0

    private static func makeSegment(byteCount: Int) -> (fd: Int32, base: UnsafeMutableRawPointer, mapping: UnsafeMutableRawPointer?)? {
        #if os(Windows)
        // Pagefile-backed file mapping (TRANSPORT_REDESIGN.md's named-mapping
        // direction, first step: helper-side creation only). The mapping is
        // named pid + monotonic id so the future hello path can re-open it by
        // name; a crashed helper's handles close with it, so no name leaks.
        // The app-side open() by name is still unimplemented (see below).
        guard byteCount > 0, byteCount < Int(UInt32.max) else { return nil }
        let id = idLock.withLock { () -> UInt64 in defer { nextID += 1 }; return nextID }
        let name = "LTM.\(GetCurrentProcessId()).\(id)"
        var segment: (fd: Int32, base: UnsafeMutableRawPointer, mapping: UnsafeMutableRawPointer?)? = nil
        name.withCString(encodedAs: UTF16.self) { namePtr in
            guard let mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, nil, DWORD(PAGE_READWRITE), 0, DWORD(byteCount), namePtr) else { return }
            guard let base = MapViewOfFile(mapping, DWORD(FILE_MAP_ALL_ACCESS), 0, 0, 0) else { CloseHandle(mapping); return }
            segment = (fd: -1, base: base, mapping: mapping)
        }
        return segment
        #else
        let id = idLock.withLock { () -> UInt64 in defer { nextID += 1 }; return nextID }
        let name = "/ltm.\(getpid()).\(id)"
        var fd: Int32 = -1
        name.withCString { ptr in fd = shm_open(ptr, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR) }
        guard fd >= 0 else { return nil }
        // Unlink at once: the name never outlives a crash, and the fd (passed
        // via SCM_RIGHTS) is all the app needs.
        name.withCString { _ = shm_unlink($0) }
        guard ftruncate(fd, off_t(byteCount)) == 0 else { ltmClose(fd); return nil }
        guard let base = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
            base != MAP_FAILED
        else { ltmClose(fd); return nil }
        return (fd, base, nil)
        #endif
    }

    private static func preconditionsFailed(_ what: String) -> Never {
        preconditionFailure("ShmSurface: \(what) failed: \(String(cString: strerror(errno)))")
    }

    /// The status block segment (StatusBlock.bytes).
    public static func createStatus() -> ShmSurface {
        guard let segment = makeSegment(byteCount: StatusBlock.bytes) else { preconditionsFailed("shm_open") }
        return ShmSurface(
            fd: segment.fd,
            base: segment.base,
            byteCount: StatusBlock.bytes,
            width: StatusBlock.bytes / 8,
            height: 1,
            bytesPerRow: StatusBlock.bytes,
            mapping: segment.mapping
        )
    }

    /// One frame segment: height rows of width BGRA pixels, tightly packed.
    public static func createFrame(width: Int, height: Int) -> ShmSurface {
        precondition(width > 0 && height > 0, "ShmSurface.createFrame: bad size \(width)x\(height)")
        let rowBytes = width * 4
        guard let segment = makeSegment(byteCount: rowBytes * height) else { preconditionsFailed("shm_open") }
        return ShmSurface(
            fd: segment.fd,
            base: segment.base,
            byteCount: rowBytes * height,
            width: width,
            height: height,
            bytesPerRow: rowBytes,
            mapping: segment.mapping
        )
    }

    // MARK: - App side

    /// Map a hello fd. The fd is closed; the mapping holds its own reference.
    public static func open(
        fd: Int32,
        byteCount: Int,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> ShmSurface? {
        #if os(Windows)
        fatalError("ShmSurface: the Windows transport uses named file mappings (not implemented yet)")
        #else
        guard byteCount > 0, width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }
        guard let base = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
            base != MAP_FAILED
        else { return nil }
        ltmClose(fd)
        return ShmSurface(
            fd: -1,
            base: base,
            byteCount: byteCount,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
        #endif
    }
}

nonisolated public struct StatusBlock: @unchecked Sendable {
    public static let magic: UInt64 = 0x4C54_4D53_5441_5432  // "LTMSTAT2"
    public static let layoutVersion: UInt64 = 2
    public static let bytes = 4096

    public let surface: ShmSurface
    private let base: UnsafeMutablePointer<UInt64>

    public init(_ surface: ShmSurface) {
        precondition(surface.byteCount >= Self.bytes, "StatusBlock: segment smaller than 4096 bytes")
        self.surface = surface
        base = surface.baseAddress.assumingMemoryBound(to: UInt64.self)
    }

    /// The helper's block, zeroed and stamped.
    public static func create() -> StatusBlock {
        let block = StatusBlock(ShmSurface.createStatus())
        memset(block.base, 0, bytes)
        block[.layoutVersion] = layoutVersion
        #if os(Windows)
        // Helper-side creation works on Windows (pagefile-backed mapping);
        // only the app-side open() by name is still unimplemented.
        block[.helperPID] = UInt64(GetCurrentProcessId())
        #else
        block[.helperPID] = UInt64(getpid())
        #endif
        block[.magic] = magic
        return block
    }

    public var isValid: Bool {
        surface.byteCount >= Self.bytes && self[.magic] == Self.magic && self[.layoutVersion] == Self.layoutVersion
    }

    public subscript(_ slot: StatusSlot) -> UInt64 {
        get { ltm_load(base + slot.rawValue) }
        nonmutating set { ltm_store(base + slot.rawValue, newValue) }
    }
    public func loadSeq(_ slot: StatusSlot) -> UInt64 { ltm_load_seq(base + slot.rawValue) }
    public func storeSeq(_ slot: StatusSlot, _ value: UInt64) { ltm_store_seq(base + slot.rawValue, value) }
    public func bumpHeartbeat() { _ = ltm_add(base + StatusSlot.heartbeat.rawValue, 1) }

    public func snapshot() -> SharedStatus {
        SharedStatus(
            heartbeat: self[.heartbeat],
            frameSerial: self[.frameSerial],
            width: Int(self[.width]),
            height: Int(self[.height]),
            ringGeneration: self[.ringGeneration],
            uiReady: self[.uiReady] != 0,
            storageFailed: self[.storageFailed] != 0,
            shutdownConfirmed: self[.shutdownConfirmed] != 0,
            displaySleeping: self[.displaySleeping] != 0,
            agentStatus: Int(self[.agentStatus]),
            glesContexts: Int(self[.glesContexts]),
            iconGeneration: self[.iconGeneration],
            qemuState: QemuState(rawValue: self[.qemuState]) ?? .notStarted,
            exitCode: Int32(truncatingIfNeeded: Int64(bitPattern: self[.exitCode])),
            helperPID: Int32(truncatingIfNeeded: self[.helperPID]),
            guestPackage: self[.guestPackageReported] == 0
                ? nil
                : GuestPackageReport(
                    serial: Int64(bitPattern: self[.guestPackage]),
                    result: Int32(truncatingIfNeeded: Int64(bitPattern: self[.guestPackageState]))
                ),
            glesProtocol: Int32(truncatingIfNeeded: Int64(bitPattern: self[.glesProtocol])),
            glesSerial: Int64(bitPattern: self[.glesSerial]),
            guestPackageSupported: self[.guestPackageSupported] != 0,
            backlightLevel: Int(Int64(bitPattern: self[.backlightLevel])),
            vibrating: self[.vibrating] != 0,
            vibratorPulses: self[.vibratorPulses]
        )
    }
}

/// The helper's side of the ring: three segments, and a publish that never
/// touches the segment the reader holds or has locked.
nonisolated public final class FrameRingWriter: @unchecked Sendable {
    public let status: StatusBlock
    public private(set) var surfaces: [ShmSurface] = []
    public private(set) var generation: UInt64 = 0
    private var serial: UInt64 = 0
    public private(set) var dropped = 0

    public init(status: StatusBlock) { self.status = status }

    public var width: Int { surfaces.first?.width ?? 0 }
    public var height: Int { surfaces.first?.height ?? 0 }

    /// A new ring of `width` x `height`. The caller calls `activate()` and then
    /// sends the hello for it: the app sizes the segments from the status
    /// block, so the dimensions must be published before the hello goes out.
    public func resize(width: Int, height: Int) {
        surfaces = (0..<3).map { _ in ShmSurface.createFrame(width: width, height: height) }
        generation += 1
    }

    public func activate() {
        status[.width] = UInt64(width)
        status[.height] = UInt64(height)
        status[.front] = 3  // nothing published in this ring yet: the reader keeps its last segment
        status[.ringGeneration] = generation
    }

    /// Fill a free surface and publish it. False if all three were busy (a dropped frame).
    @discardableResult
    public func publish(_ fill: (ShmSurface) -> Void) -> Bool {
        let front = Int(status[.front])
        let held = Int(status.loadSeq(.held)) - 1
        guard let i = surfaces.indices.first(where: { $0 != front && $0 != held && !surfaces[$0].isInUse }) else {
            dropped += 1
            return false
        }
        surfaces[i].lock()
        fill(surfaces[i])
        surfaces[i].unlock()
        serial += 1
        status[.front] = UInt64(i)
        status[.publishTicks] = ltm_monotonic_ns()
        status.storeSeq(.frameSerial, serial)
        return true
    }

    /// Copy tightly packed BGRA rows into the segment's rows, with the alpha
    /// byte forced opaque: iBoot and the iPod's framebuffer leave it 0. (The
    /// macOS build did this with Accelerate's vImage; a plain loop is fast
    /// enough next to the copy itself.)
    public static func copy(_ pixels: UnsafeRawPointer, width: Int, height: Int, into surface: ShmSurface) {
        let rowBytes = width * 4
        let dst = surface.baseAddress
        let src = pixels.assumingMemoryBound(to: UInt8.self)
        if surface.bytesPerRow == rowBytes {
            dst.copyMemory(from: pixels, byteCount: rowBytes * height)
        } else {
            for y in 0..<height {
                dst.advanced(by: y * surface.bytesPerRow)
                    .copyMemory(from: src.advanced(by: y * rowBytes), byteCount: rowBytes)
            }
        }
        // Little-endian BGRA: the alpha byte is the top byte of the UInt32.
        let words = dst.assumingMemoryBound(to: UInt32.self)
        let stride = surface.bytesPerRow / 4
        for y in 0..<height {
            let row = words.advanced(by: y * stride)
            for x in 0..<width { row[x] |= 0xFF00_0000 }
        }
    }
}

/// The app's side: which segment to show. One reader per ring.
nonisolated public final class FrameRingReader: @unchecked Sendable {
    public let status: StatusBlock
    public let generation: UInt64
    public let surfaces: [ShmSurface]
    private var lastSerial: UInt64 = 0
    private var current: ShmSurface?
    private var currentIndex = -1

    public init(status: StatusBlock, generation: UInt64, surfaces: [ShmSurface]) {
        self.status = status
        self.generation = generation
        self.surfaces = surfaces
    }

    /// The newest published segment, and whether it is new since the last call.
    /// While the helper is between rings (a resize in flight) this keeps
    /// returning the last segment. Call from one thread (the display link).
    public func front() -> (surface: ShmSurface, serial: UInt64, isNew: Bool)? {
        guard surfaces.count == 3 else { return nil }
        let s1 = status.loadSeq(.frameSerial)
        if s1 == lastSerial || status[.ringGeneration] != generation {
            return current.map { ($0, lastSerial, false) }
        }
        let index = Int(status[.front])
        guard index < 3 else { return current.map { ($0, lastSerial, false) } }
        status.storeSeq(.held, UInt64(index + 1))
        // Moved under us: the helper may already be writing into `index`. Keep
        // the last one; the next call takes the newer frame.
        guard status.loadSeq(.frameSerial) == s1 else {
            status.storeSeq(.held, UInt64(currentIndex + 1))
            return current.map { ($0, lastSerial, false) }
        }
        lastSerial = s1
        current = surfaces[index]
        currentIndex = index
        return (surfaces[index], s1, true)
    }

    /// Stop holding any segment (the display is hidden or the ring is replaced).
    public func release() { status.storeSeq(.held, 0) }
}
