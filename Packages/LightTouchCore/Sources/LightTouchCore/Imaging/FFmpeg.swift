// The ffmpeg/ffprobe subprocess pipeline: the cross-platform replacement for
// AVFoundation (encoding, export, metadata), AudioToolbox (AAC conversion)
// and ImageIO (decode/encode). ffmpeg 8 is expected on PATH (installed with
// the package); every entry point fails honestly when it is missing instead
// of crashing.
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
#if canImport(System)
import System
#else
import SystemPackage
#endif
import Foundation
import Subprocess
import Synchronization

public enum FFmpegError: Error, LocalizedError {
    case missing(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let what): return "\(what) needs ffmpeg, which isn’t installed."
        case .failed(let why): return why
        }
    }
}

public enum FFmpeg {
    /// Where the binary lives, or nil when ffmpeg isn't installed.
    public nonisolated static func executablePath() -> String? {
        for candidate in ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(dir) + "/ffmpeg"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public nonisolated static func probePath() -> String? {
        guard let ffmpeg = executablePath() else { return nil }
        let ffprobe = (ffmpeg as NSString).deletingLastPathComponent + "/ffprobe"
        return FileManager.default.isExecutableFile(atPath: ffprobe) ? ffprobe : nil
    }

    /// Run ffmpeg to completion, feeding `stdin` if given. Throws
    /// `FFmpegError.missing` when ffmpeg isn't installed, `FFmpegError.failed`
    /// with stderr's tail on a non-zero exit. Killing on cancellation: the
    /// child is SIGKILLed only while the body hasn't finished.
    @discardableResult
    public nonisolated static func run(
        _ arguments: [String],
        stdin: Data? = nil,
        stdoutLimit: Int = 4 << 20
    ) async throws -> (stdout: Data, stderr: String) {
        guard let bin = executablePath() else { throw FFmpegError.missing("This operation") }
        try Task.checkCancellation()
        do {
            let result = try await Subprocess.run(
                .path(FilePath(bin)),
                arguments: Arguments(arguments),
                input: .inputWriter,
                output: .bytes(limit: stdoutLimit),
                error: .string(limit: 8192)
            ) { execution in
                #if !os(Windows)
                let pid = execution.processIdentifier.value
                #endif
                let finished = Mutex(false)
                do {
                    try await withTaskCancellationHandler {
                        if let stdin, !stdin.isEmpty {
                            _ = try await execution.standardInputWriter.write([UInt8](stdin))
                        }
                        try await execution.standardInputWriter.finish()
                        finished.withLock { $0 = true }
                    } onCancel: {
                        #if !os(Windows)
                        if !finished.withLock({ $0 }) { kill(pid, SIGKILL) }
                        #endif
                    }
                } catch {
                    finished.withLock { $0 = true }
                    throw error
                }
            }
            // A kill from cancellation must surface as CancellationError, not
            // as ffmpeg's signal death (or a broken stdin pipe from it).
            try Task.checkCancellation()
            switch result.terminationStatus {
            case .exited(0): return (Data(result.standardOutput), result.standardError)
            case .exited(let code):
                throw FFmpegError.failed("ffmpeg exited with status \(code): \(result.standardError)")
            #if !os(Windows)
            case .signaled(let code):
                throw FFmpegError.failed("ffmpeg died from signal \(code): \(result.standardError)")
            #endif
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    // MARK: - ffprobe

    public nonisolated struct Stream: Sendable {
        public var codec: String
        public var codecType: String = ""
        public var profile: String?
        public var width = 0
        public var height = 0
        public var frameRate = 0.0
        /// H.264 level_idc as ffprobe reports it (30 = level 3.0).
        public var level = 0
        public var channels = 0
        public var sampleRate = 0.0
        public var duration = 0.0
        public var tags: [String: String] = [:]
    }

    public nonisolated struct Probe: Sendable {
        public var duration = 0.0
        public var title: String?
        public var formatTags: [String: String] = [:]
        public var streams: [Stream] = []
        public var video: [Stream] { streams.filter { $0.codecType == "video" } }
        public var audio: [Stream] { streams.filter { $0.codecType == "audio" } }
    }

    /// ffprobe's JSON for one file: durations, stream codecs/dimensions and
    /// the format tags (title etc.). Throws `FFmpegError.failed` when the file
    /// isn't readable media.
    public nonisolated static func probe(_ file: URL) async throws -> Probe {
        guard let bin = probePath() else { throw FFmpegError.missing("Reading this file") }
        try Task.checkCancellation()
        do {
            let result = try await Subprocess.run(
                .path(FilePath(bin)),
                arguments: [
                    "-v", "error", "-show_format", "-show_streams", "-of", "json", file.path,
                ],
                input: .none,
                output: .bytes(limit: 4 << 20),
                error: .string(limit: 4096)
            )
            // A kill from cancellation surfaces as a signal death (the child
            // is SIGKILLed); that must read as CancellationError, not as a
            // media failure. Mirrors FFmpeg.run's handling.
            try Task.checkCancellation()
            guard case .exited(0) = result.terminationStatus else {
                throw FFmpegError.failed("This file couldn’t be read as media.")
            }
            return try parseProbe(Data(result.standardOutput))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    nonisolated static func parseProbe(_ json: Data) throws -> Probe {
        struct JSONStream: Decodable {
            var codec_type: String?
            var codec_name: String?
            var profile: String?
            var width: Int?
            var height: Int?
            var avg_frame_rate: String?
            var level: Int?
            var channels: Int?
            var sample_rate: String?
            var duration: String?
            var tags: [String: String]?
        }
        struct JSONFormat: Decodable {
            var duration: String?
            var tags: [String: String]?
        }
        struct JSONProbe: Decodable {
            var streams: [JSONStream]?
            var format: JSONFormat?
        }
        let decoded = try JSONDecoder().decode(JSONProbe.self, from: json)
        var probe = Probe()
        if let duration = decoded.format?.duration.flatMap(Double.init) { probe.duration = duration }
        probe.formatTags = decoded.format?.tags ?? [:]
        probe.title = probe.formatTags["title"]
        for s in decoded.streams ?? [] {
            var stream = Stream(codec: s.codec_name ?? "", profile: s.profile)
            stream.codecType = s.codec_type ?? ""
            stream.width = s.width ?? 0
            stream.height = s.height ?? 0
            if let rate = s.avg_frame_rate {
                let parts = rate.split(separator: "/")
                if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 {
                    stream.frameRate = n / d
                }
            }
            stream.channels = s.channels ?? 0
            stream.sampleRate = Double(s.sample_rate ?? "") ?? 0
            stream.duration = Double(s.duration ?? "") ?? 0
            stream.level = s.level ?? 0
            stream.tags = s.tags ?? [:]
            probe.streams.append(stream)
        }
        return probe
    }
}
