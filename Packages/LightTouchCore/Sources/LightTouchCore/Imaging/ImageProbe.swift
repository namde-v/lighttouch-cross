// Still-image probing without ImageIO: ffprobe for the coded dimensions,
// plus a tiny pure-Swift EXIF reader for JPEG orientation (ffprobe doesn't
// expose it). ffmpeg's decoder applies the orientation itself (`-autorotate`,
// on by default), so callers need the *display* size to size their outputs.
import Foundation

public nonisolated enum ImageProbe {
    /// The image's display dimensions: coded size with EXIF orientations 5-8
    /// (the transposing ones) swapped. Throws when the file isn't an image.
    public nonisolated static func displaySize(of url: URL) async throws -> (width: Int, height: Int) {
        let probe = try await FFmpeg.probe(url)
        guard let video = probe.video.first, video.width > 0, video.height > 0 else {
            throw FFmpegError.failed("This file couldn’t be read as an image.")
        }
        let ext = url.pathExtension.lowercased()
        let orientation = (ext == "jpg" || ext == "jpeg") ? jpegOrientation(of: url) : 1
        if (5...8).contains(orientation) {
            return (video.height, video.width)
        }
        return (video.width, video.height)
    }

    /// EXIF orientation (1-8) of a JPEG, or 1 when the file has none or can't be parsed.
    public nonisolated static func jpegOrientation(of url: URL) -> Int {
        guard let data = try? Data(contentsOf: url), data.count > 4,
            data[0] == 0xFF, data[1] == 0xD8
        else { return 1 }
        var i = 2
        while i + 9 < data.count {
            guard data[i] == 0xFF else { return 1 }
            let marker = data[i + 1]
            if marker == 0xD9 || marker == 0xDA { return 1 }  // EOI or start of scan
            let length = Int(data[i + 2]) << 8 | Int(data[i + 3])
            guard length >= 2, i + 2 + length <= data.count else { return 1 }
            if marker == 0xE1, length > 8, data[i + 4] == 0x45, data[i + 5] == 0x78,
                data[i + 6] == 0x69, data[i + 7] == 0x66, data[i + 8] == 0x00, data[i + 9] == 0x00
            {
                if let orientation = tiffOrientation(data[(i + 10)..<(i + 2 + length)]) { return orientation }
            }
            i += 2 + length
        }
        return 1
    }

    private static func tiffOrientation(_ exif: Data) -> Int? {
        // Data slices keep the original's indices; this parser counts from 0.
        let exif = exif.startIndex == 0 ? exif : Data(exif)
        guard exif.count > 8 else { return nil }
        let little: Bool
        if exif[0] == 0x49, exif[1] == 0x49 { little = true }
        else if exif[0] == 0x4D, exif[1] == 0x4D { little = false }
        else { return nil }
        func u16(_ o: Int) -> Int {
            guard o + 1 < exif.count else { return 0 }
            return little ? Int(exif[o]) | Int(exif[o + 1]) << 8 : Int(exif[o]) << 8 | Int(exif[o + 1])
        }
        func u32(_ o: Int) -> Int {
            guard o + 3 < exif.count else { return 0 }
            return little
                ? Int(exif[o]) | Int(exif[o + 1]) << 8 | Int(exif[o + 2]) << 16 | Int(exif[o + 3]) << 24
                : Int(exif[o]) << 24 | Int(exif[o + 1]) << 16 | Int(exif[o + 2]) << 8 | Int(exif[o + 3])
        }
        guard u16(2) == 42 else { return nil }
        let ifd = u32(4)
        guard ifd + 2 < exif.count else { return nil }
        let count = u16(ifd)
        for n in 0..<count {
            let entry = ifd + 2 + n * 12
            guard entry + 12 <= exif.count else { return nil }
            if u16(entry) == 0x0112 {  // Orientation
                let value = u16(entry + 8)
                return (1...8).contains(value) ? value : 1
            }
        }
        return nil
    }
}
