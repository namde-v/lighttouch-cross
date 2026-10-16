import Foundation
import Testing
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif

@testable import FirmwareKit

/// DiskImage: the argv of both backends on every host; the real operations on each backend this host has
/// (hdiutil everywhere; `diskutil image` on macOS 27+), and that both produce the same grown volume and raw disk.
/// (Editing through a diskutil attach lays files out differently, the solid-state allocation policy: DiskImage.backend.)
@Suite(.serialized, .detachesItsImages) struct DiskImageTests {
    #if os(macOS)
        static func backends() async throws -> [DiskImage.Backend] {
        let hasDiskutilImage = try await DiskImage.exec(["/usr/sbin/diskutil", "image"]).0 == 0
        return [.hdiutil] + (hasDiskutilImage ? [.diskutil] : [])
    }

    @Test func argv() {
        let img = URL(fileURLWithPath: "/tmp/v.img")
        let raw = ["-imagekey", "diskimage-class=CRawDiskImage"]
        #expect(
            DiskImage.attachCommand(img, readOnly: false, mount: false, backend: .hdiutil)
                == ["/usr/bin/hdiutil", "attach", "-plist"] + raw + ["-nomount", "-nobrowse", "/tmp/v.img"]
        )
        #expect(
            DiskImage.attachCommand(img, readOnly: true, mount: true, backend: .hdiutil)
                == ["/usr/bin/hdiutil", "attach", "-plist"] + raw + [
                    "-readonly", "-owners", "off", "-noverify", "-noautoopen", "/tmp/v.img",
                ]
        )
        #expect(
            DiskImage.attachCommand(img, readOnly: false, mount: false, backend: .diskutil)
                == ["/usr/sbin/diskutil", "image", "attach", "--plist", "--noMount", "--nobrowse", "/tmp/v.img"]
        )
        #expect(
            DiskImage.attachCommand(img, readOnly: true, mount: true, backend: .diskutil)
                == [
                    "/usr/sbin/diskutil", "image", "attach", "--plist", "--readOnly", "--mountOptions", "noowners",
                    "/tmp/v.img",
                ]
        )
        #expect(
            DiskImage.detachCommand("/dev/disk9", force: false, backend: .hdiutil) == [
                "/usr/bin/hdiutil", "detach", "/dev/disk9",
            ]
        )
        #expect(
            DiskImage.detachCommand("/dev/disk9", force: true, backend: .hdiutil) == [
                "/usr/bin/hdiutil", "detach", "/dev/disk9", "-force",
            ]
        )
        #expect(
            DiskImage.detachCommand("/dev/disk9", force: false, backend: .diskutil) == [
                "/usr/sbin/diskutil", "eject", "/dev/disk9",
            ]
        )
        #expect(
            DiskImage.detachCommand("/dev/disk9", force: true, backend: .diskutil) == [
                "/usr/sbin/diskutil", "unmountDisk", "force", "/dev/disk9",
            ]
        )
        #expect(
            DiskImage.resizeCommand(img, bytes: 1 << 30, slack: 4096, backend: .hdiutil) == [
                "/usr/bin/hdiutil", "resize", "-sectors", "2097152",
            ] + raw + ["/tmp/v.img"]
        )
        #expect(
            DiskImage.resizeCommand(img, bytes: 1 << 30, slack: 0, backend: .diskutil) == [
                "/usr/sbin/diskutil", "image", "resize", "--size", "1073741824", "/tmp/v.img",
            ]
        )
        #expect(
            DiskImage.resizeCommand(img, bytes: 1 << 30, slack: 4096, backend: .diskutil) == [
                "/usr/sbin/diskutil", "image", "resize", "--size", "1073737728", "/tmp/v.img",
            ]
        )
        let dmg = URL(fileURLWithPath: "/tmp/a.dmg")
        let out = URL(fileURLWithPath: "/tmp/w/raw")
        #expect(
            DiskImage.convertCommand(dmg, raw: out, backend: .hdiutil) == [
                "/usr/bin/hdiutil", "convert", "/tmp/a.dmg", "-format", "UDTO", "-quiet", "-o", "/tmp/w/raw",
            ]
        )
        #expect(
            DiskImage.convertCommand(dmg, raw: out, backend: .diskutil) == [
                "/usr/sbin/diskutil", "image", "create", "from", "--format", "RAW", "/tmp/a.dmg", "/tmp/w/raw.raw",
            ]
        )
    }

    /// Both tools' attach plists: dev-entry with or without /dev/, the whole disk chosen, the mount point if any.
    @Test func attachPlist() {
        let diskutil = """
            <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>system-entities</key><array>
            <dict><key>dev-entry</key><string>disk6</string><key>filesystem-type</key><string>hfs</string></dict>
            </array></dict></plist>
            """
        #expect(DiskImage.parseAttach(diskutil) == .init(device: "/dev/disk6", mountPoint: nil))
        let hdiutil = """
            <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>system-entities</key><array>
            <dict><key>dev-entry</key><string>/dev/disk8s2</string><key>mount-point</key><string>/Volumes/Data</string></dict>
            <dict><key>dev-entry</key><string>/dev/disk8</string></dict>
            </array></dict></plist>
            """
        #expect(
            DiskImage.parseAttach("noise before\n" + hdiutil)
                == .init(device: "/dev/disk8", mountPoint: "/Volumes/Data")
        )
        #expect(DiskImage.parseAttach("not a plist") == nil)
    }

    /// Each backend this host has: attach/detach a raw volume (listed while attached, gone after), grow it, and the
    /// grown volumes of both backends are byte-identical, for 4 KiB and 8 KiB allocation blocks (iOS's two sizes)
    /// with 0, 4 and 8 KiB of file slack past the volume (the iPad IPSW volumes carry 4 KiB; hdiutil then stops a
    /// block short).
    ///
    /// macOS-only: needs hdiutil/diskutil, newfs_hfs and fsck_hfs. The Linux losetup backend's pure argv/parse
    /// functions are covered by `argv`, `attachPlist` and `linuxBackend` below; its live attach path needs root
    /// and is not exercised here (see SHIM_NOTES.md).
    @Test(arguments: [(4096, 0), (8192, 0), (8192, 4096), (4096, 4096), (8192, 8192)]) func backendsAgree(
        blockSize: Int,
        slack: Int
    ) async throws {
        try await Oracle.withTemp { dir in
            let base = dir.appendingPathComponent("base.img")
            #expect(
                FileManager.default.createFile(atPath: base.path, contents: nil) && truncate(base.path, 32 << 20) == 0
            )
            let dev0 = try await DiskImage.attach(base)
            try await DiskImage.run(["/sbin/newfs_hfs", "-s", "-J", "-b", String(blockSize), "-v", "Data", dev0.device])
            try await DiskImage.detach(dev0.device)
            #expect(truncate(base.path, off_t((32 << 20) + slack)) == 0)
            var grown: [DiskImage.Backend: Data] = [:]
            for b in try await Self.backends() {
                let img = dir.appendingPathComponent("\(b.rawValue).img")
                try FileManager.default.copyItem(at: base, to: img)
                let a = try await DiskImage.attach(img, backend: b)
                #expect(a.device.hasPrefix("/dev/disk") && a.mountPoint == nil, "\(b)")
                // A loaded host lists a just-attached image in `hdiutil info` a moment later (seen under parallel builds).
                #expect(
                    try await Self.eventually {
                        try await DiskImage.attachedImages().contains { $0.image == img.path && $0.device == a.device }
                    },
                    "\(b): listed while attached"
                )
                try await DiskImage.detach(a.device, backend: b)
                #expect(
                    !(try await DiskImage.attachedImages()).contains { $0.image == img.path },
                    "\(b): gone after detach"
                )
                // resize, then the pad + alternate header move
                try await VolumeMount.grow(img, toBytes: 64 << 20, backend: b)
                let v = try HFSPlusVolume(img)
                #expect(
                    v.blockSize == blockSize && v.totalBlocks == ((64 << 20) - slack % blockSize) / blockSize,
                    "\(b): \(v.totalBlocks) x \(v.blockSize)"
                )
                let dev = try await DiskImage.attach(img, backend: b).device
                let fsck = try await VolumeMount.check(dev)
                try await DiskImage.detach(dev, backend: b)
                #expect(fsck.ok, "\(b): \(fsck.output.suffix(300))")
                grown[b] = try Data(contentsOf: img)
            }
            if let h = grown[.hdiutil], let d = grown[.diskutil] {
                #expect(
                    h == d,
                    "hdiutil and diskutil image resize differ: first byte \(zip(h, d).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1)"
                )
            }
        }
    }

    #endif

    /// True once `condition` holds, polling for up to five seconds.
    static func eventually(_ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<50 {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try await condition()
    }

    /// detachAll(under:) takes the images whose files are under the root (a killed preparer's) and no others.
    /// macOS-only: needs hdiutil (see backendsAgree).
    #if os(macOS)
        @Test func detachAllUnderRoot() async throws {
        try await Oracle.withTemp { dir in
            let inside = dir.appendingPathComponent("Preparing/job")
            let outside = dir.appendingPathComponent("kept")
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let (a, b) = (inside.appendingPathComponent("a.img"), outside.appendingPathComponent("b.img"))
            for img in [a, b] {
                #expect(
                    FileManager.default.createFile(atPath: img.path, contents: nil) && truncate(img.path, 1 << 20) == 0
                )
            }
            _ = try await DiskImage.attach(a)
            let kept = try await DiskImage.attach(b)
            try await DiskImage.detachAll(under: dir.appendingPathComponent("Preparing"))
            // One hdiutil info read can leave an attached image out while others attach or detach: b is polled for.
            let attached = try await DiskImage.attachedImages().map(\.image)
            let keptSeen = try await Self.eventually {
                try await DiskImage.attachedImages().contains { $0.image == b.path }
            }
            try await DiskImage.detach(kept.device)
            #expect(!attached.contains(a.path) && keptSeen, "\(attached)")
        }
    }
    #endif

    /// Each backend converts a UDIF (zlib) image to the same raw disk.
    /// macOS-only: needs hdiutil (see backendsAgree); the Linux dmg2img path is unwired here.
    #if os(macOS)
        @Test func convertToRaw() async throws {
        try await Oracle.withTemp { dir in
            let src = dir.appendingPathComponent("src")
            let dmg = dir.appendingPathComponent("a.dmg")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try Data("hello\n".utf8).write(to: src.appendingPathComponent("f"))
            try await DiskImage.run([
                "/usr/bin/hdiutil", "create", "-quiet", "-format", "UDZO", "-fs", "HFS+", "-layout", "SPUD",
                "-srcfolder", src.path, "-o", dmg.path,
            ])
            var raws: [Data] = []
            for b in try await Self.backends() {
                let out = dir.appendingPathComponent("\(b.rawValue).raw")
                try await DiskImage.convertToRaw(dmg, to: out, backend: b)
                raws.append(try Data(contentsOf: out))
                #expect(
                    raws.last!.count > 0 && (try? APM.hfsSlice(raws.last!.prefix(64 * 512))) != nil,
                    "\(b): an Apple partition map with an HFS slice"
                )
            }
            if raws.count == 2 {
                let (o1, o2) = (try APM.hfsSlice(raws[0].prefix(64 * 512)), try APM.hfsSlice(raws[1].prefix(64 * 512)))
                #expect(
                    o1 == o2
                        && raws[0][o1.offset..<o1.offset + o1.length] == raws[1][o2.offset..<o2.offset + o2.length],
                    "the backends' HFS slices differ (\(raws[0].count) vs \(raws[1].count) bytes, first difference at \(zip(raws[0], raws[1]).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1))"
                )
            }
        }
    }
    #endif

    /// The Linux backend's pure functions: losetup argv, /dev/loopN parse, losetup --json parse.
    @Test func linuxBackend() throws {
        let img = URL(fileURLWithPath: "/tmp/v.img")
        #expect(
            DiskImage.attachCommand(img, readOnly: false, mount: false, backend: .linux)
                == ["/sbin/losetup", "--find", "--show", "/tmp/v.img"]
        )
        #expect(
            DiskImage.attachCommand(img, readOnly: true, mount: true, backend: .linux)
                == ["/sbin/losetup", "--find", "--show", "--read-only", "/tmp/v.img"]
        )
        #expect(
            DiskImage.detachCommand("/dev/loop3", force: false, backend: .linux)
                == ["/sbin/losetup", "--detach", "/dev/loop3"]
        )
        #expect(
            DiskImage.detachCommand("/dev/loop3", force: true, backend: .linux)
                == ["/sbin/losetup", "--detach", "/dev/loop3"]
        )
        #expect(
            DiskImage.resizeCommand(img, bytes: 1 << 30, slack: 0, backend: .linux)
                == ["/usr/bin/truncate", "--size", "1073741824", "/tmp/v.img"]
        )
        #expect(
            DiskImage.convertCommand(img, raw: URL(fileURLWithPath: "/tmp/w/raw"), backend: .linux)
                == ["/usr/bin/dmg2img", "/tmp/v.img", "/tmp/w/raw"]
        )
        #expect(DiskImage.parseAttach("/dev/loop7\n", backend: .linux) == .init(device: "/dev/loop7", mountPoint: nil))
        #expect(DiskImage.parseAttach("  /dev/loop0  \n", backend: .linux)?.device == "/dev/loop0")
        #expect(DiskImage.parseAttach("not a device\n", backend: .linux) == nil)
        #expect(DiskImage.parseAttach("", backend: .linux) == nil)
        let listing = """
            {"loopdevices": [
               {"name": "/dev/loop0", "back-file": "/tmp/a.img", "autoclear": false},
               {"name": "/dev/loop1", "back-file": null},
               {"name": "/dev/loop2"}
            ]}
            """
        let parsed = try DiskImage.parseLinuxAttachments(listing)
        #expect(parsed.count == 1 && parsed[0].image == "/tmp/a.img" && parsed[0].device == "/dev/loop0")
        #expect(try DiskImage.parseLinuxAttachments("{\"loopdevices\": []}").isEmpty)
        #expect(throws: FirmwareError.self) { try DiskImage.parseLinuxAttachments("not json") }
    }
}
