import Foundation
import Testing

@testable import LightTouchCore

/// Song preparation (MediaSong): the staged copy is the source's bytes with its duration and one identity, raw ADTS
/// AAC becomes an M4A whose identity survives a second conversion, malformed audio is refused and cancellation
/// honored. The sources are six seconds each: AAC and Apple Lossless M4A, PCM WAV and silent MP3.
// The fixtures need ffmpeg, which Windows CI doesn't have.
#if !os(Windows)
struct MediaSongTests {
    static func write(_ name: String, to url: URL) async throws {
        switch name {
        case "aac.m4a": try await MediaFixtures.tone(url, format: .aac)
        case "lossless.m4a": try await MediaFixtures.tone(url, format: .appleLossless)
        case "stereo.wav": try await MediaFixtures.tone(url, format: .linearPCM)
        default: try MediaFixtures.silentMP3(url)
        }
    }

    @Test(arguments: ["aac.m4a", "lossless.m4a", "stereo.wav", "tone.mp3"])
    func stagedCopyKeepsTheBytes(_ name: String) async throws {
        try await withTemporaryState { work in
            let source = work.appendingPathComponent(name)
            try await Self.write(name, to: source)
            let song = try await MediaSong.prepare(source)
            defer { try? FileManager.default.removeItem(at: song.directory) }
            #expect(
                try Data(contentsOf: song.audio) == Data(contentsOf: source),
                "the staged copy is the source's bytes"
            )
            let metadata =
                try PropertyListSerialization.propertyList(from: Data(contentsOf: song.metadata), format: nil)
                as? [String: Any]
            let duration = try #require(metadata?["duration_ms"] as? Double)
            #expect(abs(duration - 6000) < 100, "\(duration) ms")
            #expect(metadata?["filename"] as? String == song.audio.lastPathComponent)
            #expect(UUID(uuidString: song.id) != nil)
            let repeated = try await MediaSong.prepare(source)
            defer { try? FileManager.default.removeItem(at: repeated.directory) }
            #expect(repeated.id == song.id && repeated.directory != song.directory)
        }
    }

    @Test func rawAACBecomesM4AWithAStableIdentity() async throws {
        try await withTemporaryState { work in
            let m4a = work.appendingPathComponent("source.m4a")
            let raw = work.appendingPathComponent("raw.aac")
            try await MediaFixtures.tone(m4a, format: .aac)
            try await MediaFixtures.adts(from: m4a, to: raw)
            let converted = try await MediaSong.prepare(raw)
            defer { try? FileManager.default.removeItem(at: converted.directory) }
            #expect(converted.audio.pathExtension == "m4a")
            let probe = try await FFmpeg.probe(converted.audio)
            #expect(abs(probe.duration - 6) < 0.15, "converted duration \(probe.duration)")
            #expect(
                !FileManager.default.fileExists(atPath: converted.directory.appendingPathComponent("audio.aac").path)
            )
            // A second conversion a second later writes new timestamps; the identity ignores them.
            try await Task.sleep(for: .seconds(1.1))
            let repeated = try await MediaSong.prepare(raw)
            defer { try? FileManager.default.removeItem(at: repeated.directory) }
            #expect(repeated.id == converted.id, "AAC conversion changed content identity")
        }
    }

    @Test func malformedAndCancelled() async throws {
        try await withTemporaryState { work in
            let invalid = work.appendingPathComponent("invalid.m4a")
            try Data("not audio".utf8).write(to: invalid)
            await #expect(throws: (any Error).self) { try await MediaSong.prepare(invalid) }
            let source = work.appendingPathComponent("aac.m4a")
            try await MediaFixtures.tone(source, format: .aac)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await MediaSong.prepare(source)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }
}
#endif
