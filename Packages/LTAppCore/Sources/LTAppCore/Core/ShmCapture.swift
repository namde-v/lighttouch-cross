import LTBridgeC
/// Swift-side frame-ring reading and capture (ui/ABI.md §6 gap 4, §3.8).
///
/// Two consumers need guest pixels without bridge traffic in the hot loop:
///
///  1. **Capture** (screenshots, screen recordings): `ShmCapture.supplier`
///     reads the helper's frame ring through `DeviceLink.frontSurface()` and
///     hands `LTMImage`s to `ScreenRecordingSession` / the PNG encoder.
///  2. **Display**: Qt's `DisplayItem` maps a ring directly. The ABI's
///     `kLTEventDisplayLinkReady` carries one fd for the whole ring, but the
///     helper's ring is three separate shm segments whose fds the app side
///     closes at hello time — there is no single fd to hand over. So Swift
///     publishes each new frame into a **Qt-facing mirror ring** it owns
///     (`QtFrameMirror`): one shm segment, one live fd, header + two frame
///     slots. Qt maps that fd and reads the newest frame by serial, exactly
///     as the ABI describes. The extra memcpy is Swift-internal (never bridge
///     traffic) and only runs while a display link is up.
///
/// The capture supplier reads from the *mirror*, not the helper ring:
/// `frontSurface()` must be called from one thread only (the session poll),
/// so the poll publishes into the mirror and every other consumer copies out
/// of it.
import DeviceRuntime
import Foundation
import HostRuntime
import LightTouchCore

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

// MARK: - Qt-facing mirror ring

/// One shm segment Qt maps for the display link.
///
/// Layout: `QtMirrorHeader` (32 bytes) followed by two frame slots of
/// `height * stride` bytes. Qt reads `serial`/`activeSlot` for new frames.
struct QtMirrorHeader {
    var magic: UInt64 = 0x4C54_4D51_5452_494E // "LTMQRIN"
    var serial: UInt64 = 0
    var width: Int32 = 0
    var height: Int32 = 0
    var stride: Int32 = 0
    var activeSlot: Int32 = 0
}

final class QtFrameMirror {
    /// The live shm fd handed to Qt in kLTEventDisplayLinkReady. Stays open
    /// until the mirror is replaced or closed; Qt mmaps it on receipt.
    let fd: Int32
    let generation: UInt64
    private(set) var width: Int
    private(set) var height: Int
    private(set) var stride: Int
    private var base: UnsafeMutableRawPointer
    private var byteCount: Int
    private let lock = NSLock()
    private var closed = false

    nonisolated(unsafe) private static var nextID: UInt64 = 0
    private static let idLock = NSLock()

    init?(width: Int, height: Int, generation: UInt64) {
        #if os(Windows)
        // The Windows transport uses named file mappings (DeviceRuntime's
        // Windows transport is not implemented yet either); fail gracefully.
        return nil
        #else
        guard width > 0, height > 0 else { return nil }
        let stride = width * 4
        let headerSize = MemoryLayout<QtMirrorHeader>.size
        let slotBytes = height * stride
        let total = headerSize + slotBytes * 2
        let id = Self.idLock.withLock { () -> UInt64 in defer { Self.nextID += 1 }; return Self.nextID }
        let name = "/ltm.qtmirror.\(getpid()).\(id)"
        var fd: Int32 = -1
        name.withCString { ptr in fd = shm_open(ptr, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR) }
        guard fd >= 0 else { return nil }
        name.withCString { _ = shm_unlink($0) } // unnamed: no residue on crash
        guard ftruncate(fd, off_t(total)) == 0 else { shm_close(fd); return nil }
        guard let base = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
            base != MAP_FAILED
        else { shm_close(fd); return nil }
        self.fd = fd
        self.generation = generation
        self.width = width
        self.height = height
        self.stride = stride
        self.base = base
        self.byteCount = total
        var header = QtMirrorHeader()
        header.width = Int32(width)
        header.height = Int32(height)
        header.stride = Int32(stride)
        withUnsafeBytes(of: &header) { base.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        #endif
    }

    deinit { close() }

    func close() {
        #if !os(Windows)
        lock.withLock {
            guard !closed else { return }
            closed = true
            munmap(base, byteCount)
            shm_close(fd)
        }
        #endif
    }

    /// Publishes one frame: copies BGRA rows into the inactive slot, flips
    /// `activeSlot`, bumps `serial`. Call from the session poll only.
    func publish(surface: ShmSurface) {
        #if !os(Windows)
        lock.withLock {
            guard !closed, surface.width == width, surface.height == height else { return }
            let headerSize = MemoryLayout<QtMirrorHeader>.size
            let slotBytes = height * stride
            var header = base.load(as: QtMirrorHeader.self)
            let slot = 1 - Int(header.activeSlot)
            let dst = base.advanced(by: headerSize + slot * slotBytes)
            let src = surface.baseAddress
            if surface.bytesPerRow == stride {
                dst.copyMemory(from: src, byteCount: slotBytes)
            } else {
                for y in 0..<height {
                    dst.advanced(by: y * stride)
                        .copyMemory(from: src.advanced(by: y * surface.bytesPerRow), byteCount: stride)
                }
            }
            header.activeSlot = Int32(slot)
            header.serial &+= 1
            withUnsafeBytes(of: &header) { base.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
        #endif
    }

    /// Copies the newest published frame out as an LTMImage (BGRA), or nil
    /// when nothing was published yet. Thread-safe; the capture path's read.
    func latestImage() -> LTMImage? {
        #if os(Windows)
        return nil
        #else
        lock.withLock {
            guard !closed else { return nil }
            let header = base.load(as: QtMirrorHeader.self)
            guard header.serial > 0 else { return nil }
            let headerSize = MemoryLayout<QtMirrorHeader>.size
            let slotBytes = height * stride
            let src = base.advanced(by: headerSize + Int(header.activeSlot) * slotBytes)
            var pixels = [UInt8](repeating: 0, count: slotBytes)
            pixels.withUnsafeMutableBytes { dst in
                dst.baseAddress!.copyMemory(from: src, byteCount: slotBytes)
            }
            return LTMImage(width: width, height: height, pixels: pixels)
        }
        #endif
    }

    var serial: UInt64 {
        #if os(Windows)
        return 0
        #else
        return lock.withLock { closed ? 0 : base.load(as: QtMirrorHeader.self).serial }
        #endif
    }
}

#if os(Linux) || canImport(Darwin)
private func shm_close(_ fd: Int32) { close(fd) }
#endif

// MARK: - Frame supplier for ScreenRecordingSession

enum ShmCapture {
    /// The `frame:` supplier for `ScreenRecordingSession.start`: the newest
    /// mirrored frame, or nil when there is none new. Thread-safe.
    static func supplier(for session: DeviceSession) -> () throws -> LTMImage? {
        // The supplier may run on the recorder's task; the mirror is the
        // thread-safe read side (frontSurface stays on the session poll).
        return { @Sendable in
            session.displayMirror?.latestImage()
        }
    }
}

// MARK: - Minimal PNG encoder (portable, no AppKit/CoreGraphics)

// Screenshots were AppKit (CGImage) upstream; the portable core needs its own
// encoder. This is a minimal truecolor PNG writer: 8-bit RGBA, no filtering,
// zlib "stored" (uncompressed) deflate blocks — valid PNG, dependency-free,
// portable to Windows. Compression ratio is not the goal; screenshots are
// one-shot.

enum LTMPNG {
    /// Encodes `image` (BGRA bytes) as PNG data, or nil on internal error.
    static func encode(_ image: LTMImage) -> Data? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, image.pixels.count >= w * h * 4 else { return nil }
        // Rows: filter byte 0 + RGBA pixels (BGRA -> RGBA swap).
        var raw = [UInt8]()
        raw.reserveCapacity(h * (1 + w * 4))
        for y in 0..<h {
            raw.append(0)
            let rowStart = y * w * 4
            for x in 0..<w {
                let i = rowStart + x * 4
                raw.append(image.pixels[i + 2]) // R
                raw.append(image.pixels[i + 1]) // G
                raw.append(image.pixels[i]) // B
                raw.append(image.pixels[i + 3]) // A
            }
        }
        let deflated = zlibStored(raw)
        var png = Data()
        // Signature.
        png.append(contentsOf: [137, 80, 78, 71, 13, 10, 26, 10])
        // IHDR.
        var ihdr = Data()
        ihdr.appendUInt32(UInt32(w))
        ihdr.appendUInt32(UInt32(h))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0]) // 8-bit, truecolor+alpha
        png.appendChunk(type: "IHDR", data: ihdr)
        png.appendChunk(type: "IDAT", data: deflated)
        png.appendChunk(type: "IEND", data: Data())
        return png
    }

    /// zlib wrapper around "stored" (uncompressed) deflate blocks.
    private static func zlibStored(_ raw: [UInt8]) -> Data {
        var out = Data()
        out.append(contentsOf: [0x78, 0x01]) // zlib header: deflate, 32K window
        var offset = 0
        while offset < raw.count {
            let n = min(65535, raw.count - offset)
            let isFinal = offset + n >= raw.count
            out.append(isFinal ? 0x01 : 0x00) // BFINAL + BTYPE=00 (stored)
            out.appendUInt16(UInt16(n))
            out.appendUInt16(~UInt16(n))
            out.append(contentsOf: raw[offset..<(offset + n)])
            offset += n
        }
        out.appendUInt32(adler32(raw))
        return out
    }

    private static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt32(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF)); append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }
    mutating func appendUInt16(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
    }
    mutating func appendChunk(type: String, data: Data) {
        appendUInt32(UInt32(data.count))
        let typeBytes = Array(type.utf8)
        append(contentsOf: typeBytes)
        append(data)
        var crcInput = Data(typeBytes)
        crcInput.append(data)
        appendUInt32(LTMPNG.crcForTest(crcInput))
    }
}

// Test hook: CRC32 over arbitrary data (kept internal; tests verify vectors).
extension LTMPNG {
    static func crcForTest(_ data: Data) -> UInt32 { crc32(data) }
    static func adlerForTest(_ data: [UInt8]) -> UInt32 { adler32(data) }
}
