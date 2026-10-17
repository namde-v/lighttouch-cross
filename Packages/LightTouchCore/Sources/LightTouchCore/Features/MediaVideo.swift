#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation
import HostRuntime
import HostServiceWire
import Subprocess
import Synchronization
#if canImport(System)
import System
#else
import SystemPackage
#endif

/// A private, iPod-compatible movie prepared before it joins the device queue.
///
/// Inspection and transcoding run through ffprobe/ffmpeg (AVFoundation is
/// Apple-only); the atomic cache publish uses renameat2(2) instead of
/// renamex_np(2).
public struct MediaVideo: Sendable {
    public let id: String
    public let directory: URL
    public let video: URL
    public let metadata: URL
    public let title: String

    public nonisolated static let extensions: Set<String> = ["mp4", "m4v", "mov"]

    public nonisolated static func prepare(_ source: URL, cacheDirectory: URL? = nil, profile: Board) async throws
        -> MediaVideo
    {
        let worker = Task.detached {
            try Task.checkCancellation()
            guard extensions.contains(source.pathExtension.lowercased()) else {
                throw DeviceToolsError.failed("Choose an MP4, M4V or QuickTime video.")
            }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 1 << 30 else {
                throw DeviceToolsError.failed("Videos must be smaller than 1 GB.")
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ltm-video-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            var complete = false
            defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
            // The original can be renamed or edited after the drop. Keep a
            // snapshot so the exported movie and its metadata stay together.
            let snapshot = directory.appendingPathComponent("source." + source.pathExtension.lowercased())
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            guard
                FileManager.default.createFile(
                    atPath: snapshot.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            else {
                throw DeviceToolsError.failed("Couldn’t prepare the video.")
            }
            let copy = try FileHandle(forWritingTo: snapshot)
            defer { try? copy.close() }
            var copied = 0
            while copied < size {
                try Task.checkCancellation()
                guard let bytes = try input.read(upToCount: min(65536, size - copied)), !bytes.isEmpty else {
                    throw DeviceToolsError.failed("The video changed while it was being prepared.")
                }
                try copy.write(contentsOf: bytes)
                copied += bytes.count
            }
            guard try input.read(upToCount: 1)?.isEmpty != false else {
                throw DeviceToolsError.failed("The video changed while it was being prepared.")
            }
            try copy.close()
            let probe = try await Self.probeMovie(snapshot)
            let duration = probe.duration
            var title = source.deletingPathExtension().lastPathComponent
            if let tagged = probe.title, !tagged.isEmpty, tagged.utf8.count <= 4096 {
                title = tagged
            }
            let output = directory.appendingPathComponent("video.m4v")
            let cache =
                cacheDirectory
                ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("gold.samhenri.LightTouchMac/Converted Videos", isDirectory: true)
            try FileManager.default.createDirectory(
                at: cache,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
            let cached = cache.appendingPathComponent(
                try MediaIdentity.identifier(for: snapshot)
                    + (MediaVideoExport.playsHD(profile) ? "-720p" : "") + ".m4v"
            )
            var reused = false
            if FileManager.default.fileExists(atPath: cached.path) {
                do {
                    try FileManager.default.copyItem(at: cached, to: output)
                    _ = try await validatedDuration(of: output, expected: duration, profile: profile)
                    reused = true
                } catch {
                    try Task.checkCancellation()
                    try? FileManager.default.removeItem(at: output)
                    try? FileManager.default.removeItem(at: cached)
                }
            }
            if !reused {
                let export = await MediaVideoExport(source: snapshot, destination: output, profile: profile)
                try await withTaskCancellationHandler {
                    try await export.run()
                } onCancel: {
                    Task { await export.cancel() }
                }
                try Task.checkCancellation()
                _ = try await validatedDuration(of: output, expected: duration, profile: profile)
                try MediaIdentity.normalizeGeneratedMovie(output)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                // H.264 encoding can vary by a byte between identical runs.
                // Reuse the completed conversion so Retry after an uncertain
                // guest reply reconciles one library entry, not a second movie.
                // Publish atomically; simultaneous imports adopt the winner.
                // renameat2(2) with RENAME_NOREPLACE fails in the kernel when
                // the destination exists (renamex_np(2) on Darwin).
                let publishing = cache.appendingPathComponent(".\(UUID().uuidString).m4v")
                defer { try? FileManager.default.removeItem(at: publishing) }
                try FileManager.default.copyItem(at: output, to: publishing)
                if renameNoReplace(from: publishing.path, to: cached.path) != 0 {
                    guard errno == EEXIST else {
                        throw DeviceToolsError.failed(
                            "Couldn’t save the converted video (\(String(cString: strerror(errno))))."
                        )
                    }
                    try FileManager.default.removeItem(at: output)
                    try FileManager.default.copyItem(at: cached, to: output)
                }
            }
            try Task.checkCancellation()
            let exportedDuration = try await validatedDuration(of: output, expected: duration, profile: profile)
            let metadata = directory.appendingPathComponent("metadata.plist")
            let properties: [String: Any] = [
                "filename": output.lastPathComponent,
                "kind": "feature-movie",
                "title": title,
                "duration_ms": exportedDuration * 1000,
            ]
            try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
                .write(to: metadata, options: .atomic)
            let result = MediaVideo(
                id: try MediaIdentity.identifier(for: output),
                directory: directory,
                video: output,
                metadata: metadata,
                title: title
            )
            try FileManager.default.removeItem(at: snapshot)
            complete = true
            return result
        }
        return try await withTaskCancellationHandler {
            let video = try await worker.value
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: video.directory)
                throw CancellationError()
            }
            return video
        } onCancel: {
            worker.cancel()
        }
    }

    /// ffprobe validation: an unprotected video with one video track and at
    /// most one audio track, and a sane duration. (DRM detection has no Linux
    /// equivalent; see SHIM_NOTES.md.)
    nonisolated static func probeMovie(_ file: URL) async throws -> FFmpeg.Probe {
        let probe: FFmpeg.Probe
        do {
            probe = try await FFmpeg.probe(file)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DeviceToolsError.failed(
                "Choose an unprotected video with one video track and no more than one audio track."
            )
        }
        let duration = probe.duration
        guard duration.isFinite, duration > 0, duration <= 86400,
            probe.video.count == 1, probe.audio.count <= 1
        else {
            throw DeviceToolsError.failed(
                "Choose an unprotected video with one video track and no more than one audio track."
            )
        }
        return probe
    }

    nonisolated private static func validatedDuration(of file: URL, expected duration: Double, profile: Board)
        async throws -> Double
    {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let probe = try await Self.probeMovie(file)
        let exportedDuration = probe.duration
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size > 0
        else {
            throw DeviceToolsError.failed("The prepared video couldn’t be read.")
        }
        guard size <= 1 << 30 else {
            throw DeviceToolsError.failed("The prepared video is too large. Choose a shorter video.")
        }
        guard exportedDuration.isFinite, abs(exportedDuration - duration) < 0.2,
            probe.video.count == 1
        else {
            throw DeviceToolsError.failed(
                "The whole video couldn’t be converted for the \(profile.shortName). Try a shorter video."
            )
        }
        return exportedDuration
    }
}

/// Publish `from` at `to`, failing when `to` exists — the atomic-rename half of
/// renamex_np(2) with RENAME_EXCL on Darwin. Implemented as link(2)+unlink(2):
/// link fails with EEXIST when the destination exists, and both paths are in
/// the same directory (so the same filesystem). Returns 0 on success, -1 with
/// errno set otherwise.
private nonisolated func renameNoReplace(from: String, to: String) -> Int32 {
    #if os(Linux)
    let result = from.withCString { f in
        to.withCString { t in
            Glibc.link(f, t)
        }
    }
    guard result == 0 else { return -1 }
    from.withCString { _ = Glibc.unlink($0) }
    return 0
    #elseif os(Windows)
    // renamex_np is Darwin-only. On Windows, fail if the destination exists,
    // else use the CRT rename (which is atomic for the replace case we avoid).
    let attrs = to.withCString { WinSDK.GetFileAttributesA($0) }
    guard attrs == WinSDK.INVALID_FILE_ATTRIBUTES else { return -1 }
    return from.withCString { f in
        to.withCString { t in
            rename(f, t)
        }
    }
    #else
    return from.withCString { f in
        to.withCString { t in
            renamex_np(f, t, UInt32(RENAME_EXCL))
        }
    }
    #endif
}

/// Keep the non-Sendable exporter on one actor, including cancellation.
@MainActor
private final class MediaVideoExport {
    private let source: URL
    private let destination: URL
    private let profile: Board
    // Set from the export's body closure (off the actor); Mutex makes the
    // kill-on-cancel race-free.
    #if os(Windows)
    // WinSDK has no pid_t; the value is a process ID (DWORD).
    private nonisolated(unsafe) let pid = Mutex<Int32>(-1)
    #else
    private nonisolated(unsafe) let pid = Mutex<pid_t>(-1)
    #endif

    /// The A4 devices (iPad, iPhone 4, iPod touch 4th generation) play H.264 up to 720p.
    public nonisolated static func playsHD(_ profile: Board) -> Bool { profile.soc == .s5l8930 }

    public init(source: URL, destination: URL, profile: Board) {
        self.source = source
        self.destination = destination
        self.profile = profile
    }

    public func run() async throws {
        try Task.checkCancellation()
        // The device presets' H.264/AAC profile, dimensions and frame rate the
        // hardware plays: 640×480 for the iPods and the iPhone 3GS, 720p for
        // the A4 devices. Baseline profile, levels 3.0 / 3.1.
        guard let bin = FFmpeg.executablePath() else {
            throw DeviceToolsError.failed("Converting video needs ffmpeg, which isn’t installed.")
        }
        let hd = Self.playsHD(profile)
        let scale = hd ? "1280:720" : "640:480"
        let level = hd ? "3.1" : "3.0"
        // Fit within the profile's frame, keeping aspect; the second scale
        // rounds down to even dimensions — libx264 (yuv420p) rejects odd
        // heights like the 640×427 that 480×320 scales to.
        let scaleFilter =
            "scale=\(scale):force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"
        var arguments = [
            "-y", "-v", "error",
            "-i", source.path,
            "-vf", scaleFilter,
            "-r", "30",
            "-c:v", "libx264", "-profile:v", "baseline", "-level", level, "-pix_fmt", "yuv420p",
        ]
        // Probe once for the audio track: keep it (AAC, stereo, 48 kHz) or drop it.
        let probe = try await MediaVideo.probeMovie(source)
        if probe.audio.isEmpty {
            arguments += ["-an"]
        } else {
            arguments += ["-c:a", "aac", "-b:a", "128k", "-ac", "2", "-ar", "48000"]
        }
        arguments += ["-movflags", "+faststart", destination.path]
        do {
            try await transcode(bin: bin, arguments: arguments, profileName: profile.shortName)
        } catch is CancellationError {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    /// Runs ffmpeg, polling for its exit without holding the actor; a throw
    /// kills it. Nonisolated: swift-subprocess invokes the body off the
    /// caller's executor, and a @MainActor-isolated closure traps there
    /// (dispatch_assert_queue_fail → SIGILL). Only the nonisolated pid Mutex
    /// is touched off-actor.
    private nonisolated func transcode(bin: String, arguments: [String], profileName: String) async throws {
        let result = try await Subprocess.run(
            .path(FilePath(bin)),
            arguments: Arguments(arguments),
            input: .none,
            output: .discarded,
            error: .string(limit: 8192)
        ) { execution in
            let pidValue = execution.processIdentifier.value
            #if os(Windows)
            self.pid.withLock { $0 = Int32(bitPattern: pidValue) }
            #else
            self.pid.withLock { $0 = pidValue }
            #endif
            defer { self.pid.withLock { $0 = -1 } }
            do {
                // Wait for the transcode without holding the actor: ffmpeg
                // exiting ends the polling, cancellation kills it. A zombie
                // still answers kill(pid, 0), so poll /proc for a live state;
                // Subprocess.run reaps it once the body returns.
                #if os(Windows)
                while Self.isProcessRunning(Int32(bitPattern: pidValue)) {
                #else
                while Self.isProcessRunning(pidValue) {
                #endif
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                #if os(Windows)
                // No POSIX kill on Windows; the Subprocess runner reaps on cancellation.
                #else
                kill(pidValue, SIGKILL)
                #endif
                throw error
            }
        }
        try Task.checkCancellation()
        switch result.terminationStatus {
        case .exited(0): break
        case .exited(let code):
            throw DeviceToolsError.failed(
                "This video couldn’t be converted for the \(profileName) (ffmpeg exited \(code))."
            )
        case .signaled:
            throw DeviceToolsError.failed("This video couldn’t be converted for the \(profileName).")
        }
    }

    public func cancel() {
        let pid = pid.withLock { $0 }
        #if os(Windows)
        // No POSIX kill on Windows; cancellation is cooperative via Task.
        _ = pid
        #else
        if pid > 0 { kill(pid, SIGKILL) }
        #endif
    }

    /// Whether the process is still running: gone when /proc/pid/stat is
    /// unreadable, and a zombie (state Z) counts as exited — kill(pid, 0)
    /// still succeeds for zombies, which would spin the transcode poll
    /// forever.
    #if os(Windows)
    private nonisolated static func isProcessRunning(_ pid: Int32) -> Bool {
        // /proc is Linux-only; on Windows, assume the process is running until
        // the Subprocess runner reaps it (the poll loop exits on completion).
        return true
    }
    #else
    private nonisolated static func isProcessRunning(_ pid: pid_t) -> Bool {
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let closeParen = stat.lastIndex(of: ")")
        else { return false }
        let fields = stat[stat.index(after: closeParen)...].split(separator: " ", omittingEmptySubsequences: true)
        return fields.first != "Z"
    }
    #endif
}
