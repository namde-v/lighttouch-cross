import CActivation
import Crypto
import Foundation
#if canImport(MachOKit)
import MachOKit
#endif
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif

public struct ActivationFailure: Error, CustomStringConvertible, Sendable {
    public let code = "activation_failed"
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "\(code): \(message)" }
}

/// An unconditional part of preparing a new device. No executable or strategy is supplied by callers.
public enum Activation {
    public struct Result: Sendable, Equatable, Codable {
        public let inputSHA256: String, outputSHA256: String
        // Optional so device records written by earlier releases remain decodable.
        public var patch: Patch? = nil
        /// The data route (iOS 6): lockdownd left stock, these keys seeded into /var/root/Library/Lockdown/data_ark.plist.
        public var dataArk: [String: String]? = nil
        var record: [String: Any] {
            var result: [String: Any] = ["input_sha256": inputSHA256, "output_sha256": outputSHA256]
            if let dataArk { result["data_ark"] = dataArk }
            if let patch {
                result["patch"] = [
                    "strategy": patch.strategy, "isa": patch.isa, "offset": patch.offset,
                    "original": patch.original.hexString,
                    "replacement": patch.replacement.hexString,
                ]
            }
            return result
        }
    }
    public struct Patch: Sendable, Equatable, Codable {
        public let strategy: String, isa: String
        public let offset: Int
        public let original: Data, replacement: Data
    }

    public static func run(on file: URL) throws -> Result {
        let before = try Data(contentsOf: file)
        var after = before
        var error: UnsafePointer<CChar>?
        var report = LTActivationReport()
        let success = after.withUnsafeMutableBytes {
            lt_activate_report($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &report, &error)
        }
        guard success != 0 else {
            throw ActivationFailure(error.map { String(cString: $0) } ?? "Unsupported activation path")
        }
        // 1.x ships unsigned lockdownd and predates mandatory code signing. Only
        // the positively recognized 1.x path may remain unsigned; later paths
        // still require a valid signature allocation. Existing signatures are refreshed.
        if success != 2 || MachOSignature.codeSignature(in: after) != nil {
            after = try signed(after)
        }
        // Preserve the HFS catalog record and its metadata; this file is on a disposable staging volume.
        #if os(Windows)
        // No O_NOFOLLOW or fchmod(2) on Windows: open binary (no CRLF translation) and use the
        // path-based UCRT _chmod, which honors the write bit (read-only vs. writable).
        let metadata = open(file.path, O_RDONLY | _O_BINARY)
        guard metadata >= 0 else { throw ActivationFailure("Cannot open activation target") }
        var original = stat()
        guard fstat(metadata, &original) == 0, Int32(original.st_mode) & S_IFMT == S_IFREG else {
            close(metadata)
            throw ActivationFailure("Activation target is not a regular file")
        }
        defer {
            _ = chmod(file.path, Int32(original.st_mode) & 0o7777)
            close(metadata)
        }
        guard chmod(file.path, Int32(original.st_mode) & 0o7777 | 0o200) == 0 else {
            throw ActivationFailure("Cannot make activation target writable")
        }
        let out = open(file.path, O_WRONLY | _O_BINARY)
        guard out >= 0 else { throw ActivationFailure("Cannot open activation target") }
        defer { close(out) }
        try after.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }  // empty: nothing to write
            var offset = 0
            while offset < bytes.count {
                // UCRT write takes a UInt32 count and returns Int32.
                let count = Int(write(out, start.advanced(by: offset), UInt32(bytes.count - offset)))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ActivationFailure("Cannot write activation target") }
                offset += count
            }
        }
        #else
        let metadata = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard metadata >= 0 else { throw ActivationFailure("Cannot open activation target") }
        var original = stat()
        guard fstat(metadata, &original) == 0, original.st_mode & S_IFMT == S_IFREG else {
            close(metadata)
            throw ActivationFailure("Activation target is not a regular file")
        }
        defer {
            _ = fchmod(metadata, original.st_mode & 0o7777)
            close(metadata)
        }
        guard fchmod(metadata, original.st_mode & 0o7777 | 0o200) == 0 else {
            throw ActivationFailure("Cannot make activation target writable")
        }
        let out = open(file.path, O_WRONLY | O_NOFOLLOW)
        guard out >= 0 else { throw ActivationFailure("Cannot open activation target") }
        defer { close(out) }
        try after.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }  // empty: nothing to write
            var offset = 0
            while offset < bytes.count {
                let count = write(out, start.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ActivationFailure("Cannot write activation target") }
                offset += count
            }
        }
        #endif
        let patch = Patch(
            strategy: String(cString: report.strategy),
            isa: String(cString: report.isa),
            offset: report.offset,
            original: withUnsafeBytes(of: report.original) { Data($0.prefix(Int(report.width))) },
            replacement: withUnsafeBytes(of: report.replacement) { Data($0.prefix(Int(report.width))) }
        )
        return Result(inputSHA256: Preparer.sha256(before), outputSHA256: Preparer.sha256(after), patch: patch)
    }

    /// iOS 6 lockdownd, which no binary strategy matches, takes its activation state from its data ark: the
    /// lockdown_cache domain's ActivationState, which a factory unit carries as FactoryActivated. Offered only when
    /// lockdownd names that domain and state; the binary stays stock.
    public static func dataArkRoute(lockdownd: Data) -> Result? {
        guard lockdownd.range(of: Data("com.apple.mobile.lockdown_cache\0".utf8)) != nil,
            lockdownd.range(of: Data("FactoryActivated\0".utf8)) != nil
        else { return nil }
        let h = Preparer.sha256(lockdownd)
        return Result(
            inputSHA256: h,
            outputSHA256: h,
            dataArk: ["com.apple.mobile.lockdown_cache-ActivationState": "FactoryActivated"]
        )
    }

    /// Rebuild the existing code-page hashes as an ad-hoc signature, retaining entitlements and
    /// special-slot hashes. Patching does not change the binary's size or its signing allocation.
    static func signed(_ data: Data) throws -> Data {
        var b = [UInt8](data)
        func invalid() -> ActivationFailure { ActivationFailure("Unsupported code signature") }
        guard let cs = MachOSignature.codeSignature(in: data) else { throw invalid() }
        let (start, size) = cs
        guard size >= 12, start <= b.count - size, be32(b, start) == 0xFADE_0CC0 else { throw invalid() }
        let length = Int(be32(b, start + 4))
        let count = Int(be32(b, start + 8))
        guard length >= 12, length <= size, count <= (length - 12) / 8 else { throw invalid() }
        var entries: [(UInt32, Int)] = []
        var directories = 0
        for i in 0..<count {
            let type = be32(b, start + 12 + i * 8)
            let offset = Int(be32(b, start + 16 + i * 8))
            guard offset >= 12 + count * 8, offset <= length - 8 else { throw invalid() }
            let blob = start + offset
            let blobLength = Int(be32(b, blob + 4))
            guard blobLength >= 8, blobLength <= length - offset else { throw invalid() }
            if type == 0 || (0x1000...0x1005).contains(type) {
                guard blobLength >= 44, be32(b, blob) == 0xFADE_0C02 else { throw invalid() }
                let hashOffset = Int(be32(b, blob + 16))
                let special = Int(be32(b, blob + 24))
                let slots = Int(be32(b, blob + 28))
                let limit = Int(be32(b, blob + 32))
                let hashSize = Int(b[blob + 36])
                let hashType = b[blob + 37]
                let exponent = Int(b[blob + 39])
                guard exponent > 0, exponent <= 20, limit > 0, limit <= start,
                    (hashType == 1 && hashSize == 20) || (hashType == 2 && hashSize == 32),
                    hashOffset >= 44 + special * hashSize,
                    hashOffset <= blobLength, slots <= (blobLength - hashOffset) / hashSize
                else { throw invalid() }
                let page = 1 << exponent
                guard slots == (limit + page - 1) / page else { throw invalid() }
                // Scatter layouts require a different page mapping, so fail before touching disk.
                if be32(b, blob + 8) >= 0x20100 {
                    guard blobLength >= 48, be32(b, blob + 44) == 0 else { throw invalid() }
                }
                putBE32(&b, blob + 12, be32(b, blob + 12) | 2)  // CS_ADHOC
                for slot in 0..<slots {
                    let bytes = Data(b[(slot * page)..<min(limit, (slot + 1) * page)])
                    let digest =
                        hashType == 1 ? Array(Insecure.SHA1.hash(data: bytes)) : Array(SHA256.hash(data: bytes))
                    b.replaceSubrange(
                        (blob + hashOffset + slot * hashSize)..<(blob + hashOffset + (slot + 1) * hashSize),
                        with: digest
                    )
                }
                directories += 1
            }
            if type != 0x10000 { entries.append((type, offset)) }  // Remove the now-invalid CMS signature.
        }
        guard directories > 0, entries.contains(where: { $0.0 == 0 }) else { throw invalid() }
        for i in 0..<count {
            putBE32(&b, start + 12 + i * 8, i < entries.count ? entries[i].0 : 0)
            putBE32(&b, start + 16 + i * 8, i < entries.count ? UInt32(entries[i].1) : 0)
        }
        putBE32(&b, start + 8, UInt32(entries.count))
        return Data(b)
    }
}

private func putBE32(_ b: inout [UInt8], _ offset: Int, _ value: UInt32) {
    for i in 0..<4 { b[offset + i] = UInt8(truncatingIfNeeded: value >> (24 - i * 8)) }
}

/// Mach-O header checks for the guest helpers, through MachOKit: thin/fat files, their slices' cpu, load
/// commands and LC_CODE_SIGNATURE.
enum MachOSignature {
    static let armCPU: Int32 = 12, armv7: Int32 = 9  // CPU_TYPE_ARM, CPU_SUBTYPE_ARM_V7

    #if canImport(MachOKit)
    static func codeSignature(_ cmds: some Sequence<LoadCommand>) -> LoadCommandInfo<linkedit_data_command>? {
        for lc in cmds { if case .codeSignature(let info) = lc { return info } }
        return nil
    }
    #endif

    /// ipad1_rootfs.guest_tool_problem: nil for a thin armv7 Mach-O that 3.2's dyld takes (no LC_MAIN, no
    /// LC_VERSION_MIN_IPHONEOS) and that is signed; else why not.
    static func guestToolProblem(_ url: URL) -> String? {
        #if canImport(MachOKit)
        guard case .machO(let m)? = try? MachOKit.loadFromFile(url: url), !m.is64Bit else {
            return "not a thin 32-bit Mach-O"
        }
        let h = m.header.layout
        guard h.cputype == armCPU, h.cpusubtype == armv7 else { return "cpu \(h.cputype)/\(h.cpusubtype), not armv7" }
        for lc in m.loadCommands {
            switch lc {
            case .main, .versionMinIphoneos: return "carries LC_MAIN/LC_VERSION_MIN (not run through machotool mkold)"
            default: continue
            }
        }
        return codeSignature(m.loadCommands) != nil ? nil : "unsigned (ldid -S)"
        #else
        // MachOKit is unavailable on Windows; Mach-O validation is skipped.
        return nil
        #endif
    }

    /// ipad1_rootfs.appsync_problem: nil for a fat Mach-O with an armv7 slice and a signature per slice.
    static func appSyncProblem(_ url: URL) -> String? {
        #if canImport(MachOKit)
        guard case .fat(let f)? = try? MachOKit.loadFromFile(url: url), let slices = try? f.machOFiles() else {
            return "not a fat Mach-O (expected armv6+armv7)"
        }
        for (i, s) in slices.enumerated() where codeSignature(s.loadCommands) == nil {
            return "slice \(i) (cpu \(s.header.layout.cputype)/\(s.header.layout.cpusubtype)) is not ldid-signed"
        }
        return slices.contains { $0.header.layout.cputype == armCPU && $0.header.layout.cpusubtype == armv7 }
            ? nil : "no armv7 slice"
        #else
        return nil
        #endif
    }

    /// 2.x/3.0 dyld needs classic relocations and an ARMv6 slice; fail before baking a modern helper.
    static func earlyARMProblem(_ url: URL) -> String? {
        #if canImport(MachOKit)
        guard let file = try? MachOKit.loadFromFile(url: url) else { return "not a Mach-O" }
        let images: [MachOFile]
        switch file {
        case .machO(let image): images = [image]
        case .fat(let fat):
            guard let slices = try? fat.machOFiles() else { return "unreadable slices" }
            images = slices
        }
        guard
            let image = images.first(where: { $0.header.layout.cputype == armCPU && $0.header.layout.cpusubtype == 6 })
        else { return "no armv6 slice" }
        for command in image.loadCommands {
            switch command {
            case .dyldInfoOnly, .main, .versionMinIphoneos, .buildVersion:
                return "requires a newer dyld; rebuild with LEGACY_LINK=1"
            default: continue
            }
        }
        return codeSignature(image.loadCommands) == nil ? "unsigned armv6 slice" : nil
        #else
        return nil
        #endif
    }

    /// LC_CODE_SIGNATURE's (dataoff, datasize) of a thin 32-bit Mach-O in memory (Activation.signed patches the buffer).
    static func codeSignature(in data: Data) -> (offset: Int, size: Int)? {
        #if canImport(MachOKit)
        data.withUnsafeBytes { b -> (Int, Int)? in
            guard b.count >= 28, let base = b.baseAddress, b.loadUnaligned(as: UInt32.self) == 0xFEED_FACE,
                let cs = codeSignature(MachOImage(ptr: base.assumingMemoryBound(to: mach_header.self)).loadCommands)
            else { return nil }
            return (Int(cs.dataoff), Int(cs.datasize))
        }
        #else
        // MachOKit is unavailable on Windows: parse the 32-bit Mach-O header directly.
        // mach_header (28 bytes): magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags.
        // Each load command starts with cmd, cmdsize; LC_CODE_SIGNATURE (0x1D) is a
        // linkedit_data_command: cmd, cmdsize, dataoff, datasize.
        data.withUnsafeBytes { b -> (Int, Int)? in
            guard let base = b.baseAddress, b.count >= 28 else { return nil }
            guard base.loadUnaligned(as: UInt32.self) == 0xFEED_FACE else { return nil }
            let ncmds = base.advanced(by: 16).loadUnaligned(as: UInt32.self)
            var off = 28
            for _ in 0..<ncmds {
                guard off + 8 <= b.count else { return nil }
                let cmd = base.advanced(by: off).loadUnaligned(as: UInt32.self)
                let cmdsize = base.advanced(by: off + 4).loadUnaligned(as: UInt32.self)
                guard cmdsize >= 8, off + Int(cmdsize) <= b.count else { return nil }
                if cmd == 0x1D, cmdsize >= 16 {
                    let dataoff = base.advanced(by: off + 8).loadUnaligned(as: UInt32.self)
                    let datasize = base.advanced(by: off + 12).loadUnaligned(as: UInt32.self)
                    return (Int(dataoff), Int(datasize))
                }
                off += Int(cmdsize)
            }
            return nil
        }
        #endif
    }
}
