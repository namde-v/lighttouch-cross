import Foundation
import Testing

@testable import BuildTools

struct VendorTests {
    func scratch() throws -> URL {
        let dir = files.temporaryDirectory.appendingPathComponent("vendor-tests-\(UUID().uuidString)")
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func touch(_ file: URL) throws {
        try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
    }

    /// Finder's .DS_Store in a tree (work/, a package checkout, the patches) is neither walked nor listed, so the
    /// license copy over the Swift checkouts no longer opens one as a package directory.
    @Test func finderLitterIsIgnored() throws {
        let dir = try scratch()
        defer { remove(dir) }
        for name in [".DS_Store", "a/.DS_Store", "a/LICENSE", "b/c.txt"] { try touch(dir.appendingPathComponent(name)) }
        #expect(walk(dir) == ["a/LICENSE", "b/c.txt"])
        #expect(try entries(dir).map(\.lastPathComponent) == ["a", "b"])
        #expect(try entries(dir.appendingPathComponent("a")).map(\.lastPathComponent) == ["LICENSE"])
    }

    /// An interrupted static build (libcrypto.a there, no static-build.json yet) is rebuilt; a finished one is not.
    @Test func staticRootNeedsItsRecord() throws {
        let dir = try scratch()
        defer { remove(dir) }
        try touch(dir.appendingPathComponent("prefix/lib/libcrypto.a"))
        #expect(!Vendor.staticComplete(dir))
        try writeJSON(["arch": "arm64"], to: dir.appendingPathComponent("static-build.json"))
        #expect(Vendor.staticComplete(dir))
    }

    /// A second holder of the vendor lock waits (and says so) until the first lets go.
    @Test func secondRunWaitsForTheLock() async throws {
        let dir = try scratch()
        defer { remove(dir) }
        let first = try Vendor.lock(dir) {}
        let second = Task.detached {
            var waited = false
            let fd = try Vendor.lock(dir) { waited = true }
            close(fd)
            return (waited, Date())
        }
        try await Task.sleep(for: .milliseconds(300))
        let released = Date()
        close(first)
        let (waited, acquired) = try await second.value
        #expect(waited && acquired >= released)
    }
}
