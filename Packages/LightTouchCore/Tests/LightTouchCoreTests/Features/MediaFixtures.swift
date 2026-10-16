import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// Media files for the preparation tests, made here with ffmpeg (and, for
/// MP3, which nothing here encodes, silent frames written by hand).
enum MediaFixtures {
    typealias RGBA = (UInt8, UInt8, UInt8, UInt8)
    enum ImageType { case jpeg, png }

    /// An image `width`×`height` painted by `fill` (rectangles in pixel coordinates, top-left origin), written as
    /// `type` with the given EXIF orientation.
    static func image(
        _ url: URL,
        width: Int,
        height: Int,
        type: ImageType,
        orientation: Int? = nil,
        background: RGBA = (0, 0, 0, 0),
        fill: [(CGRect, RGBA)]
    ) async throws {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        func paint(_ rect: CGRect, _ c: RGBA) {
            for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
                for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) {
                    let i = (y * width + x) * 4
                    pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2; pixels[i + 3] = c.3
                }
            }
        }
        paint(CGRect(x: 0, y: 0, width: width, height: height), background)
        for (rect, color) in fill { paint(rect, color) }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".fixture-\(UUID().uuidString).raw")
        try Data(pixels).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        switch type {
        case .jpeg:
            try await FFmpeg.run([
                "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(width)x\(height)",
                "-i", tmp.path, "-frames:v", "1", "-q:v", "2", url.path,
            ])
        case .png:
            try await FFmpeg.run([
                "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(width)x\(height)",
                "-i", tmp.path, "-frames:v", "1", url.path,
            ])
        }
        if let orientation, type == .jpeg {
            try patchEXIFOrientation(url, orientation: orientation)
        }
    }

    /// Minimal EXIF: an APP1 segment carrying only the orientation tag.
    static func patchEXIFOrientation(_ url: URL, orientation: Int) throws {
        var data = try Data(contentsOf: url)
        guard data.count > 2, data[0] == 0xFF, data[1] == 0xD8 else {
            throw CocoaError(.fileWriteUnknown)
        }
        var exif = Data("Exif\0\0".utf8)
        exif += Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])  // II, 42, IFD at 8
        exif += Data([0x01, 0x00])  // one entry
        exif += Data([0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00,
            UInt8(orientation & 0xFF), UInt8((orientation >> 8) & 0xFF), 0x00, 0x00])
        exif += Data([0x00, 0x00, 0x00, 0x00])
        let length = exif.count + 2
        var segment = Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)])
        segment += exif
        data.insert(contentsOf: segment, at: 2)
        try data.write(to: url, options: .atomic)
    }

    /// The decoded pixels of an image file, and a sampler at (x, y) from the top left.
    static func pixels(_ url: URL) async throws -> (width: Int, height: Int, at: (Int, Int) -> RGBA) {
        let (width, height) = try await ImageProbe.displaySize(of: url)
        let (stdout, _) = try await FFmpeg.run(
            ["-v", "error", "-i", url.path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
            stdoutLimit: width * height * 3 + 16
        )
        guard stdout.count >= width * height * 3 else { throw CocoaError(.fileReadCorruptFile) }
        let bytes = [UInt8](stdout)
        return (
            width, height,
            { x, y in
                let i = (y * width + x) * 3
                return (bytes[i], bytes[i + 1], bytes[i + 2], 255)
            }
        )
    }

    static func isProgressiveJPEG(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count > 4 else { return false }
        var i = 2
        while i + 4 < data.count {
            guard data[i] == 0xFF else { return false }
            let marker = data[i + 1]
            if marker == 0xC2 { return true }
            if marker == 0xC0 { return false }
            if marker == 0xD9 || marker == 0xDA { return false }
            let length = Int(data[i + 2]) << 8 | Int(data[i + 3])
            guard length >= 2 else { return false }
            i += 2 + length
        }
        return false
    }

    enum ToneFormat { case aac, appleLossless, linearPCM }

    /// A stereo 440 Hz tone, `seconds` long at 44.1 kHz, in `format` (AAC or
    /// Apple Lossless in .m4a, PCM in .wav).
    static func tone(_ url: URL, seconds: Double = 6, format: ToneFormat) async throws {
        let codec: String
        switch format {
        case .aac: codec = "aac"
        case .appleLossless: codec = "alac"
        case .linearPCM: codec = "pcm_s16le"
        }
        try await FFmpeg.run([
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds):sample_rate=44100",
            "-ac", "2", "-c:a", codec,
            url.path,
        ])
    }

    /// `seconds` of silent MPEG-1 Layer III, 128 kbit/s, 44.1 kHz stereo: frames whose side information is all
    /// zero decode as silence.
    static func silentMP3(_ url: URL, seconds: Double = 6) throws {
        let frameCount = Int((seconds * 44100 / 1152).rounded(.up))
        var frame = Data([0xFF, 0xFB, 0x90, 0x00])
        frame.append(Data(count: 417 - 4))
        try Data((0..<frameCount).flatMap { _ in frame }).write(to: url)
    }

    /// The AAC packets of an .m4a as raw ADTS (what a .aac file holds).
    static func adts(from m4a: URL, to url: URL) async throws {
        try await FFmpeg.run([
            "-y", "-v", "error", "-i", m4a.path, "-map", "0:a", "-c:a", "copy", "-f", "adts", url.path,
        ])
    }

    /// A `width`×`height` H.264 movie at 30 fps, `seconds` long, moving color bars, with a stereo AAC tone track.
    static func movie(_ url: URL, width: Int, height: Int, seconds: Int = 6) async throws {
        try await FFmpeg.run([
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "testsrc2=size=\(width)x\(height):rate=30:duration=\(seconds)",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds):sample_rate=44100",
            "-ac", "2",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "128k",
            "-shortest",
            url.path,
        ])
    }

    /// A movie's video track as the device decodes it: size, frame rate, H.264 profile_idc and level_idc, and each
    /// audio track's codec, channels and sample rate.
    nonisolated struct MovieFormat: Sendable {
        var width = 0, height = 0, frameRate = 0.0, codec: UInt32 = 0, profile = 0, level = 0
        var audio: [(codec: UInt32, channels: Int, rate: Double)] = []
    }

    static func format(of url: URL) async throws -> MovieFormat {
        let probe = try await FFmpeg.probe(url)
        var result = MovieFormat()
        guard let video = probe.video.first else { throw CocoaError(.fileReadCorruptFile) }
        result.width = video.width
        result.height = video.height
        result.frameRate = video.frameRate
        result.codec = fourCC(video.codec, fallback: 0)
        // ffprobe names the profile; the tests want the H.264 profile_idc.
        result.profile =
            switch video.profile {
            case "Constrained Baseline", "Baseline": 66
            case "Main": 77
            case "High": 100
            default: 0
            }
        result.level = video.level
        for audio in probe.audio {
            result.audio.append((fourCC(audio.codec, fallback: 0), audio.channels, audio.sampleRate))
        }
        return result
    }

    private static func fourCC(_ codec: String, fallback: UInt32) -> UInt32 {
        switch codec {
        case "h264": return 0x6176_6331  // 'avc1'
        case "aac": return 0x6161_6320
        case "mp3": return 0x6D70_3320
        case "alac": return 0x616C_6163
        default:
            guard codec.hasPrefix("pcm_") else { return fallback }
            return 0x6C70_636D
        }
    }

    /// Write iTunes metadata atoms into an M4A's moov (the fixture writer for
    /// MediaTagsTests): `items` of (box name, data-atom type, payload).
    /// The udta is appended inside moov, which ffmpeg writes after mdat, so no
    /// chunk offsets move.
    static func tagM4A(_ url: URL, items: [(name: [UInt8], type: UInt32, payload: Data)]) throws {
        var data = try Data(contentsOf: url)
        func box(_ name: [UInt8], _ content: Data) -> Data {
            var d = Data()
            let size = UInt32(content.count + 8).bigEndian
            d += withUnsafeBytes(of: size) { Data($0) }
            d += Data(name)
            d += content
            return d
        }
        // The iTunes items, each its name box (©nam, trkn, …) holding the data box.
        var itemsData = Data()
        for item in items {
            var atom = Data()
            let type = item.type.bigEndian
            atom += withUnsafeBytes(of: type) { Data($0) }
            atom += Data([0, 0, 0, 0])  // locale
            atom += item.payload
            itemsData += box(item.name, box(Array("data".utf8), atom))
        }
        var hdlr = Data([0, 0, 0, 0, 0, 0, 0, 0])  // version/flags, pre_defined
        hdlr += Data("mdir".utf8)
        hdlr += Data(count: 12)
        hdlr += Data([0])
        let hdlrBox = box(Array("hdlr".utf8), hdlr)
        /// The full range (header included) of the first child box named `name` in a parent's content.
        func childBox(in parentContent: Range<Int>, named name: [UInt8]) -> Range<Int>? {
            var k = parentContent.lowerBound
            while k + 8 <= parentContent.upperBound {
                let size = Int(data[k]) << 24 | Int(data[k + 1]) << 16 | Int(data[k + 2]) << 8 | Int(data[k + 3])
                guard size >= 8, k + size <= parentContent.upperBound else { return nil }
                if Array(data[(k + 4)..<(k + 8)]) == name { return k..<(k + size) }
                k += size
            }
            return nil
        }
        /// Bump the size fields of these boxes (header included ranges, captured before the insert).
        func grow(_ boxes: [Range<Int>], by count: Int) {
            for r in boxes {
                let newSize = UInt32(r.count + count).bigEndian
                withUnsafeBytes(of: newSize) {
                    data.replaceSubrange(r.lowerBound..<(r.lowerBound + 4), with: $0)
                }
            }
        }
        // The top-level moov.
        var i = data.startIndex
        var moov: Range<Int>?
        while i + 8 <= data.endIndex {
            let size = Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
            guard size >= 8, i + size <= data.endIndex else { break }
            if data[(i + 4)..<(i + 8)].elementsEqual("moov".utf8) {
                moov = i..<(i + size)
                break
            }
            i += size
        }
        guard let moov else { throw CocoaError(.fileWriteUnknown) }
        let moovContent = (moov.lowerBound + 8)..<moov.upperBound
        // ffmpeg already wrote a udta (its ©too encoder tag): the items join
        // its ilst, the way a real tagger merges. A second udta, or a second
        // meta, would be malformed, and the parser reads the first.
        if let udta = childBox(in: moovContent, named: Array("udta".utf8)),
            let meta = childBox(
                in: (udta.lowerBound + 8)..<udta.upperBound, named: Array("meta".utf8)
            ),
            let ilst = childBox(
                in: (meta.lowerBound + 8 + 4)..<meta.upperBound, named: Array("ilst".utf8)
            )
        {
            data.insert(contentsOf: itemsData, at: ilst.upperBound)
            grow([ilst, meta, udta, moov], by: itemsData.count)
        } else if let udta = childBox(in: moovContent, named: Array("udta".utf8)) {
            var metaContent = Data([0, 0, 0, 0])  // version/flags
            metaContent += hdlrBox + box(Array("ilst".utf8), itemsData)
            let metaBox = box(Array("meta".utf8), metaContent)
            data.insert(contentsOf: metaBox, at: udta.upperBound)
            grow([udta, moov], by: metaBox.count)
        } else {
            var metaContent = Data([0, 0, 0, 0])  // version/flags
            metaContent += hdlrBox + box(Array("ilst".utf8), itemsData)
            let udtaBox = box(Array("udta".utf8), box(Array("meta".utf8), metaContent))
            data.insert(contentsOf: udtaBox, at: moov.upperBound)
            grow([moov], by: udtaBox.count)
        }
        try data.write(to: url, options: .atomic)
    }
}
