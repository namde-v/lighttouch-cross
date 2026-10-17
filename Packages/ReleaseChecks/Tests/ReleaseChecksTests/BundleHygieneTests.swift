import Foundation
#if !os(Windows)
import RCZlib
#endif
import Testing

@testable import ReleaseChecks

/// Fixture bundles, each broken one way (was tests/release/test-bundle-hygiene.py's self-test).
struct BundleHygieneTests {
    let guest = BundleHygiene.guest

#if os(macOS)
    /// On macOS the fixtures are real binaries (cc) and archives (aa); on Linux there is no Mach-O toolchain,
    /// so these fixtures — and the tests built on them — are macOS-only. The platform-free paths (zlib inflate,
    /// the packed-device format, Package.resolved parsing, SHA-256) are tested below on every platform.
    struct Fixture {
        let root: URL, stripped: Data, debug: Data
        init(root: URL) throws {
            self.root = root
            let main = root.appendingPathComponent("main.c")
            try "int main(void) { return 0; }\n".write(to: main, atomically: true, encoding: .utf8)
            for args in [
                ["-g", "-c", main.path, "-o", root.appendingPathComponent("main.o").path],
                [root.appendingPathComponent("main.o").path, "-o", root.appendingPathComponent("debug").path],
            ] {
                try #require(try Shell.run(["cc"] + args).succeeded)
            }
            try FileManager.default.copyItem(
                at: root.appendingPathComponent("debug"),
                to: root.appendingPathComponent("stripped")
            )
            try #require(try Shell.run(["strip", "-S", "-x", root.appendingPathComponent("stripped").path]).succeeded)
            stripped = try Data(contentsOf: root.appendingPathComponent("stripped"))
            debug = try Data(contentsOf: root.appendingPathComponent("debug"))
        }

        func write(_ data: Data, _ path: String, in app: URL) throws {
            let url = app.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }

        func guest(_ members: [String: Data], into app: URL) throws {
            let staged = root.appendingPathComponent(app.lastPathComponent + "-guest")
            try? FileManager.default.removeItem(at: staged)
            for (name, data) in members { try write(data, name, in: staged) }
            let archive = app.appendingPathComponent(BundleHygiene.guest)
            try FileManager.default.createDirectory(
                at: archive.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: archive)
            try #require(try Shell.run(["aa", "archive", "-d", staged.path, "-o", archive.path]).succeeded)
        }

        func bundle(_ label: String) throws -> URL {
            let app = root.appendingPathComponent("\(label).app")
            for (name, salt) in [
                ("Contents/MacOS/usbmuxd", "u"), ("Contents/Frameworks/libplist-2.0.4.dylib", "p"),
                ("Contents/MacOS/inetcat", "i"), ("Contents/MacOS/LightTouchServices", "w"),
            ] {
                try write(stripped + Data(salt.utf8), name, in: app)  // distinct contents, still a Mach-O
            }
            try guest(["guest-tools/it_agent": stripped + Data("a".utf8)], into: app)
            for directory in [
                "usbmuxd", "libimobiledevice-glue", "libplist", "qemu", "inetcat", "libusbmuxd",
            ] {
                try write(Data("license text".utf8), "Contents/Resources/licenses/\(directory)/COPYING", in: app)
                try write(
                    Data("\(directory): https://example.invalid/\(directory).tar.gz".utf8),
                    "Contents/Resources/licenses/\(directory)/SOURCE.txt",
                    in: app
                )
            }
            try write(Data("MIT".utf8), "Contents/Resources/licenses/swift/Example/LICENSE.txt", in: app)
            try write(
                Data(
                    "Licenses: usbmuxd, libimobiledevice-glue, libplist, QEMU, inetcat, libusbmuxd"
                        .utf8
                ),
                "Contents/Resources/Help.txt",
                in: app
            )
            return app
        }

        func packed(_ app: URL, seed: String, extra: Data = Data()) throws {
            let files: [(String, Data)] = [
                ("device.lock.json", try JSONSerialization.data(withJSONObject: ["identity": ["seed": seed]])),
                ("identity.json", try JSONSerialization.data(withJSONObject: ["seed": seed])),
                ("nand/cs0/1.page", Data(repeating: UInt8(ascii: "p"), count: 5000) + extra),
            ]
            let index = try JSONSerialization.data(withJSONObject: [
                "entries": files.map { ["name": $0.0, "size": $0.1.count, "mode": 0o444] }
            ])
            let body = files.reduce(Data()) { $0 + $1.1 }
            var length = UInt32(index.count).littleEndian
            try write(
                Data("ITPACK01".utf8) + Data(bytes: &length, count: 4) + index + deflate(body),
                "Contents/Resources/Device/n72ap-7E18.itbase",
                in: app
            )
        }
    }

    func problems(_ app: URL) throws -> [String] {
        try BundleHygiene.problems(app: app, packages: ["example"], localMarkers: ["/Users/someone"])
    }

    func expect(_ app: URL, _ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let found = try problems(app)
        #expect(
            found.contains { $0.contains(text) },
            "\(app.lastPathComponent): expected “\(text)”, got \(found)",
            sourceLocation: sourceLocation
        )
    }

    /// Every build copies the guest tools (guest.aar), not only Archive: without them a Debug build couldn't prepare
    /// any device ("guest helper it_agent missing from …/Resources/guest-tools").
    @Test func everyBuildCopiesTheGuestTools() throws {
        let project = try String(
            contentsOf: repository.appendingPathComponent("LightTouchMac.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let guestFile = try #require(project.firstMatch(of: /(\w+) \/\* Guest in [^*]+\*\/ = \{isa = PBXBuildFile/))
        let phases = project.split(separator: "isa = PBXCopyFilesBuildPhase;").dropFirst()
            .map { $0.prefix { $0 != "}" } }
            .filter { $0.contains("files = (") && $0.split(separator: "files = (")[1].contains(guestFile.1) }
        #expect(phases.count == 1, "one phase copies Guest")
        #expect(
            phases.first?.contains("runOnlyForDeploymentPostprocessing = 0;") == true,
            "and not only when archiving"
        )
    }

    @Test func aCompleteBundlePassesAndEachBreakageIsNamed() throws {
        try withScratch { root in
            let f = try Fixture(root: root)
            let good = try f.bundle("good")
            #expect(try problems(good) == [])
            try f.packed(good, seed: BundleHygiene.placeholderSeed)
            #expect(try problems(good) == [])

            var broken = try f.bundle("no-license")
            try FileManager.default.removeItem(
                at: broken.appendingPathComponent("Contents/Resources/licenses/libimobiledevice-glue/COPYING")
            )
            try expect(broken, "no license text for libimobiledevice-glue")
            broken = try f.bundle("no-source")
            try FileManager.default.removeItem(
                at: broken.appendingPathComponent("Contents/Resources/licenses/usbmuxd/SOURCE.txt")
            )
            try expect(broken, "no SOURCE.txt naming the source of usbmuxd")
            broken = try f.bundle("local-path")
            try f.write(
                Data(#"{"path": "/Users/someone/Developer/qemu-ios"}"#.utf8),
                "Contents/Resources/build-inputs.json",
                in: broken
            )
            try expect(broken, "names a local path: Contents/Resources/build-inputs.json")
            broken = try f.bundle("packed-local-path")
            try f.packed(
                broken,
                seed: BundleHygiene.placeholderSeed,
                extra: Data("/Users/someone/Library/Caches/x.ipsw".utf8)
            )
            try expect(broken, "names a local path: Contents/Resources/Device/n72ap-7E18.itbase (packed)")
            broken = try f.bundle("packed-identity")
            try f.packed(broken, seed: "6A1F0E2B-0000-4000-8000-000000000000")
            try expect(broken, "carries a unit identity")
            broken = try f.bundle("unattributed")
            try f.write(f.stripped + Data("n".utf8), "Contents/MacOS/newtool", in: broken)
            try expect(broken, "unattributed Mach-O (add it to binaries with its licenses): Contents/MacOS/newtool")
            broken = try f.bundle("unstripped")
            try f.write(f.debug, "Contents/MacOS/usbmuxd", in: broken)
            try expect(broken, "not stripped (has a debug map): Contents/MacOS/usbmuxd")
            broken = try f.bundle("dsym")
            try FileManager.default.createDirectory(
                at: broken.appendingPathComponent("Contents/Resources/usbmuxd.dSYM/Contents"),
                withIntermediateDirectories: true
            )
            try expect(broken, "a dSYM ships")
            broken = try f.bundle("twice")
            try f.guest(
                ["guest-tools/it_agent": f.stripped + Data("a".utf8), "tools/it_agent": f.stripped + Data("a".utf8)],
                into: broken
            )
            try expect(broken, "ships twice: \(guest)/guest-tools/it_agent and \(guest)/tools/it_agent")
            broken = try f.bundle("loose")
            try f.write(f.stripped + Data("g".utf8), "Contents/Resources/guest-tools/it_pbd", in: broken)
            try expect(broken, "nested code under Resources (pack it into")
            broken = try f.bundle("packed-local")
            try f.guest(
                [
                    "guest-tools/it_agent": f.stripped + Data("a".utf8),
                    "guest-tools/it.plist": Data("/Users/someone/x".utf8),
                ],
                into: broken
            )
            try expect(broken, "names a local path: \(guest)/guest-tools/it.plist")
            broken = try f.bundle("swift")
            try FileManager.default.removeItem(
                at: broken.appendingPathComponent("Contents/Resources/licenses/swift/Example")
            )
            try expect(broken, "no license text for the Swift package example")
            broken = try f.bundle("help")
            try f.write(Data("Licenses: usbmuxd".utf8), "Contents/Resources/Help.txt", in: broken)
            try expect(broken, "Help.txt does not name libimobiledevice-glue")
        }
    }

#else
    // The inflate checks need zlib, which is unavailable on Windows
    // (BundleHygiene.inflate is a stub there): Linux-only.
#if !os(Windows)
    /// The platform-free checks, exercised on Linux: inflate, the packed-device format, Package.resolved
    /// parsing, Mach-O magic detection and SHA-256 (via swift-crypto's Crypto here, CryptoKit on macOS).
    @Test func inflateRoundTripsADeflatedStream() throws {
        try withScratch { root in
            var body = Data()
            for i in 0..<2000 { body += Data("line \(i): the quick brown fox jumps over the lazy dog\n".utf8) }
            let file = root.appendingPathComponent("stream.z")
            try deflate(body).write(to: file)
            let handle = try FileHandle(forReadingFrom: file)
            var out = Data()
            let ok = BundleHygiene.inflate(handle) { out += $0 }
            try? handle.close()
            #expect(ok)
            #expect(out == body)
        }
    }

    @Test func inflateRejectsAGarbageStream() throws {
        try withScratch { root in
            let file = root.appendingPathComponent("garbage.z")
            try Data("this is not a zlib stream".utf8).write(to: file)
            let handle = try FileHandle(forReadingFrom: file)
            var out = Data()
            let ok = BundleHygiene.inflate(handle) { out += $0 }
            try? handle.close()
            #expect(!ok)
        }
    }
#endif

    func itbase(_ files: [(String, Data)]) throws -> Data {
        let index = try JSONSerialization.data(withJSONObject: [
            "entries": files.map { ["name": $0.0, "size": $0.1.count, "mode": 0o444] }
        ])
        var length = UInt32(index.count).littleEndian
        let body = files.reduce(Data()) { $0 + $1.1 }
        return Data("ITPACK01".utf8) + Data(bytes: &length, count: 4) + index + deflate(body)
    }

    func packedURL(_ files: [(String, Data)], in root: URL) throws -> URL {
        let url = root.appendingPathComponent("n72ap-7E18.itbase")
        try itbase(files).write(to: url)
        return url
    }

    func identityFiles(seed: String, extra: Data = Data()) throws -> [(String, Data)] {
        [
            ("device.lock.json", try JSONSerialization.data(withJSONObject: ["identity": ["seed": seed]])),
            ("identity.json", try JSONSerialization.data(withJSONObject: ["seed": seed])),
            ("nand/cs0/1.page", Data(repeating: UInt8(ascii: "p"), count: 5000) + extra),
        ]
    }

    @Test func packedDeviceWithThePlaceholderSeedPasses() throws {
        try withScratch { root in
            let url = try packedURL(identityFiles(seed: BundleHygiene.placeholderSeed), in: root)
            #expect(BundleHygiene.packedProblems(url, name: "n72ap-7E18.itbase", local: []) == [])
        }
    }

    @Test func packedDeviceWithAUnitIdentityIsNamed() throws {
        try withScratch { root in
            let url = try packedURL(identityFiles(seed: "6A1F0E2B-0000-4000-8000-000000000000"), in: root)
            let found = BundleHygiene.packedProblems(url, name: "n72ap-7E18.itbase", local: [])
            #expect(found.contains { $0.contains("carries a unit identity") }, "\(found)")
        }
    }

    @Test func packedDeviceNamingALocalPathIsNamed() throws {
        try withScratch { root in
            let url = try packedURL(
                identityFiles(
                    seed: BundleHygiene.placeholderSeed,
                    extra: Data("/Users/someone/Library/Caches/x.ipsw".utf8)
                ),
                in: root
            )
            let found = BundleHygiene.packedProblems(
                url,
                name: "n72ap-7E18.itbase",
                local: [Data("/Users/someone".utf8)]
            )
            #expect(found.contains { $0.contains("names a local path") }, "\(found)")
        }
    }

    @Test func packedDeviceWithAGarbageBodyIsNamed() throws {
        try withScratch { root in
            let url = root.appendingPathComponent("n72ap-7E18.itbase")
            let index = try JSONSerialization.data(withJSONObject: [
                "entries": [["name": "identity.json", "size": 2, "mode": 0o444]]
            ])
            var length = UInt32(index.count).littleEndian
            try (Data("ITPACK01".utf8) + Data(bytes: &length, count: 4) + index + Data("garbage".utf8))
                .write(to: url)
            let found = BundleHygiene.packedProblems(url, name: "n72ap-7E18.itbase", local: [])
            #expect(found.contains { $0.contains("unreadable body") }, "\(found)")
        }
    }

    @Test func isMachODetectsMagic() throws {
        try withScratch { root in
            let magics: [[UInt8]] = [
                [0xcf, 0xfa, 0xed, 0xfe], [0xce, 0xfa, 0xed, 0xfe],
                [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
            ]
            for (i, magic) in magics.enumerated() {
                let url = root.appendingPathComponent("macho\(i)")
                try Data(magic + [0x00, 0x01]).write(to: url)
                #expect(BundleHygiene.isMachO(url), "magic \(i)")
            }
            let elf = root.appendingPathComponent("elf")
            try Data([0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01]).write(to: elf)
            #expect(!BundleHygiene.isMachO(elf))
            let short = root.appendingPathComponent("short")
            try Data([0xcf, 0xfa]).write(to: short)
            #expect(!BundleHygiene.isMachO(short))
        }
    }

    @Test func swiftPackagesReadsIdentities() throws {
        try withScratch { root in
            let resolved = root.appendingPathComponent("Package.resolved")
            try JSONSerialization.data(withJSONObject: [
                "pins": [
                    ["identity": "swift-crypto", "kind": "remoteSourceControl"],
                    ["identity": "swift-system", "kind": "remoteSourceControl"],
                    ["kind": "remoteSourceControl"],
                ],
                "version": 3,
            ]).write(to: resolved)
            #expect(try BundleHygiene.swiftPackages(resolved: [resolved]) == ["swift-crypto", "swift-system"])
        }
    }

    @Test func sha256HexMatchesTheKnownVector() throws {
        #expect(
            sha256Hex(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
#endif
}

#if !os(Windows)
/// zlib's one-shot compressor (the tests' deflate helper).
func deflate(_ data: Data) -> Data {
    var size = compressBound(uLong(data.count))
    var out = [UInt8](repeating: 0, count: Int(size))
    data.withUnsafeBytes {
        _ = compress(&out, &size, $0.bindMemory(to: Bytef.self).baseAddress, uLong(data.count))
    }
    return Data(out.prefix(Int(size)))
}
#endif

