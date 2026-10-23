#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation
import Testing

@testable import LightTouchCore

/// The state/log layout (the .noindex root and its migration, backups, isolation, a blocked root), the metadata
/// cache's isolation and purge recovery, and the bounded log pipes. Every Library directory is a temporary fixture.
struct StorageLocationsTests {
    let fm = FileManager.default

    #if os(Windows)
    /// flock(LOCK_EX) for tests: a non-blocking exclusive LockFileEx on the
    /// CRT descriptor's HANDLE.
    func lockNB(_ fd: Int32) -> Bool {
        let raw = _get_osfhandle(fd)
        guard raw != -1, let handle = UnsafeMutableRawPointer(bitPattern: raw) else { return false }
        var overlapped = OVERLAPPED()
        return LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY), 0, 1, 0, &overlapped)
    }
    #endif

    func write(_ text: String, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    nonisolated func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    func mode(_ url: URL) throws -> Int {
        try (fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }

    @Test func layoutIsPrivateAndMigratesTheUnsuffixedRoot() throws {
        try withTemporaryDirectory { root in
            let library = root.appendingPathComponent("Library", isDirectory: true)
            let support = library.appendingPathComponent("Application Support", isDirectory: true)
            let destination = support.appendingPathComponent(
                StorageLocations.bundleIdentifier + ".noindex",
                isDirectory: true
            )
            // A root from before the .noindex name moves over whole; while an older build holds its app lock, startup stops.
            let unsuffixed = support.appendingPathComponent(StorageLocations.bundleIdentifier, isDirectory: true)
            try StorageLocations.privateDirectory(unsuffixed)
            try write("pages", unsuffixed.appendingPathComponent("Devices/x/base/0.page"))
            let held = open(unsuffixed.appendingPathComponent(".app-lock").path, O_RDWR | O_CREAT, 0o600)
            #if os(Windows)
            #expect(held >= 0 && lockNB(held))
            #else
            #expect(held >= 0 && flock(held, LOCK_EX) == 0)
            #endif
            #expect(throws: (any Error).self) {
                try StorageLocations.prepare(applicationSupport: support, library: library)
            }
            #expect(!exists(destination) && exists(unsuffixed))
            close(held)
            let layout = try StorageLocations.prepare(applicationSupport: support, library: library)
            #expect(layout.state == destination && exists(destination) && !exists(unsuffixed))
            #expect(try text(destination.appendingPathComponent("Devices/x/base/0.page")) == "pages")
            // Device storage is out of Time Machine (Spotlight: the root's suffix).
            // macOS-only: Linux has no backup-exclusion xattr, so corelibs'
            // setResourceValues is a silent no-op and the read-back is nil.
            #if os(macOS)
            for name in ["Devices", "Preparing"] {
                #expect(
                    try destination.appendingPathComponent(name).resourceValues(forKeys: [.isExcludedFromBackupKey])
                        .isExcludedFromBackup == true
                )
            }
            #endif
            #expect(
                layout.logs.path == library.appendingPathComponent("Logs/" + StorageLocations.bundleIdentifier).path
                    && exists(layout.logs)
            )
            for url in [destination, layout.logs] {
                #if !os(Windows)
                // POSIX permissions have no Windows equivalent (owner-only by
                // default ACL instead).
                #expect(try mode(url) == 0o700)
                #endif
            }
            _ = try StorageLocations.prepare(applicationSupport: support, library: library)  // again: fine

            // An isolated run keeps its state and logs under the override.
            let isolated = root.appendingPathComponent("isolated")
            let isolatedLayout = try StorageLocations.prepare(
                applicationSupport: support,
                library: library,
                override: isolated
            )
            #expect(
                isolatedLayout.state == isolated
                    && isolatedLayout.logs == isolated.appendingPathComponent("Logs", isDirectory: true)
            )
            // A file where the state directory should be stops startup, and stays.
            let blocked = root.appendingPathComponent("blocked")
            try write("keep", blocked)
            #expect(throws: (any Error).self) {
                try StorageLocations.prepare(applicationSupport: support, library: library, override: blocked)
            }
            #expect(try text(blocked) == "keep")
        }
    }

    @Test func metadataCacheIsIsolatedAndRecoversFromAPurge() throws {
        try withTemporaryDirectory { root in
            let state = root.appendingPathComponent("state", isDirectory: true)
            let caches = root.appendingPathComponent("system caches", isDirectory: true)
            try fm.createDirectory(at: caches, withIntermediateDirectories: true)
            let cache = StorageLocations.appMetadataDirectory(state: state, caches: caches, isolated: true)
            #expect(cache == state.appendingPathComponent("Caches/AppMetadata", isDirectory: true) && exists(cache))
            #expect(try fm.contentsOfDirectory(atPath: caches.path).isEmpty, "an isolated run wrote the global cache")
            let normal = StorageLocations.appMetadataDirectory(
                state: root.appendingPathComponent("normal state"),
                caches: caches,
                isolated: false
            )
            #expect(
                normal == caches.appendingPathComponent("gold.samhenri.LightTouchMac/AppMetadata", isDirectory: true)
                    && exists(normal)
            )
            // The index and the icons (AppMetadataCache.save and learn) publish through writeCacheData, which
            // recreates a purged directory without reinitializing.
            let index = normal.appendingPathComponent("index.json")
            var entries = ["com.example.app": "original"]
            try StorageLocations.writeCacheData(JSONEncoder().encode(entries), to: index)
            try fm.removeItem(at: normal)
            entries["com.example.new"] = "after purge"
            try StorageLocations.writeCacheData(JSONEncoder().encode(entries), to: index)
            #expect(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: index)) == entries)
            try fm.removeItem(at: normal)
            let icon = normal.appendingPathComponent("com.example.new.png")
            try StorageLocations.writeCacheData(Data("rebuilt icon".utf8), to: icon)
            #expect(try text(icon) == "rebuilt icon")
            try StorageLocations.writeCacheData(Data("replacement icon".utf8), to: icon)
            #expect(try text(icon) == "replacement icon")
            #expect(try fm.contentsOfDirectory(atPath: normal.path) == ["com.example.new.png"])
        }
    }

    // MARK: - Log pipes

    @Test func processLogCaptureRotatesAtTheLimit() throws {
        try withTemporaryDirectory { logs in
            let url = logs.appendingPathComponent("stream.log")
            let capture = try ProcessLogCapture(url: url)
            let payload = Data(repeating: 65, count: 2_300_000)
            #if os(Windows)
            // FileHandle(fileDescriptor:) must not be used on Windows: its
            // deinit closes the underlying HANDLE even with closeOnDealloc:
            // false, corrupting the pipe teardown and crashing the test binary
            // (0xC000001D in fclose during deinit). Write via the UCRT directly.
            try payload.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var remaining = buffer.count
                var cursor = base
                while remaining > 0 {
                    let written = write(capture.writeDescriptor, cursor, UInt32(remaining))
                    guard written > 0 else { throw StorageLocations.posixError() }
                    cursor = cursor.advanced(by: Int(written))
                    remaining -= Int(written)
                }
            }
            #else
            try FileHandle(fileDescriptor: capture.writeDescriptor, closeOnDealloc: false).write(
                contentsOf: payload
            )
            #endif
            capture.flush()
            for path in [url, url.appendingPathExtension("1")] {
                let data = try Data(contentsOf: path)
                #expect(!data.isEmpty && data.count <= StorageLocations.logLimit && data.allSatisfy { $0 == 65 })
                #if !os(Windows)
                // POSIX permissions have no Windows equivalent (owner-only by
                // default ACL instead).
                #expect(try mode(path) == 0o600)
                #endif
            }
        }
    }

    /// The reader stops after EOF instead of spinning on a closed pipe; flush and finish after it are safe.
    @Test func logPipeReaderEndsAtEOF() async throws {
        try await LibraryFixtures.withScratch { logs in
            var descriptors: [Int32] = [-1, -1]
            #if os(Windows)
            #expect(_pipe(&descriptors, 4096, _O_BINARY | _O_NOINHERIT) == 0)
            #else
            #expect(pipe(&descriptors) == 0)
            #endif
            let url = logs.appendingPathComponent("eof.log")
            let reader = try LogPipeReader(descriptor: descriptors[0], log: RotatingLog(url: url))
            let marker = Data("EOF marker".utf8)
            #if os(Windows)
            // FileHandle(fileDescriptor:) must not be used on Windows (see
            // above): write via the UCRT directly so close(descriptors[1])
            // below stays the single, owning close.
            try marker.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                guard write(descriptors[1], base, UInt32(buffer.count)) == Int32(buffer.count) else {
                    throw StorageLocations.posixError()
                }
            }
            #else
            try FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: false).write(
                contentsOf: marker
            )
            #endif
            close(descriptors[1])
            try await Task.sleep(for: .milliseconds(30))
            reader.flush()
            reader.finish()
            #expect(try text(url) == "EOF marker")
        }
    }

    /// The serial FIFOs: unlinked at app stop while QEMU still holds a writer, whose writes still land; no names left.
    /// FIFO-only: SerialLogCapture isn't supported on Windows.
    #if !os(Windows)
    @Test func serialFIFOsAreRemovedWhileTheWriterLives() throws {
        try withTemporaryDirectory { root in
            let fifoRoot = root.appendingPathComponent("fifo")
            let log = root.appendingPathComponent("fifo.log")
            try StorageLocations.privateDirectory(fifoRoot)
            let serial = try SerialLogCapture(url: log, temporaryRoot: fifoRoot)
            let fifo = String(serial.argument.dropFirst("pipe:".count)) + ".out"
            let first = open(fifo, O_WRONLY)
            #expect(first >= 0)
            try FileHandle(fileDescriptor: first, closeOnDealloc: false).write(contentsOf: Data("guest serial".utf8))
            close(first)
            let active = open(fifo, O_WRONLY)
            #expect(active >= 0)
            serial.removeEndpoints()
            #expect(try fm.contentsOfDirectory(atPath: fifoRoot.path).isEmpty)
            try FileHandle(fileDescriptor: active, closeOnDealloc: false).write(contentsOf: Data(" after unlink".utf8))
            close(active)
            serial.finish()
            #expect(try fm.contentsOfDirectory(atPath: fifoRoot.path).isEmpty)
            #expect(try text(log) == "guest serial after unlink")
        }
    }
    #endif
}
