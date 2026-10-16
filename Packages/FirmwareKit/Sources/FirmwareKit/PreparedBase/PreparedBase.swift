// PreparedBase: a `create` output packed as one blob for the app bundle (the built-in iPod), and unpacked into a
// device of its own.
//
//   try PreparedBase.pack(base: dir, to: blob)                          // the release build
//   try PreparedBase.unpack(blob, into: staging) { fraction in ... }    // the app's first launch, via firmwarekit
//   try PreparedBase.reseed(staging, seed: uuid)                        // then a unit identity of its own
//
// The format is the guest package's (.itpack, qemu-ios contrib/guest-package/mkpkg.py): "ITPACK01", a
// little-endian u32 index length, {"entries": [{"name", "size", "mode"}]} in stream order, then one zlib stream of
// the files' bytes. Not an archive the notary opens (it rejects the armv6 Mach-Os a volume's pages hold), and read
// as a stream: a base never sits in memory at once.
//
// pack writes the lock with the build machine's paths reduced to their last component. reseed gives the base the
// identity `create --seed` would have: only identity.json, the NOR's SysCfg and nvram, and the lock's identity,
// machine and nor hash depend on the seed (the n72 volume and store don't), so the result is that create's output.

import Crypto
import Foundation
import HostRuntime
import CZlibFK
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif

public enum PreparedBase {
    static let magic = Data("ITPACK01".utf8)
    static let chunk = 1 << 20

    struct Entry: Codable { var name: String, size: Int, mode: Int }

    static func invalid(_ blob: URL, _ why: String) -> FirmwareError {
        FirmwareError(.unsupported, "\(blob.lastPathComponent): \(why)")
    }

    // MARK: - Pack

    /// Every regular file under `base` (sorted; .DS_Store skipped) into `blob`.
    public static func pack(base: URL, to blob: URL) throws {
        let fm = FileManager.default
        var names: [String] = []
        guard let walk = fm.enumerator(atPath: base.path) else {
            throw FirmwareError(.internal, "can't read \(base.path)")
        }
        while let name = walk.nextObject() as? String {
            if (walk.fileAttributes?[.type] as? FileAttributeType) == .typeRegular,
                (name as NSString).lastPathComponent != ".DS_Store"
            {
                names.append(name)
            }
        }
        names.sort()
        guard names.contains("device.lock.json") else {
            throw FirmwareError(.unsupported, "\(base.path) has no device.lock.json")
        }
        let lock = try scrubbedLock(Data(contentsOf: base.appendingPathComponent("device.lock.json")))
        let entries = try names.map { name -> Entry in
            let attributes = try fm.attributesOfItem(atPath: base.appendingPathComponent(name).path)
            let size = name == "device.lock.json" ? lock.count : (attributes[.size] as? Int ?? 0)
            return Entry(name: name, size: size, mode: (attributes[.posixPermissions] as? Int ?? 0o644) & 0o777)
        }
        let index = try JSONEncoder().encode(["entries": entries])
        fm.createFile(atPath: blob.path, contents: nil)
        let out = try FileHandle(forWritingTo: blob)
        defer { try? out.close() }
        var head = magic
        withUnsafeBytes(of: UInt32(index.count).littleEndian) { head.append(contentsOf: $0) }
        try out.write(contentsOf: head + index)
        var z = z_stream()
        guard deflateInit_(&z, 6, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw FirmwareError(.internal, "deflateInit")
        }
        defer { deflateEnd(&z) }
        var buffer = [UInt8](repeating: 0, count: chunk)
        func deflate(_ input: Data, finish: Bool) throws {
            var input = [UInt8](input)
            try input.withUnsafeMutableBufferPointer { source in
                z.next_in = source.baseAddress
                z.avail_in = uInt(source.count)
                repeat {
                    let status = buffer.withUnsafeMutableBufferPointer { b -> Int32 in
                        z.next_out = b.baseAddress
                        z.avail_out = uInt(b.count)
                        return CZlibFK.deflate(&z, finish ? Z_FINISH : Z_NO_FLUSH)
                    }
                    guard status != Z_STREAM_ERROR else { throw FirmwareError(.internal, "deflate") }
                    try out.write(contentsOf: Data(buffer[0..<(chunk - Int(z.avail_out))]))
                } while z.avail_out == 0
            }
        }
        for name in names {
            if name == "device.lock.json" {
                try deflate(lock, finish: false)
                continue
            }
            let input = try FileHandle(forReadingFrom: base.appendingPathComponent(name))
            defer { try? input.close() }
            while let data = try input.read(upToCount: chunk), !data.isEmpty { try deflate(data, finish: false) }
        }
        try deflate(Data(), finish: true)
    }

    /// The lock with the host paths `create` records (its IPSW, decrypt cache, guest tools, helper, guest package)
    /// reduced to their last component: nothing reads them back, and a shipped blob names no build machine.
    static func scrubbedLock(_ data: Data) throws -> Data {
        guard var lock = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FirmwareError(.unsupported, "device.lock.json is not an object")
        }
        func name(_ value: Any?) -> Any { (value as? String).map { ($0 as NSString).lastPathComponent } ?? NSNull() }
        if var inputs = lock["inputs"] as? [String: Any] {
            if var ipsw = inputs["ipsw"] as? [String: Any] {
                ipsw["path"] = name(ipsw["path"])
                inputs["ipsw"] = ipsw
            }
            for key in ["decrypted", "guest_tools"] where inputs[key] != nil { inputs[key] = name(inputs[key]) }
            lock["inputs"] = inputs
        }
        if var tool = lock["tool"] as? [String: Any], tool["helper"] != nil {
            tool["helper"] = name(tool["helper"])
            lock["tool"] = tool
        }
        if var package = lock["guest_package"] as? [String: Any], var itpack = package["itpack"] as? [String: Any] {
            itpack["path"] = name(itpack["path"])
            package["itpack"] = itpack
            lock["guest_package"] = package
        }
        return try DeviceLock(json: lock).data()
    }

    // MARK: - Unpack

    /// Unpacks `blob` into `directory` (created), reporting the fraction of bytes written about every percent.
    /// Nothing outside `directory` is written: a name that leaves it is refused before any file is made. Packed modes
    /// are set once each file is complete; nand/ and its directories end read-only, as create leaves them.
    public static func unpack(_ blob: URL, into directory: URL, progress: (Double) throws -> Void = { _ in }) throws {
        let fm = FileManager.default
        let input = try FileHandle(forReadingFrom: blob)
        defer { try? input.close() }
        guard let head = try input.read(upToCount: 12), head.count == 12, head.prefix(8) == magic else {
            throw invalid(blob, "not a packed device")
        }
        let length = Int(head[8]) | Int(head[9]) << 8 | Int(head[10]) << 16 | Int(head[11]) << 24
        guard let indexData = try input.read(upToCount: length), indexData.count == length,
            let entries = try? JSONDecoder().decode([String: [Entry]].self, from: indexData)["entries"]
        else { throw invalid(blob, "bad index") }
        for e in entries
        where e.size < 0 || e.name.hasPrefix("/") || e.name.isEmpty
            || e.name.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0 == ".." || $0.isEmpty || $0 == "."
            })
        {
            throw invalid(blob, "bad entry \(e.name)")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = entries.reduce(0) { $0 + $1.size }
        let step = max(total / 100, 1)
        var written = 0
        var reported = -1
        var next = 0
        var remaining = 0
        var output: FileHandle?
        func url(_ e: Entry) -> URL { directory.appendingPathComponent(e.name) }
        /// Opens the next entry with bytes to receive, finishing every empty one on the way; false past the end.
        func open() throws -> Bool {
            while next < entries.count {
                let e = entries[next]
                next += 1
                try fm.createDirectory(at: url(e).deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: url(e).path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw FirmwareError(.internal, "create \(url(e).path)")
                }
                if e.size > 0 {
                    output = try FileHandle(forWritingTo: url(e))
                    remaining = e.size
                    return true
                }
                chmod(url(e).path, mode_t(e.mode))
            }
            return false
        }
        func emit(_ bytes: ArraySlice<UInt8>) throws {
            var bytes = bytes
            while !bytes.isEmpty {
                if remaining == 0 { guard try open() else { throw invalid(blob, "more data than its index names") } }
                let take = min(remaining, bytes.count)
                try output?.write(contentsOf: Data(bytes.prefix(take)))
                bytes = bytes.dropFirst(take)
                remaining -= take
                written += take
                if remaining == 0 {
                    try output?.close()
                    output = nil
                    chmod(url(entries[next - 1]).path, mode_t(entries[next - 1].mode))
                }
            }
            if written / step != reported {
                reported = written / step
                try progress(Double(written) / Double(max(total, 1)))
            }
        }
        var z = z_stream()
        guard inflateInit_(&z, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw FirmwareError(.internal, "inflateInit")
        }
        defer { inflateEnd(&z) }
        var buffer = [UInt8](repeating: 0, count: chunk)
        var status = Z_OK
        while status != Z_STREAM_END {
            guard var source = try input.read(upToCount: chunk).map({ [UInt8]($0) }), !source.isEmpty else {
                throw invalid(blob, "truncated stream")
            }
            try source.withUnsafeMutableBufferPointer { s in
                z.next_in = s.baseAddress
                z.avail_in = uInt(s.count)
                repeat {
                    status = buffer.withUnsafeMutableBufferPointer { b in
                        z.next_out = b.baseAddress
                        z.avail_out = uInt(b.count)
                        return inflate(&z, Z_NO_FLUSH)
                    }
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw invalid(blob, "corrupt stream")
                    }
                    try emit(buffer[0..<(chunk - Int(z.avail_out))])
                } while z.avail_out == 0 && status != Z_STREAM_END
            }
        }
        try output?.close()
        // Every named byte arrived, and the trailing empty files exist.
        guard remaining == 0, try !open() else { throw invalid(blob, "short file \(entries[max(next - 1, 0)].name)") }
        let nand = directory.appendingPathComponent("nand")
        if fm.fileExists(atPath: nand.path) { try Preparer.readOnly(nand) }
        try progress(1)
    }

    // MARK: - Identity

    /// Gives an unpacked n72 base the unit identity `create --seed seed` makes: identity.json, the NOR's SysCfg and
    /// nvram, and the lock's identity, machine and nor hash. Other boards' identities reach their volumes; refused.
    public static func reseed(_ base: URL, seed: String) throws {
        let fm = FileManager.default
        let lockURL = base.appendingPathComponent("device.lock.json")
        let identityURL = base.appendingPathComponent("identity.json")
        let norURL = base.appendingPathComponent("nor.bin")
        guard var lock = try JSONSerialization.jsonObject(with: Data(contentsOf: lockURL)) as? [String: Any] else {
            throw FirmwareError(.unsupported, "device.lock.json is not an object")
        }
        guard lock["board"] as? String == "n72ap" else {
            throw FirmwareError(.unsupported, "only an n72ap base takes a new identity, not \(lock["board"] ?? "?")")
        }
        let old = try UnitIdentity.load(from: identityURL)
        guard let model = old["model-number"], let region = old["region-info"] else {
            throw FirmwareError(.unsupported, "identity.json has no model or region")
        }
        let id = try UnitIdentity.synthesizeIPod(seed: seed, modelNumber: model, regionInfo: region)
        try fm.removeItem(at: identityURL)
        try id.write(to: identityURL)
        let nor = try N72NOR.reidentify(Data(contentsOf: norURL), identity: id)
        let mode = (try fm.attributesOfItem(atPath: norURL.path)[.posixPermissions] as? Int) ?? 0o444
        chmod(norURL.path, 0o644)
        try nor.write(to: norURL)
        chmod(norURL.path, mode_t(mode))
        lock["identity"] = ["seed": seed, "udid": id.udid ?? "", "sha256": try Preparer.digest(identityURL, SHA256())]
        var machine = lock["machine"] as? [String: Any] ?? [:]
        machine["wifi-mac"] = id["wifi-mac"]
        machine["bt-mac"] = id["bt-mac"]
        machine["ecid"] = id["unique-chip-id"]
        lock["machine"] = machine
        if var outputs = lock["outputs"] as? [String: Any], var record = outputs["nor"] as? [String: Any] {
            record["sha256"] = Preparer.sha256(nor)
            outputs["nor"] = record
            lock["outputs"] = outputs
        }
        try DeviceLock(json: lock).data().write(to: lockURL, options: .atomic)
    }
}
