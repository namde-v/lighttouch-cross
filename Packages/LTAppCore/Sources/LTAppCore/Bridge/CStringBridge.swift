/// C string bridging: allocation, validation, thread-local last-error, and
/// debug allocation counters (ui/ABI.md §1.3, §1.4).
///
/// Ownership rule: any `const char*` an `lt_` function hands out is malloc'd
/// here and owned by the caller, freed only via `lt_free_string`. Strings
/// passed *in* are borrowed — Swift copies what it needs before returning.
import Foundation
import LTBridgeC

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

// MARK: - Outgoing strings (Swift -> C, caller-owned)

/// Copies `s` to a malloc'd NUL-terminated UTF-8 buffer. `nil` in → `nil` out.
/// Embedded NULs truncate (Swift strings cannot carry them across this
/// boundary; see the header contract). Never fails for representable input.
func ltCopyCString(_ s: String?) -> UnsafeMutablePointer<CChar>? {
    guard let s else { return nil }
    return s.withCString { src in
        let len = Int(strlen(src))
        guard let dst = malloc(len + 1)?.assumingMemoryBound(to: CChar.self) else { return nil }
        dst.update(from: src, count: len + 1) // copies the NUL too
        LTStringStats.recordAlloc()
        return dst
    }
}

/// Copies raw UTF-8 bytes (already validated) to a malloc'd NUL-terminated buffer.
func ltCopyCString(bytes: UnsafeRawBufferPointer) -> UnsafeMutablePointer<CChar>? {
    guard let dst = malloc(bytes.count + 1)?.assumingMemoryBound(to: CChar.self) else { return nil }
    if bytes.count > 0 {
        dst.update(from: bytes.baseAddress!.assumingMemoryBound(to: CChar.self), count: bytes.count)
    }
    dst[bytes.count] = 0
    LTStringStats.recordAlloc()
    return dst
}

func ltCopyCString(_ data: Data) -> UnsafeMutablePointer<CChar>? {
    data.withUnsafeBytes { ltCopyCString(bytes: $0) }
}

// MARK: - Incoming strings (C -> Swift, borrowed)

/// Validates a borrowed C string: non-null and well-formed UTF-8.
/// Returns nil (and records `what`) when the argument is unusable.
func ltTakeString(_ ptr: UnsafePointer<CChar>?, what: String) -> String? {
    guard let ptr else {
        LTLastError.set("\(what): null pointer")
        return nil
    }
    guard let s = String(validatingUTF8: ptr) else {
        LTLastError.set("\(what): malformed UTF-8")
        return nil
    }
    return s
}

/// Optional-string variant: null → nil (no error recorded).
func ltTakeOptString(_ ptr: UnsafePointer<CChar>?) -> String? {
    guard let ptr else { return nil }
    return String(validatingUTF8: ptr)
}

// MARK: - Thread-local last error (ui/ABI.md §1.4)

/// Per-thread last-error slot. `lt_last_error()` hands the caller a malloc'd
/// copy; the slot keeps its value until the next failure on the same thread.
enum LTLastError {
    private static let key = "lt_last_error"

    static func set(_ message: String) {
        Thread.current.threadDictionary[key] = message
    }

    static func set(_ error: Error) {
        set(String(describing: error))
    }

    /// Copies the stored message into a caller-owned C string, or nil when the
    /// calling thread has no recorded failure.
    static func copyCString() -> UnsafeMutablePointer<CChar>? {
        guard let message = Thread.current.threadDictionary[key] as? String else { return nil }
        return ltCopyCString(message)
    }

    static func clear() {
        Thread.current.threadDictionary.removeObject(forKey: key)
    }
}

// MARK: - Debug allocation counters

/// Debug counters backing leak checks: every malloc in ltCopyCString records
/// an alloc; lt_free_string records a free. Test-only readers live below.
enum LTStringStats {
    private static let lock = NSLock()
    private static var allocs: UInt64 = 0
    private static var frees: UInt64 = 0

    static func recordAlloc() { lock.withLock { allocs &+= 1 } }
    static func recordFree() { lock.withLock { frees &+= 1 } }

    /// (allocs, frees) snapshot for tests.
    static func snapshot() -> (allocs: UInt64, frees: UInt64) {
        lock.withLock { (allocs, frees) }
    }

    static func reset() { lock.withLock { allocs = 0; frees = 0 } }
}

// MARK: - The two deallocators (ui/ABI.md §1.3)

/// Deep-frees exactly the string fields of the event's active union member.
/// After this returns, the event holds no allocated strings.
func ltFreeEventStrings(_ event: inout LTEvent) {
    func free(_ p: UnsafePointer<CChar>?) {
        guard let p else { return }
        free(UnsafeMutableRawPointer(mutating: p))
        LTStringStats.recordFree()
    }
    // Only the active member's strings are valid; free exactly those.
    switch event.kind {
    case kLTEventBootStage:
        free(event.u.bootStage.detail)
    case kLTEventNoticeChanged:
        free(event.u.noticeChanged.message)
        free(event.u.noticeChanged.operation)
    case kLTEventZoomChanged:
        free(event.u.zoomChanged.mode)
    case kLTEventHiddenAppsListed:
        free(event.u.hiddenAppsListed.appsJson)
    case kLTEventInstallProgress:
        free(event.u.installProgress.bundleId)
        free(event.u.installProgress.phase)
    case kLTEventInstallDone:
        free(event.u.installDone.bundleId)
        free(event.u.installDone.message)
    case kLTEventFilesListed:
        free(event.u.filesListed.entriesJson)
    case kLTEventFilesProgress:
        free(event.u.filesProgress.currentFile)
    case kLTEventFilesDone:
        free(event.u.filesDone.message)
    case kLTEventLogLine:
        free(event.u.logLine.source)
        free(event.u.logLine.text)
    case kLTEventLogRotated:
        free(event.u.logRotated.source)
    case kLTEventCaptureDone:
        free(event.u.captureDone.path)
        free(event.u.captureDone.message)
    case kLTEventRecordingSaveNeeded:
        free(event.u.recordingSaveNeeded.suggestedName)
    case kLTEventJobProgress:
        free(event.u.jobProgress.entryId)
        free(event.u.jobProgress.detail)
    case kLTEventJobDone:
        free(event.u.jobDone.entryId)
        free(event.u.jobDone.message)
    case kLTEventToast:
        free(event.u.toast.title)
        free(event.u.toast.body)
        free(event.u.toast.category)
    case kLTEventDropAction:
        free(event.u.dropAction.action)
        free(event.u.dropAction.detailJson)
    default:
        break // no string payload
    }
}
