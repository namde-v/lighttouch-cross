import Foundation
#if os(Linux)
import Glibc
#endif
import Testing

@testable import LightTouchCore

/// A published base is immutable until the app deletes it; a running device's files are watched, and only what the
/// guest owns: the app's own boot-time writes under Devices/<uuid> fire nothing.
struct DeviceFilesTests {
    nonisolated final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func add(_ path: String) { lock.withLock { seen.append(path) } }
        var paths: [String] { lock.withLock { seen } }
    }

    @Test func aLockedBaseRefusesChangesUntilRemoveTree() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ltm-device-files-\(UUID().uuidString)")
        defer { try? DeviceStateStorage.removeTree(work) }
        let base = work.appendingPathComponent("base")
        let page = base.appendingPathComponent("nand/cs0/page0")
        try fm.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("page".utf8).write(to: page)
        try Data("boot".utf8).write(to: base.appendingPathComponent("iBoot.bin"))
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: page.path)
        for dir in ["nand/cs0", "nand", ""] {
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: base.appendingPathComponent(dir).path)
        }
        DeviceStateStorage.lockBase(base)
        DeviceStateStorage.lockBase(base)  // idempotent
        // A locked base is finished (the base is locked last): another call doesn't walk the tree, which is what
        // every launch's sweep does. A directory unlocked behind its back stays unlocked.
        let nand = base.appendingPathComponent("nand")
        #if os(Linux)
        // Unlock behind its back: clear the immutable bit (or restore write
        // bits where the immutable flag can't actually be set here).
        let immutableSupported = DeviceStateStorage.immutableSettable()
        if immutableSupported {
            _ = DeviceStateStorage.setImmutable(nand.path, false)
        } else {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nand.path)
        }
        DeviceStateStorage.lockBase(base)
        let nandStillUnlocked: Bool
        if let immutable = DeviceStateStorage.isImmutable(nand.path) {
            nandStillUnlocked = !immutable
        } else {
            let permissions = try? fm.attributesOfItem(atPath: nand.path)[.posixPermissions] as? Int
            nandStillUnlocked = permissions.map { $0 & 0o222 != 0 } ?? false
        }
        #expect(nandStillUnlocked, "lockBase walked a locked base")
        if immutableSupported {
            _ = DeviceStateStorage.setImmutable(nand.path, true)
        } else {
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: nand.path)
        }
        #else
        chflags(nand.path, 0)
        DeviceStateStorage.lockBase(base)
        var info = stat()
        #expect(
            lstat(nand.path, &info) == 0 && info.st_flags & UInt32(UF_IMMUTABLE) == 0,
            "lockBase walked a locked base"
        )
        chflags(nand.path, UInt32(UF_IMMUTABLE))
        #endif
        // The immutable bit refuses even root; permission bits only refuse
        // non-root. (Where the file system has no immutable flag and the tests
        // run as root, nothing can refuse the change, so there is nothing to check.)
        #if os(Linux)
        let enforcementHolds =
            DeviceStateStorage.immutableSettable() || geteuid() != 0
        #else
        let enforcementHolds = true
        #endif
        if enforcementHolds {
            #expect(throws: (any Error).self, "unlink a page") { try fm.removeItem(at: page) }
            #if !os(Linux)
            // On Linux the immutable flag guards a directory's contents, not the
            // directory's own name (renaming it is the parent's writability); on
            // BSD uchg stops the rename too.
            #expect(throws: (any Error).self, "rename the base") {
                try fm.moveItem(at: base, to: work.appendingPathComponent("moved"))
            }
            #endif
            #expect(throws: (any Error).self, "add to the base") {
                try Data().write(to: base.appendingPathComponent("stray"))
            }
            #expect(throws: (any Error).self, "unlink iBoot") {
                try fm.removeItem(at: base.appendingPathComponent("iBoot.bin"))
            }
        }
        #expect(try Data(contentsOf: page) == Data("page".utf8), "a locked base still reads")
        try DeviceStateStorage.removeTree(base)
        #expect(!fm.fileExists(atPath: base.path), "removeTree unlocks and removes the base")
    }

    @Test func theWatchReportsUnlinksAndRenamesOnceEach() async throws {
        try await withScratchDirectory { work in
            let fm = FileManager.default
            let overlay = work.appendingPathComponent("overlay")
            try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
            for name in ["nor.bin", "bus0-ce0.pages"] {
                try Data(name.utf8).write(to: overlay.appendingPathComponent(name))
            }
            let seen = Seen()
            let watch = DeviceFileWatch(directories: [overlay], base: nil) { seen.add($0) }
            #expect(watch.count == 3)
            try fm.removeItem(at: overlay.appendingPathComponent("nor.bin"))
            await eventually("the unlink") { !seen.paths.isEmpty }
            try await Task.sleep(for: .milliseconds(100))  // and only once
            #expect(seen.paths == [overlay.appendingPathComponent("nor.bin").path])
            try fm.moveItem(
                at: overlay.appendingPathComponent("bus0-ce0.pages"),
                to: overlay.appendingPathComponent("elsewhere")
            )
            await eventually("the rename") { seen.paths.count >= 2 }
            try await Task.sleep(for: .milliseconds(100))
            #expect(seen.paths.count == 2 && seen.paths.last?.hasSuffix("bus0-ce0.pages") == true, "\(seen.paths)")
            try fm.moveItem(at: overlay, to: work.appendingPathComponent("overlay-moved"))
            await eventually("the directory's rename") { seen.paths.contains(overlay.path) }
            #expect(seen.paths.contains(overlay.path), "\(seen.paths)")
            withExtendedLifetime(watch) {}
            #expect(
                DeviceFileWatch.notice(shortName: "iPad")
                    == "Files of this iPad were changed while it was running. Shut it down and start it again; unsaved changes may be lost."
            )
        }
    }

    @Test func theAppsOwnWritesAreSilentAndAnOutsideUnlinkIsNot() async throws {
        try await withScratchDirectory { work in
            let fm = FileManager.default
            let device = work.appendingPathComponent("Devices/\(UUID().uuidString)")
            let overlay = device.appendingPathComponent("overlay")
            let base = work.appendingPathComponent("Prepared/base")
            let deviceWork = device.appendingPathComponent("work")
            let nor = device.appendingPathComponent("nor.bin")
            for dir in [overlay, base, deviceWork, device.appendingPathComponent("IPAs")] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            for name in ["bus0-ce0.pages", "bus0-ce1.pages"] {
                try Data(name.utf8).write(to: overlay.appendingPathComponent(name))
            }
            try Data("nor".utf8).write(to: nor)
            try Data("{}".utf8).write(to: device.appendingPathComponent("device.plist"))
            let seen = Seen()
            // As EmulatorController wires it: overlay/, a NOR outside the overlay, the base.
            let watch = DeviceFileWatch(directories: [overlay], files: [nor], base: base) { seen.add($0) }
            #expect(watch.count == 5)
            // A boot's writes: the guest offer, the record, proxy routing, preferences and CA, usbmuxd conf, logs, an IPA; each atomic.
            try fm.createDirectory(
                at: deviceWork.appendingPathComponent("guest-offer"),
                withIntermediateDirectories: true
            )
            try Data("ltpkg".utf8).write(
                to: deviceWork.appendingPathComponent("guest-offer/offer.txt"),
                options: .atomic
            )
            for _ in 0..<3 {
                try Data("guest".utf8).write(to: device.appendingPathComponent("device.plist"), options: .atomic)
            }
            for name in [
                "web-proxy.conf", "web-proxy.plist", "web-proxy.conf.ca.der", "web-proxy.conf.ca.pem", "usbmuxd-conf",
                "usbmuxd.log",
            ] {
                try Data(name.utf8).write(to: device.appendingPathComponent(name), options: .atomic)
            }
            try Data("ipa".utf8).write(to: device.appendingPathComponent("IPAs/com.example.ipa"), options: .atomic)
            try fm.removeItem(at: device.appendingPathComponent("web-proxy.conf.ca.pem"))
            try fm.removeItem(at: deviceWork.appendingPathComponent("guest-offer"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(seen.paths.isEmpty, "the app's own writes fired: \(seen.paths)")
            try fm.removeItem(at: overlay.appendingPathComponent("bus0-ce0.pages"))
            await eventually("the outside unlink") { !seen.paths.isEmpty }
            try await Task.sleep(for: .milliseconds(100))
            #expect(seen.paths == [overlay.appendingPathComponent("bus0-ce0.pages").path])
            withExtendedLifetime(watch) {}
        }
    }
}
