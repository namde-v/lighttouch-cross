#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation
import Testing

@testable import FirmwareKit

struct FirmwareCacheTests {
    @Test func pruningCannotDeleteActiveReadersOrReplaceLockInode() throws {
        let root = try Fixtures.tempDir("cache-lease")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("result")
        try Data("cached".utf8).write(to: file)
        func reader() throws {
            let lease = try FirmwareCache.consume(root: root)
            defer { withExtendedLifetime(lease) {} }
            #expect(throws: FirmwareError.self) { try FirmwareCache.prune(root: root) }
            #expect(try Data(contentsOf: file) == Data("cached".utf8))
        }
        try reader()
        #if os(Windows)
        // No lstat(2)/st_ino on Windows: the lease file surviving prune (not replaced) is the assertion.
        let lease = root.appendingPathComponent(".lease").path
        #expect(FileManager.default.fileExists(atPath: lease))
        try FirmwareCache.prune(root: root)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: lease))
        #else
        var before = stat()
        var after = stat()
        #expect(lstat(root.appendingPathComponent(".lease").path, &before) == 0)
        try FirmwareCache.prune(root: root)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(lstat(root.appendingPathComponent(".lease").path, &after) == 0)
        #expect(before.st_ino == after.st_ino)
        #endif
    }
}
