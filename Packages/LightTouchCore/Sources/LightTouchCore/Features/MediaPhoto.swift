import Foundation
import HostRuntime
import HostServiceWire
#if canImport(System)
import System
#else
import SystemPackage
#endif

/// A small, upright baseline JPEG for the guest's native Saved Photos API.
/// Decoding, EXIF-aware sizing and JPEG encoding run through ffmpeg (see
/// Imaging/FFmpeg.swift); ImageIO is Apple-only.
public struct MediaPhoto: Sendable {
    public let id: String
    public let directory: URL
    public let image: URL
    public let title: String

    public nonisolated static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]

    public nonisolated static func prepare(_ source: URL) async throws -> MediaPhoto {
        let worker = Task.detached {
            try Task.checkCancellation()
            guard extensions.contains(source.pathExtension.lowercased()) else {
                throw DeviceToolsError.failed("Choose a JPEG, PNG or HEIC photo.")
            }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                throw DeviceToolsError.failed("This photo couldn’t be read.")
            }
            guard size <= 64 << 20 else {
                throw DeviceToolsError.failed("This photo is too large. Choose one smaller than 64 MB.")
            }
            let (width, height): (Int, Int)
            do {
                (width, height) = try await ImageProbe.displaySize(of: source)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DeviceToolsError.failed("This photo couldn’t be read.")
            }
            guard width > 0, height > 0 else {
                throw DeviceToolsError.failed("This photo couldn’t be read.")
            }
            guard width <= 100000, height <= 100000, width * height <= 100_000_000 else {
                throw DeviceToolsError.failed("This photo is too large. Choose one below 100 megapixels.")
            }
            let temporaryID = UUID().uuidString.lowercased()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ltm-photo-" + temporaryID, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            var complete = false
            defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
            let output = directory.appendingPathComponent("image.jpg")
            do {
                try await writeBaselineJPEG(source, maxPixelSize: 2048, to: output)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DeviceToolsError {
                throw error
            } catch {
                throw DeviceToolsError.failed("This photo couldn’t be read.")
            }
            try Task.checkCancellation()
            let id = try MediaIdentity.identifier(for: output)
            let result = MediaPhoto(
                id: id,
                directory: directory,
                image: output,
                title: source.deletingPathExtension().lastPathComponent
            )
            complete = true
            return result
        }
        return try await withTaskCancellationHandler {
            let photo = try await worker.value
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: photo.directory)
                throw CancellationError()
            }
            return photo
        } onCancel: {
            worker.cancel()
        }
    }

    /// Upright (EXIF rotation applied), opaque (flattened on white), baseline
    /// JPEG no larger than `maxPixelSize` on either side: what the legacy
    /// guests' Photos and Music artwork decoders accept.
    public nonisolated static func writeBaselineJPEG(_ source: URL, maxPixelSize: Int, to output: URL) async throws {
        try Task.checkCancellation()
        let (width, height): (Int, Int)
        do {
            (width, height) = try await ImageProbe.displaySize(of: source)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DeviceToolsError.failed("This photo couldn’t be read.")
        }
        guard width > 0, height > 0 else {
            throw DeviceToolsError.failed("This photo couldn’t be read.")
        }
        let scale = min(1, Double(maxPixelSize) / Double(max(width, height)))
        let targetWidth = max(1, Int((Double(width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(height) * scale).rounded()))
        // ffmpeg applies the EXIF orientation before the filter chain, so the
        // scale sees the upright image; the color-source overlay flattens
        // transparency against white (JPEG has no alpha). mjpeg's default is
        // baseline (SOF C0), matching ImageIO's non-progressive output.
        do {
            try await FFmpeg.run([
                "-y", "-v", "error",
                "-i", source.path,
                "-filter_complex",
                "[0:v]scale=\(targetWidth):\(targetHeight),format=yuva420p[fg];"
                    + "color=c=white:s=\(targetWidth)x\(targetHeight),format=yuv420p[bg];"
                    + "[bg][fg]overlay=format=yuv420:shortest=1[v]",
                "-map", "[v]", "-frames:v", "1",
                "-q:v", "3",
                output.path,
            ])
        } catch let error as FFmpegError {
            switch error {
            case .missing: throw DeviceToolsError.failed("Preparing photos needs ffmpeg, which isn’t installed.")
            case .failed: throw DeviceToolsError.failed("This photo couldn’t be read.")
            }
        }
        try Task.checkCancellation()
    }
}
