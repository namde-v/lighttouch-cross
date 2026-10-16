import Crypto
import Foundation
import HostServiceWire
#if canImport(System)
import System
#else
import SystemPackage
#endif

/// Immutable host staging copy. Metadata and uploaded bytes always describe
/// the same file, even if the selected source is edited while a job waits.
///
/// Tag reading, duration/codec validation and AAC conversion run through
/// MediaTagParsers and ffmpeg (AVFoundation and AudioToolbox are Apple-only).
public struct MediaSong: Sendable {
    public let id: String
    public let directory: URL
    public let audio: URL
    public let metadata: URL
    public let title: String
    /// Cover art from the file's tags as a baseline JPEG, staged beside the audio.
    public var artwork: URL? = nil

    public nonisolated static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav"]

    // AudioFormatIDs (AudioToolbox is Apple-only; FourCharCodes kept for the
    // guest's metadata expectations).
    nonisolated static let formatMPEGLayer3: UInt32 = 0x6D70_3320
    nonisolated static let formatMPEG4AAC: UInt32 = 0x6161_6320
    nonisolated static let formatMPEG4AAC_HE: UInt32 = 0x6161_6368
    nonisolated static let formatAppleLossless: UInt32 = 0x616C_6163
    nonisolated static let formatLinearPCM: UInt32 = 0x6C70_636D

    public nonisolated static func prepare(_ source: URL) async throws -> MediaSong {
        let worker = Task.detached {
            try Task.checkCancellation()
            let ext = source.pathExtension.lowercased()
            guard extensions.contains(ext) else {
                throw DeviceToolsError.failed("Choose an MP3, M4A, AAC or WAV audio file.")
            }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                size > 0, size <= 1 << 30
            else {
                throw DeviceToolsError.failed("Audio files must be smaller than 1 GB.")
            }
            let id = UUID().uuidString.lowercased()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ltm-music-" + id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            var complete = false
            defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
            var audio = directory.appendingPathComponent("audio." + ext)
            guard FileManager.default.createFile(atPath: audio.path, contents: nil) else {
                throw DeviceToolsError.failed("Couldn’t prepare the audio file.")
            }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: audio)
            defer { try? output.close() }
            var copied = 0
            while copied < size {
                try Task.checkCancellation()
                guard let bytes = try input.read(upToCount: min(65536, size - copied)), !bytes.isEmpty else {
                    throw DeviceToolsError.failed("The audio file changed while it was being prepared.")
                }
                try output.write(contentsOf: bytes)
                copied += bytes.count
            }
            guard try input.read(upToCount: 1)?.isEmpty != false else {
                throw DeviceToolsError.failed("The audio file changed while it was being prepared.")
            }
            try output.close()
            // Include the source tags in identity, including those lost from the
            // converted AAC container. Distinct tagged tracks must not reconcile
            // as one song merely because their encoded samples match.
            let contentID = try MediaIdentity.identifier(for: audio)
            // ffmpeg converts samples, not ID3 tags. Read the immutable
            // source before converting ADTS AAC and deleting that staging file.
            var (properties, cover) = try await tags(of: audio)
            if ext == "aac" {
                let converted = directory.appendingPathComponent("audio.m4a")
                try await convertAAC(audio, to: converted)
                let size = try converted.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 1 << 30 else {
                    throw DeviceToolsError.failed("The converted audio must be smaller than 1 GB.")
                }
                try MediaIdentity.normalizeGeneratedMovie(converted)
                try FileManager.default.removeItem(at: audio)
                audio = converted
            }
            let probe = try await Self.probeAudio(audio)
            let duration = probe.duration
            guard duration.isFinite, duration > 0, duration <= 86400 else {
                throw DeviceToolsError.failed("This audio file is protected or has an unsupported duration.")
            }
            properties["filename"] = audio.lastPathComponent
            properties["duration_ms"] = duration * 1000
            let title = properties["title"] as? String ?? source.deletingPathExtension().lastPathComponent
            properties["title"] = title
            var artwork: URL?
            if let cover, cover.count <= 16 << 20 {
                let staged = directory.appendingPathComponent("cover.bin")
                try cover.write(to: staged, options: .atomic)
                defer { try? FileManager.default.removeItem(at: staged) }
                if let (width, height) = try? await ImageProbe.displaySize(of: staged),
                    width > 0, height > 0, width <= 16384, height <= 16384,
                    width * height <= 32_000_000
                {
                    let url = directory.appendingPathComponent("artwork.jpg")
                    // Unreadable art is dropped, never the song.
                    if (try? await MediaPhoto.writeBaselineJPEG(staged, maxPixelSize: 640, to: url)) != nil {
                        artwork = url
                        properties["artwork"] = url.lastPathComponent
                    }
                }
            }
            let metadata = directory.appendingPathComponent("metadata.plist")
            try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
                .write(to: metadata, options: .atomic)
            try Task.checkCancellation()
            let result = MediaSong(
                id: contentID,
                directory: directory,
                audio: audio,
                metadata: metadata,
                title: title,
                artwork: artwork
            )
            complete = true
            return result
        }
        return try await withTaskCancellationHandler {
            let song = try await worker.value
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: song.directory)
                throw CancellationError()
            }
            return song
        } onCancel: {
            worker.cancel()
        }
    }

    /// Every tag the device's Music library keeps, from iTunes (MP4) or ID3
    /// (MP3, raw AAC) metadata, with ffprobe's format tags as the fallback for
    /// other containers. Keys are the metadata plist's (itmedia maps them onto
    /// MusicLibrary's item properties). Returns the front cover's bytes too.
    public nonisolated static func tags(of url: URL) async throws -> ([String: Any], Data?) {
        var (properties, cover) = MediaTagParsers.parse(source: url, container: url.pathExtension.lowercased())
        // Fallback: containers neither parser covers (a WAV with no ID3, an
        // MP4 whose ilst sits somewhere unexpected).
        if properties["title"] == nil, let probe = try? await FFmpeg.probe(url) {
            func set(_ key: String, _ value: String?) {
                if let value, !value.isEmpty, properties[key] == nil { properties[key] = value }
            }
            let tags = probe.formatTags
            set("title", tags["title"])
            set("artist", tags["artist"])
            set("album", tags["album"])
            set("genre", tags["genre"])
        }
        return (properties, cover)
    }

    /// ffprobe validation: one audio track of a supported codec, 1-2 channels
    /// at 8-48 kHz. Returns the container duration.
    nonisolated static func probeAudio(_ url: URL) async throws -> (duration: Double, format: UInt32) {
        let probe: FFmpeg.Probe
        do {
            probe = try await FFmpeg.probe(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DeviceToolsError.failed("This audio file is protected or has an unsupported duration.")
        }
        let audio = probe.audio
        guard audio.count == 1, let stream = audio.first else {
            throw DeviceToolsError.failed("The file must contain one audio track.")
        }
        let format: UInt32
        switch stream.codec {
        case "aac": format = stream.profile == "HE-AAC" ? formatMPEG4AAC_HE : formatMPEG4AAC
        case "mp3": format = formatMPEGLayer3
        case "alac": format = formatAppleLossless
        case _ where stream.codec.hasPrefix("pcm_"): format = formatLinearPCM
        default:
            throw DeviceToolsError.failed(
                "Use AAC, MP3, Apple Lossless or PCM audio, with one or two channels at 8–48 kHz."
            )
        }
        guard (1...2).contains(stream.channels), (8000...48000).contains(stream.sampleRate) else {
            throw DeviceToolsError.failed(
                "Use AAC, MP3, Apple Lossless or PCM audio, with one or two channels at 8–48 kHz."
            )
        }
        return (probe.duration, format)
    }

    /// ID3 genres may be "(13)", "13" or "(13)Refinement"; resolve the ID3v1 index to its name.
    nonisolated static func genreName(_ value: String) -> String {
        let digits = value.hasPrefix("(") ? value.dropFirst().prefix { $0 != ")" } : Substring(value)
        guard let index = Int(digits), id3Genres.indices.contains(index) else { return value }
        return id3Genres[index]
    }

    nonisolated static let id3Genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal",
        "Jazz+Funk",
        "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic",
        "Gothic",
        "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy",
        "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychadelic",
        "Rave", "Showtunes",
        "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
    ]

    /// Stream raw ADTS AAC into an M4A file using ffmpeg's AAC encoder. The
    /// legacy Music library expects a container; no external converter is needed.
    nonisolated static func convertAAC(_ source: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        let probe: FFmpeg.Probe
        do {
            probe = try await FFmpeg.probe(source)
        } catch {
            throw DeviceToolsError.failed("Use mono or stereo AAC audio at 8–48 kHz.")
        }
        guard let stream = probe.audio.first, stream.codec == "aac",
            (1...2).contains(stream.channels), (8000...48000).contains(stream.sampleRate),
            probe.duration > 0, probe.duration <= 86400
        else {
            throw DeviceToolsError.failed("Use mono or stereo AAC audio at 8–48 kHz.")
        }
        do {
            try await FFmpeg.run([
                "-y", "-v", "error",
                "-i", source.path,
                // Only the audio: an ID3 APIC cover surfaces as an attached-pic
                // video stream, which ffmpeg would otherwise try to transcode
                // into the M4A (and fail). Upstream's AVAudioFile converted
                // samples, not tags.
                "-map", "0:a",
                "-c:a", "aac", "-b:a", "\(96000 * stream.channels)",
                "-movflags", "+faststart",
                destination.path,
            ])
        } catch let error as FFmpegError {
            switch error {
            case .missing: throw DeviceToolsError.failed("Converting AAC needs ffmpeg, which isn’t installed.")
            case .failed: throw DeviceToolsError.failed("The AAC file couldn’t be converted.")
            }
        }
        // Bound encoded output too; a day of stereo audio can exceed 1 GB.
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 1 << 30 else {
            throw DeviceToolsError.failed("The prepared audio is larger than 1 GB.")
        }
        try Task.checkCancellation()
    }
}
