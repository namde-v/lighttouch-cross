import Foundation

/// A fresh directory under the temporary directory, removed after `body`.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ltm-tests-" + UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

/// A path for one file in a fresh temporary directory.
func withTemporaryFile<T>(named name: String = "file", _ body: (URL) throws -> T) throws -> T {
    try withTemporaryDirectory { try body($0.appendingPathComponent(name)) }
}

/// Recursive copy that doesn't preserve ownership: FileManager.copyItem on a
/// directory tries to chown, which fails with EPERM in containers where the
/// TMPDIR's setgid bit gives files an unmapped group.
func copyTree(_ source: URL, to destination: URL) throws {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
    }
    if isDirectory.boolValue {
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            try copyTree(source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
        }
    } else {
        try fm.copyItem(at: source, to: destination)
    }
}
