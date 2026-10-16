// Linux shims for the Darwin-only libc calls the tests use directly. The call sites stay identical to
// upstream; only these spellings change.

#if os(Linux)
    import Foundation
    import Glibc

    @testable import FirmwareKit

    /// clonefile(2) is Darwin-only; the tests only need its copy semantics.
    func clonefile(_ src: UnsafePointer<CChar>?, _ dst: UnsafePointer<CChar>?, _ flags: UInt32) -> Int32 {
        guard let src, let dst else { return -1 }
        let fm = FileManager.default
        do {
            let s = String(cString: src), d = String(cString: dst)
            if fm.fileExists(atPath: d) { try fm.removeItem(atPath: d) }
            try fm.copyItem(atPath: s, toPath: d)
            return 0
        } catch {
            return -1
        }
    }

    /// setxattr(2) via the l* nofollow variant. sys/xattr.h is not in Swift's Glibc overlay; the lsetxattr
    /// spelling is declared in FirmwareKit's StoppedVolumeEdit.swift (visible here via @testable import).
    /// The tests pass position 0 / options 0, which Linux folds into flags.
    func setxattr(
        _ path: UnsafePointer<CChar>?, _ name: UnsafePointer<CChar>?, _ value: UnsafeRawPointer?, _ size: Int,
        _ position: UInt32, _ options: Int32
    ) -> Int32 {
        lsetxattr(path, name, value, size, 0)
    }
#endif
