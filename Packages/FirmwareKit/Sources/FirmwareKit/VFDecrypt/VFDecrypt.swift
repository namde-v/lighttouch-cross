// VFDecrypt: decrypt an Apple "encrcdsa" v2 disk image (an iOS rootfs DMG) with its known 36-byte key
// (AES-128 key + HMAC-SHA1 key); chunk n's IV = HMAC-SHA1(hmac_key, be32(n))[:16]. Ports imgtools/vfdecrypt.c.
//
//   try VFDecrypt.decrypt(input: encrypted, output: plain, key: key36)       // file to file
//   try VFDecrypt.decrypt(from: fd, output: plain, key: key36)               // any sequential fd (a pipe)
//   try ipsw.stream(osImage) { try VFDecrypt.decrypt(from: $0.fileDescriptor, output: plain, key: key36) }
//
// Streams in fixed-size chunks; the input is read once, front to back, so it can come straight off
// `unzip -p` without a temporary copy of the encrypted image.

import _CryptoExtras
import Crypto
import Foundation
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif

public enum VFDecrypt {
    public static func decrypt(input: URL, output: URL, key: Data) throws {
        let fd = open(input.path, O_RDONLY)
        guard fd >= 0 else { throw FirmwareError(.internal, "open \(input.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        try decrypt(from: fd, output: output, key: key)
    }

    public static func decrypt(from fd: Int32, output: URL, key: Data) throws {
        guard key.count == 36 else {
            throw FirmwareError(.keyMissing, "vfdecrypt key must be 36 bytes, got \(key.count)")
        }
        let aesKey = [UInt8](key.prefix(16))
        let hmacKey = [UInt8](key.dropFirst(16))
        var header = [UInt8](repeating: 0, count: 0x100)
        guard readFully(fd, &header, 0, 0x100) == 0x100, header[0..<8].elementsEqual("encrcdsa".utf8) else {
            throw FirmwareError(.unsupported, "not encrcdsa")
        }
        let be = { (o: Int, n: Int) in header[o..<o + n].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        let bs = Int(be(52, 4))
        let dataOffset = Int(be(64, 8))
        var left = be(56, 8)
        guard bs > 0, bs % 16 == 0, bs <= 1 << 24 else {
            throw FirmwareError(.unsupported, "encrcdsa block size \(bs)")
        }

        // Position at the data: header bytes already read count toward it; skip forward, never back.
        var ct = [UInt8](repeating: 0, count: bs)
        var carried = 0
        if dataOffset < 0x100 {
            carried = 0x100 - dataOffset
            ct.replaceSubrange(0..<carried, with: header[dataOffset..<0x100])
        } else {
            var skip = dataOffset - 0x100
            while skip > 0 {
                let n = readFully(fd, &ct, 0, min(skip, bs))
                guard n > 0 else { throw FirmwareError(.unsupported, "short image") }
                skip -= n
            }
        }

        guard FileManager.default.createFile(atPath: output.path, contents: nil),
            let out = FileHandle(forWritingAtPath: output.path)
        else {
            throw FirmwareError(.internal, "cannot create \(output.path)")
        }
        defer { try? out.close() }
        var pending = Data(capacity: 1 << 22)
        var n: UInt32 = 0
        while left > 0 {
            let r = carried + readFully(fd, &ct, carried, bs - carried)
            carried = 0
            guard r > 0 else { throw FirmwareError(.unsupported, "short image") }
            guard r % 16 == 0 else {
                throw FirmwareError(.unsupported, "encrcdsa chunk \(n) is \(r) bytes, not whole AES blocks")
            }
            let nb = [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            // Chunk n's IV = HMAC-SHA1(hmac_key, be32(n))[:16] (was: CCHmac(kCCHmacAlgSHA1, ...)).
            let iv = Array(
                HMAC<Insecure.SHA1>.authenticationCode(for: nb, using: SymmetricKey(data: hmacKey)).prefix(16))
            // Raw AES-CBC, no padding (was: CCCrypt(kCCDecrypt, kCCAlgorithmAES, 0, ...)).
            let decrypted: Data
            do {
                decrypted = try AES._CBC.decrypt(
                    ct.prefix(r), using: SymmetricKey(data: aesKey), iv: AES._CBC.IV(ivBytes: iv), noPadding: true)
            } catch {
                throw FirmwareError(.internal, "AES-CBC decrypt failed (\(error))")
            }
            let take = min(UInt64(decrypted.count), left)
            pending.append(contentsOf: decrypted.prefix(Int(take)))
            left -= take
            if pending.count >= 1 << 22 {
                try out.write(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
            }
            n += 1
        }
        try out.write(contentsOf: pending)
    }

    /// Reads until `count` bytes or EOF; returns the bytes read.
    static func readFully(_ fd: Int32, _ buf: inout [UInt8], _ at: Int, _ count: Int) -> Int {
        var got = 0
        buf.withUnsafeMutableBytes { p in
            guard let start = p.baseAddress else { return }  // an empty buffer holds nothing
            while got < count {
                let r = read(fd, start + at + got, count - got)
                if r > 0 { got += r } else if r < 0, errno == EINTR { continue } else { break }
            }
        }
        return got
    }
}
