import LTBridgeC
/// Log tail following (ui/ABI.md §3.9): `lt_log_follow` subscriptions turn
/// appended log bytes into `kLTEventLogLine` batches; rotation/truncation
/// into `kLTEventLogRotated`.
///
/// Sources: `"app"` (the core's AppEventLog) and `"helper:<uuid>"` (a device's
/// native.log). The follow poll runs from `lt_pump_main_queue()` on @MainActor.
/// Batches are whole lines, capped per post; a partial trailing line is
/// buffered until its newline arrives.
import Foundation
import LightTouchCore

@MainActor
final class LogFollow {
    private weak var core: AppCore?
    /// source -> byte offset already delivered.
    private var offsets: [String: UInt64] = [:]
    /// source -> buffered partial line (no newline yet).
    private var partials: [String: Data] = [:]

    init(core: AppCore) { self.core = core }

    // MARK: - Source resolution

    /// All tail-able sources right now.
    func sources() -> [String] {
        var result = ["app"]
        guard let core else { return result }
        for session in core.allSessions() {
            let url = session.paths.logs.appendingPathComponent("native.log")
            if FileManager.default.fileExists(atPath: url.path) {
                result.append("helper:\(session.instance.id.uuidString.lowercased())")
            }
        }
        return result
    }

    /// The file behind a source, or nil when unknown.
    func url(for source: String) -> URL? {
        if source == "app" {
            guard let dir = Bundled.preparedLogsDirectory else { return nil }
            return dir.appendingPathComponent("app.log")
        }
        guard source.hasPrefix("helper:") else { return nil }
        let id = String(source.dropFirst("helper:".count))
        guard let uuid = UUID(uuidString: id),
            let session = core?.sessions[uuid]
        else { return nil }
        return session.paths.logs.appendingPathComponent("native.log")
    }

    // MARK: - Follow control

    func setFollow(_ source: String, follow: Bool) {
        if follow {
            if offsets[source] == nil {
                // Start at the end: following shows new lines, like tail -f.
                offsets[source] = size(of: source)
            }
        } else {
            offsets.removeValue(forKey: source)
            partials.removeValue(forKey: source)
        }
    }

    func isFollowing(_ source: String) -> Bool { offsets[source] != nil }

    // MARK: - Poll (from lt_pump_main_queue)

    func poll() {
        for source in offsets.keys {
            pollSource(source)
        }
    }

    private func pollSource(_ source: String) {
        guard let url = url(for: source),
            let last = offsets[source]
        else { return }
        let size = size(of: url)
        if size < last {
            // Rotated/replaced: Qt resets its offset to 0 and we re-read.
            offsets[source] = 0
            partials[source] = nil
            EventPump.shared.post(kind: kLTEventLogRotated) { e in
                e.u.logRotated.source = ltCopyCString(source)
            }
            return pollSource(source)
        }
        guard size > last else { return }
        // Cap a single post (whole lines; the remainder waits for next poll).
        let maxBatch: UInt64 = 65536
        let end = min(size, last + maxBatch)
        guard let data = readBytes(url: url, from: last, to: end), !data.isEmpty else {
            offsets[source] = end
            return
        }
        var buffer = (partials[source] ?? Data()) + data
        partials[source] = nil
        // Split whole lines; keep the trailing partial for the next batch.
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 10) {
            lines.append(Data(buffer[..<nl]))
            buffer = Data(buffer[buffer.index(after: nl)...])
        }
        partials[source] = buffer.isEmpty ? nil : buffer
        offsets[source] = end
        guard !lines.isEmpty else { return }
        let text = lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        let offset = end
        EventPump.shared.post(kind: kLTEventLogLine) { e in
            e.u.logLine.source = ltCopyCString(source)
            e.u.logLine.text = ltCopyCString(text)
            e.u.logLine.offset = offset
        }
    }

    // MARK: - Clear

    /// Truncates the log (the Clear button); emits kLTEventLogRotated.
    func clear(_ source: String) -> Bool {
        guard let url = url(for: source) else { return false }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.close()
        } catch {
            return false
        }
        offsets[source] = 0
        partials[source] = nil
        EventPump.shared.post(kind: kLTEventLogRotated) { e in
            e.u.logRotated.source = ltCopyCString(source)
        }
        return true
    }

    // MARK: - Helpers

    private func size(of source: String) -> UInt64 {
        guard let url = url(for: source) else { return 0 }
        return size(of: url)
    }

    private func size(of url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private func readBytes(url: URL, from: UInt64, to: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: from)) != nil else { return nil }
        return try? handle.read(upToCount: Int(to - from))
    }
}
