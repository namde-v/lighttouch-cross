// LogExports.swift — ABI.md §3.9: log & console.
//
// Fronts LogTail. Log following is managed here (the portable app core owns
// the subscription set); appended lines post kLTEventLogLine.

import Foundation
import LTBridgeC
import LightTouchCore

// MARK: - Log following (portable addition; the Mac app's UI owned this)

/// Active log subscriptions: source -> polling task.
private final class LogFollowers: @unchecked Sendable {
    static let shared = LogFollowers()
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]

    func follow(_ source: String) {
        lock.withLock {
            guard tasks[source] == nil else { return }
            tasks[source] = Task { [weak self] in
                await self?.poll(source: source)
            }
        }
    }

    func unfollow(_ source: String) {
        lock.withLock {
            tasks[source]?.cancel()
            tasks[source] = nil
        }
    }

    private func poll(source: String) async {
        guard let url = LogSources.url(for: source) else { return }
        var offset: UInt64 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        while !Task.isCancelled {
            let (text, rotated) = LogTail.read(url, from: offset)
            if rotated {
                EventPump.shared.post(kind: kLTEventLogRotated) { e in
                    e.u.logRotated.source = ltCopyCString(source)
                }
                offset = 0
            } else if !text.isEmpty {
                offset += UInt64(text.utf8.count)
                let lines = text
                let lineOffset = offset - UInt64(text.utf8.count)
                EventPump.shared.post(kind: kLTEventLogLine) { e in
                    e.u.logLine.source = ltCopyCString(source)
                    e.u.logLine.text = ltCopyCString(lines)
                    e.u.logLine.offset = lineOffset
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

/// Maps log source names to URLs.
private enum LogSources {
    static func url(for source: String) -> URL? {
        if source == "app" {
            return AppCore.shared?.directories.logDir.appendingPathComponent("app.log")
        }
        if source.hasPrefix("helper:") {
            let id = String(source.dropFirst("helper:".count))
            return AppCore.shared?.directories.logDir.appendingPathComponent("helper-\(id).log")
        }
        return nil
    }

    static func available() -> [String] {
        var sources = ["app"]
        if let core = AppCore.shared {
            for session in core.allSessions() {
                sources.append("helper:\(session.instance.id.uuidString.lowercased())")
            }
        }
        return sources
    }
}

// MARK: - Exports

@_cdecl("lt_log_sources")
public func lt_log_sources(_ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> LTResult {
    guard let out else { return kLTBadArgument }
    guard let json = ltEncodeJSON(LogSources.available()) else { return kLTFailed }
    out.pointee = ltCopyCString(json).map { UnsafePointer($0) }
    return kLTOk
}

@_cdecl("lt_log_read")
public func lt_log_read(
    _ source: UnsafePointer<CChar>?,
    _ from: UInt64,
    _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    guard let source, let out else { return kLTBadArgument }
    let name = String(cString: source)
    guard let url = LogSources.url(for: name) else {
        LTLastError.set("lt_log_read: unknown source '\(name)'")
        return kLTBadArgument
    }
    let (text, rotated) = LogTail.read(url, from: from)
    struct LogReadDTO: Codable {
        var text: String
        var rotated: Bool
        var offset: UInt64
    }
    // Offset advances by the bytes read (whole lines per LogTail's contract).
    let dto = LogReadDTO(text: text, rotated: rotated, offset: from + UInt64(text.utf8.count))
    guard let json = ltEncodeJSON(dto) else { return kLTFailed }
    out.pointee = ltCopyCString(json)
    return kLTOk
}

@_cdecl("lt_log_follow")
public func lt_log_follow(_ source: UnsafePointer<CChar>?, _ follow: Int32) -> LTResult {
    guard let source else { return kLTBadArgument }
    let name = String(cString: source)
    if follow != 0 {
        LogFollowers.shared.follow(name)
    } else {
        LogFollowers.shared.unfollow(name)
    }
    return kLTOk
}

@_cdecl("lt_log_clear")
public func lt_log_clear(_ source: UnsafePointer<CChar>?) -> LTResult {
    guard let source else { return kLTBadArgument }
    let name = String(cString: source)
    guard let url = LogSources.url(for: name) else {
        LTLastError.set("lt_log_clear: unknown source '\(name)'")
        return kLTBadArgument
    }
    do {
        try "".write(to: url, atomically: true, encoding: .utf8)
        EventPump.shared.post(kind: kLTEventLogRotated) { e in
            e.u.logRotated.source = ltCopyCString(name)
        }
        return kLTOk
    } catch {
        LTLastError.set("lt_log_clear: \(error.localizedDescription)")
        return kLTFailed
    }
}

/// Pure: filter log text (Qt may do this in QML; exported for parity/testing).
@_cdecl("lt_log_filter")
public func lt_log_filter(
    _ text: UnsafePointer<CChar>?,
    _ filter: UnsafePointer<CChar>?,
    _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> Int32 {
    guard let text, let filter, let out else { return kLTBadArgument }
    let result = LogTail.filtered(String(cString: text), by: String(cString: filter))
    out.pointee = ltCopyCString(result).map { UnsafePointer($0) }
    return kLTOk
}
