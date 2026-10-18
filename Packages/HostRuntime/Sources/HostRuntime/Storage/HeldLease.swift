#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation
import Synchronization

#if os(Windows)
/// strerror() is deprecated in the UCRT (unsafe); strerror_s is the conformant spelling.
private func errnoDescription(_ code: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    _ = strerror_s(&buffer, buffer.count, code)
    return String(cString: buffer)
}
#else
private func errnoDescription(_ code: Int32) -> String { String(cString: strerror(code)) }
#endif

/// A device helper's hold on its storage lease (Devices/<uuid>/work/lease): taken at hello, kept until the process
/// exits, so a second helper on the same storage — from another Light Touch, or beside one still finishing its
/// shutdown — is refused before it boots. Taken on the link's queue, read on the boot path.
public nonisolated final class HeldLease: Sendable {
    private let held = Mutex<StorageLease?>(nil)
    public init() {}

    public var lease: StorageLease? { held.withLock { $0 } }

    /// True when there is no lease to take (`path` nil) or it was taken; a refusal keeps nothing and says why.
    public func take(_ path: String?, log: (String) -> Void) -> Bool {
        guard let path else { return true }
        do {
            let lease = try StorageLease(URL(fileURLWithPath: path))
            held.withLock { $0 = lease }
            return true
        } catch let error as StorageLease.Failure {
            switch error {
            case .openFailed(let code): log("lease \(path): \(errnoDescription(code))")
            case .inUse: log("lease \(path) is held")
            case .pendingEdit:
                log(
                    "unfinished storage edit \(URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("edit.json").path); resolve it before booting"
                )
            }
        } catch { log("lease \(path): \(error.localizedDescription)") }
        return false
    }

    /// Give the lease up (tests; a helper keeps it until it exits).
    public func release() {
        held.withLock {
            $0?.close()
            $0 = nil
        }
    }
}
