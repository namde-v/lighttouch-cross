// The byte readers and writers FirmwareKit's formats share: integers at offsets of an image, hex, zlib's CRC-32.
import Foundation
import CZlibFK

func le16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }

func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}

func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
}

/// `v`'s low 16 bits, little-endian, at `o`.
func put16(_ b: inout [UInt8], _ o: Int, _ v: Int) {
    b[o] = UInt8(v & 0xFF)
    b[o + 1] = UInt8((v >> 8) & 0xFF)
}

/// `v`, little-endian, at `o`.
func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    for k in 0..<4 { b[o + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) }
}

/// zlib's CRC-32 of `b`.
#if os(Windows)
// zlib is unavailable on Windows; a small pure-Swift CRC-32 (IEEE).
func crc(_ b: ArraySlice<UInt8>) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in b {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
        }
    }
    return crc ^ 0xFFFF_FFFF
}
#else
func crc(_ b: ArraySlice<UInt8>) -> UInt32 {
    UInt32(b.withUnsafeBufferPointer { CZlibFK.crc32(0, $0.baseAddress, uInt($0.count)) })
}
#endif

extension Sequence<UInt8> {
    /// Lowercase hex, two digits a byte.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

extension UnsafeRawBufferPointer {
    func u16le(_ o: Int) -> UInt16 { UInt16(littleEndian: loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
    func u32le(_ o: Int) -> UInt32 { UInt32(littleEndian: loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
    func u64le(_ o: Int) -> UInt64 { UInt64(littleEndian: loadUnaligned(fromByteOffset: o, as: UInt64.self)) }
    func u32be(_ o: Int) -> UInt32 { UInt32(bigEndian: loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
}
