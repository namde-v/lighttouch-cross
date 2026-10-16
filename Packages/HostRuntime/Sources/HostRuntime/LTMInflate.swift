// Portable raw-deflate inflate for GuestPack.read. On Apple platforms this is
// NSData's Compression-backed decompressed(using: .zlib); everywhere else it
// is zlib directly (the CZlib system target). Both spellings are raw deflate
// with the adler32 trailer ignored, matching the 2-byte header strip in
// GuestPack.read.

import Foundation

#if canImport(Compression)
import Compression

func inflateRawDeflate(_ data: Data) throws -> Data {
    try (data as NSData).decompressed(using: .zlib) as Data
}

#elseif os(Windows)
// zlib is not available on Windows; GuestPack reading is not supported there.
import CZlibHost

func inflateRawDeflate(_ data: Data) throws -> Data {
    throw CocoaError(.fileReadCorruptFile)
}

#else
import CZlibHost

func inflateRawDeflate(_ data: Data) throws -> Data {
    func corrupt() -> Error { CocoaError(.fileReadCorruptFile) }
    // An empty index covers an empty stream; nothing to inflate.
    guard !data.isEmpty else { return Data() }
    var stream = z_stream()
    // -MAX_WBITS: raw deflate — no zlib header expected, trailer ignored.
    guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw corrupt()
    }
    defer { inflateEnd(&stream) }
    var output = Data()
    let status: Int32 = try data.withUnsafeBytes { input -> Int32 in
        guard let base = input.baseAddress else { throw corrupt() }
        stream.next_in = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: Bytef.self))
        stream.avail_in = uInt(input.count)
        var status: Int32 = Z_OK
        while status == Z_OK {
            var chunk = [Bytef](repeating: 0, count: 65536)
            status = chunk.withUnsafeMutableBufferPointer { buffer in
                stream.next_out = buffer.baseAddress
                stream.avail_out = uInt(buffer.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            output.append(contentsOf: chunk.prefix(chunk.count - Int(stream.avail_out)))
        }
        return status
    }
    guard status == Z_STREAM_END else { throw corrupt() }
    return output
}
#endif
