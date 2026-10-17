import Foundation

/// Shared helpers for the Library and Storage tests: the checkout's files, child processes and fake tools.
nonisolated enum LibraryFixtures {
    /// The repository checkout this test file is in.
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var shippedCatalog: URL { repo.appendingPathComponent("LightTouchMac/Resources/firmware-catalog.json") }
    static var fakeFirmwarekit: URL { repo.appendingPathComponent("tests/fixtures/fake-firmwarekit") }

    /// Points the app's state and log roots (Bundled, which logEvent's app.log goes through) at a temporary
    /// directory before anything in this process reads them, so code under test that logs never writes the real
    /// library. Call first in any test whose code logs.
    static let isolatedAppState: URL = {
        // Tests/TestIsolation sets LTM_STATE_DIR to a private directory before any test runs.
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["LTM_STATE_DIR"]!, isDirectory: true)
    }()

    /// An IPSW-shaped zip holding only a Restore.plist with this ProductType and build.
    static func restoreZip(_ url: URL, product: String, build: String) throws {
        let folder = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".d")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plist = folder.appendingPathComponent("Restore.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["ProductType": product, "ProductBuildVersion": build],
            format: .xml,
            options: 0
        ).write(to: plist)
        try run("/usr/bin/zip", ["-q", "-j", url.path, plist.path])
    }

    static func randomData(_ count: Int) -> Data {
        // Fast: seed a xorshift PRNG once from the system RNG, then fill in
        // 8-byte chunks. Byte-by-byte SystemRandomNumberGenerator (a getrandom
        // syscall per byte on Linux) takes 30s+ for the 160MB buffer and hogs
        // the MainActor under batch load, stalling every other test's timeouts.
        var data = Data(count: count)
        data.withUnsafeMutableBytes { ptr in
            var rng = SystemRandomNumberGenerator()
            var state = rng.next() | 0x9E3779B97F4A7C15  // non-zero seed
            func next() -> UInt64 {
                // xorshift64*
                state ^= state >> 12
                state ^= state << 25
                state ^= state >> 27
                return state &* 0x2545F4914F6CDD1D
            }
            let words = ptr.bindMemory(to: UInt64.self)
            for i in 0..<words.count { words[i] = next() }
            let remainderStart = words.count * 8
            if remainderStart < count {
                var last = next()
                for i in remainderStart..<count {
                    ptr[i] = UInt8(truncatingIfNeeded: last)
                    last >>= 8
                }
            }
        }
        return data
    }

    /// Runs `executable` to its exit; returns its stdout. Throws on a non-zero status.
    ///
    /// NOTE (Linux): stdout is captured to a temporary file, not a Pipe.
    /// swift-corelibs-foundation's Process.run() calls closeFile() — which is
    /// `try! close()` — on Pipe stdio after spawning, and a spurious EBADF there
    /// fatals the entire test runner (intermittent on Linux CI:
    /// `Fatal error: 'try!' ... "Bad file descriptor"` at FileHandle.swift:740).
    /// That fatal cannot be caught. Plain file handles are never closed by run(),
    /// so this path avoids the landmine entirely.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> String
    {
        let process = Process()
        let stdoutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltm-run-\(UUID().uuidString).out")
        try Data().write(to: stdoutURL)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        defer {
            try? stdoutHandle.close()
            try? FileManager.default.removeItem(at: stdoutURL)
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        process.standardOutput = stdoutHandle
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(
                .executableLoad,
                userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments) exited \(process.terminationStatus)"]
            )
        }
        // The child wrote directly to the file via its dup2'ed stdout; it has exited,
        // so all output is on disk. Read via a fresh descriptor — our handle is only
        // closed by the defer above.
        let data = (try? Data(contentsOf: stdoutURL)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// An executable shell script at `url`.
    static func script(_ url: URL, _ body: String) throws -> URL {
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The fake preparer (tests/fixtures/fake-firmwarekit) in `mode`, writing its argv to `argv`, as its own
    /// executable: the mode and argv path travel in the script, not this process's shared environment.
    static func fakePreparer(in directory: URL, mode: String = "ok", argv: URL? = nil, unwrap: URL? = nil) throws -> URL
    {
        let name = "preparer-\(mode)-\(UUID().uuidString.prefix(8))"
        var body = ""
        if let unwrap { body += "[ \"$1\" = unwrap ] && exec '\(unwrap.path)' \"$@\"\n" }
        body += "FAKE_MODE=\(mode) FAKE_ARGV='\(argv?.path ?? "")' exec '\(fakeFirmwarekit.path)' \"$@\"\n"
        return try script(directory.appendingPathComponent(name), body)
    }

    /// Removes a tree a preparer made read-only or immutable.
    static func forceRemove(_ url: URL) {
        #if !os(Linux)
        // chflags(1) is BSD/macOS-only; on Linux the immutable flag isn't
        // used by the fixtures, and spawning a nonexistent /usr/bin/chflags
        // crashes corelibs-foundation's Process.run instead of throwing.
        _ = try? run("/usr/bin/chflags", ["-R", "nouchg", url.path])
        #endif
        // u+w in-process: spawning /bin/chmod with stderr on
        // FileHandle.nullDevice fatals on Linux (nullDevice wraps fd -1;
        // Process.run() synchronizes the handle -> fsync(-1) -> EBADF ->
        // try! in synchronizeFile() traps -> SIGILL kills the test runner).
        makeWritable(url)
        try? FileManager.default.removeItem(at: url)
    }

    /// Recursively ORs owner-write into every entry's posixPermissions,
    /// in-process (equivalent of `chmod -R u+w`, without spawning).
    private static func makeWritable(_ url: URL) {
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in enumerator {
                let current =
                    (try? fm.attributesOfItem(atPath: item.path)[.posixPermissions] as? Int) ?? 0o644
                try? fm.setAttributes(
                    [.posixPermissions: current | 0o200], ofItemAtPath: item.path)
            }
        }
        let current =
            (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o755
        try? fm.setAttributes([.posixPermissions: current | 0o200], ofItemAtPath: url.path)
    }

    /// Like withTemporaryDirectory, for trees with read-only or locked parts.
    static func withScratch<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ltm-tests-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { forceRemove(directory) }
        return try await body(directory.resolvingSymlinksInPath())
    }
}
