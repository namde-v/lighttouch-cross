// Music-library tag readers without AVFoundation: ID3v2 (MP3, raw ADTS AAC)
// and iTunes `ilst` atoms (M4A). Covers what MediaSong.tags(of:) mapped from
// AVMetadataItem: the iTunes/ID3 text frames, track/disk pairs, the TCMP/cpil
// compilation flag, the genre index, and the front-cover bytes (APIC/covr).
// Unknown frames are skipped; an absent or malformed tag is empty metadata,
// never an error — unreadable art is dropped, never the song.
import Foundation

/// Every tag the device's Music library keeps, plus the front cover's bytes.
/// Keys are the metadata plist's (itmedia maps them onto MusicLibrary's item
/// properties). `source`: the staged audio file; `container`: its extension.
public nonisolated enum MediaTagParsers {
    public static func parse(source: URL, container: String) -> ([String: Any], Data?) {
        switch container {
        case "m4a": return parseMP4(source)
        case "mp3", "aac", "wav": return parseID3v2(source)
        default: return ([:], nil)
        }
    }

    // MARK: - ID3v2

    private static func parseID3v2(_ url: URL) -> ([String: Any], Data?) {
        guard let data = try? Data(contentsOf: url), data.count > 10,
            data[0] == 0x49, data[1] == 0x44, data[2] == 0x33  // "ID3"
        else { return ([:], nil) }
        let size = [data[6], data[7], data[8], data[9]].reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
        guard size > 0, data.count >= 10 + size else { return ([:], nil) }
        let tag = data[10..<min(10 + size, data.count)]
        var properties: [String: Any] = [:]
        var cover: Data?
        var i = tag.startIndex
        func text(_ body: Data) -> String? {
            guard let encoding = body.first else { return nil }
            let payload = body.dropFirst()
            let raw: String?
            switch encoding {
            case 0: raw = String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self)
            case 1, 2:
                // UTF-16 with or without a BOM.
                var bytes = Array(payload)
                let little: Bool
                if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE { little = true; bytes.removeFirst(2) }
                else if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { little = false; bytes.removeFirst(2) }
                else { little = true }
                var units: [UInt16] = []
                var j = 0
                while j + 1 < bytes.count {
                    let u = little ? UInt16(bytes[j]) | UInt16(bytes[j + 1]) << 8
                        : UInt16(bytes[j]) << 8 | UInt16(bytes[j + 1])
                    if u == 0 { break }
                    units.append(u)
                    j += 2
                }
                raw = String(decoding: units, as: UTF16.self)
            case 3: raw = String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self)
            default: return nil
            }
            let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.utf8.count > 4096 ? nil : trimmed
        }
        func pair(_ value: String?) -> (Int, Int)? {
            guard let value else { return nil }
            let parts = value.split(separator: "/", maxSplits: 1).map {
                Int($0.trimmingCharacters(in: .whitespaces)) ?? 0
            }
            return (parts[0], parts.count > 1 ? parts[1] : 0)
        }
        func set(_ key: String, _ value: Any?) {
            if let value, properties[key] == nil { properties[key] = value }
        }
        func setPair(_ keys: (String, String), _ value: (Int, Int)?) {
            guard let (number, count) = value else { return }
            if (1...65535).contains(number) { set(keys.0, number) }
            if (1...65535).contains(count) { set(keys.1, count) }
        }
        while i + 10 <= tag.endIndex {
            let id = String(decoding: tag[i..<i + 4], as: UTF8.self)
            guard id.allSatisfy({ $0.isLetter || $0.isNumber }) else { break }  // padding
            let size = Int(tag[i + 4]) << 24 | Int(tag[i + 5]) << 16 | Int(tag[i + 6]) << 8 | Int(tag[i + 7])
            guard size >= 0, i + 10 + size <= tag.endIndex else { break }
            let body = tag[(i + 10)..<(i + 10 + size)]
            switch id {
            case "TIT2": set("title", text(body))
            case "TPE1": set("artist", text(body))
            case "TALB": set("album", text(body))
            case "TPE2": set("album_artist", text(body))
            case "TCOM": set("composer", text(body))
            case "TCON": set("genre", text(body).map(MediaSong.genreName))
            case "TRCK": setPair(("track_number", "track_count"), pair(text(body)))
            case "TPOS": setPair(("disc_number", "disc_count"), pair(text(body)))
            case "TYER", "TDRC":
                if let year = text(body).flatMap({ Int($0.prefix(4)) }), (1...9999).contains(year) {
                    set("year", year)
                }
            case "TCMP":
                if let flag = text(body).flatMap(Int.init) { set("compilation", flag != 0) }
            case "APIC":
                if cover == nil, body.count > 4 {
                    // encoding, MIME NUL, type, description NUL, data.
                    var j = body.startIndex + 1
                    while j < body.endIndex, body[j] != 0 { j += 1 }
                    guard j + 2 < body.endIndex else { break }
                    let encoding = body[body.startIndex]
                    j += 2  // MIME's NUL and the picture type
                    while j < body.endIndex {
                        if encoding == 1 || encoding == 2 {
                            guard j + 1 < body.endIndex else { break }
                            if body[j] == 0, body[j + 1] == 0 { j += 2; break }
                            j += 2
                        } else if body[j] == 0 { j += 1; break } else { j += 1 }
                    }
                    let bytes = body[j...]
                    if !bytes.isEmpty { cover = Data(bytes) }
                }
            default: break
            }
            i += 10 + size
        }
        return (properties, cover)
    }

    // MARK: - iTunes atoms (M4A)

    private static func parseMP4(_ url: URL) -> ([String: Any], Data?) {
        guard let data = try? Data(contentsOf: url) else { return ([:], nil) }
        // moov/udta/meta/ilst; meta is a full box (4 version/flags bytes).
        guard let moov = child(of: data, path: ["moov"]),
            let udta = child(of: moov, path: ["udta"]),
            let metaRange = childRange(of: udta, named: "meta"),
            metaRange.count > 4
        else { return ([:], nil) }
        // `meta` is a full box: its content starts with 4 version/flags bytes.
        let metaChildren = Data(udta[(metaRange.lowerBound + 4)..<metaRange.upperBound])
        guard let ilst = child(of: metaChildren, path: ["ilst"]) else { return ([:], nil) }
        var properties: [String: Any] = [:]
        var cover: Data?
        func set(_ key: String, _ value: Any?) {
            if let value, properties[key] == nil { properties[key] = value }
        }
        func setPair(_ keys: (String, String), _ bytes: Data) {
            guard bytes.count >= 6 else { return }
            let number = Int(bytes[2]) << 8 | Int(bytes[3])
            let count = Int(bytes[4]) << 8 | Int(bytes[5])
            if (1...65535).contains(number) { set(keys.0, number) }
            if (1...65535).contains(count) { set(keys.1, count) }
        }
        var i = ilst.startIndex
        while i + 8 <= ilst.endIndex {
            let size = Int(ilst[i]) << 24 | Int(ilst[i + 1]) << 16 | Int(ilst[i + 2]) << 8 | Int(ilst[i + 3])
            guard size >= 8, i + size <= ilst.endIndex else { break }
            let name = ilst[(i + 4)..<(i + 8)]
            let item = ilst[(i + 8)..<(i + size)]
            // Each item holds data atoms: size, 'data', type, locale, payload.
            var j = item.startIndex
            var texts: [String] = []
            var binaries: [Data] = []
            while j + 16 <= item.endIndex {
                let dsize = Int(item[j]) << 24 | Int(item[j + 1]) << 16 | Int(item[j + 2]) << 8 | Int(item[j + 3])
                guard dsize >= 16, j + dsize <= item.endIndex,
                    item[j + 4] == 0x64, item[j + 5] == 0x61, item[j + 6] == 0x74, item[j + 7] == 0x61
                else { break }
                let type = Int(item[j + 8]) << 24 | Int(item[j + 9]) << 16 | Int(item[j + 10]) << 8 | Int(item[j + 11])
                let payload = item[(j + 16)..<(j + dsize)]
                if type == 1, let text = String(data: payload, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty, text.utf8.count <= 4096
                {
                    texts.append(text)
                } else {
                    binaries.append(Data(payload))
                }
                // covr keeps its bytes with their kind.
                if name.elementsEqual([0x63, 0x6F, 0x76, 0x72]), cover == nil, (type == 13 || type == 14),
                    !payload.isEmpty
                {
                    cover = Data(payload)
                }
                j += dsize
            }
            let text = texts.first
            switch name.map({ $0 }) {
            case [0xA9, 0x6E, 0x61, 0x6D]: set("title", text)  // ©nam
            case [0xA9, 0x41, 0x52, 0x54]: set("artist", text)  // ©ART
            case [0xA9, 0x61, 0x6C, 0x62]: set("album", text)  // ©alb
            case [0x61, 0x41, 0x52, 0x54]: set("album_artist", text)  // aART
            case [0xA9, 0x77, 0x72, 0x74]: set("composer", text)  // ©wrt
            case [0xA9, 0x67, 0x65, 0x6E]: set("genre", text)  // ©gen
            case [0xA9, 0x64, 0x61, 0x79]:  // ©day
                if let year = text.flatMap({ Int($0.prefix(4)) }), (1...9999).contains(year) { set("year", year) }
            case [0x74, 0x72, 0x6B, 0x6E]:  // trkn
                if let binary = binaries.first { setPair(("track_number", "track_count"), binary) }
            case [0x64, 0x69, 0x73, 0x6B]:  // disk
                if let binary = binaries.first { setPair(("disc_number", "disc_count"), binary) }
            case [0x63, 0x70, 0x69, 0x6C]:  // cpil
                if let binary = binaries.first, !binary.isEmpty {
                    let flag = binary.count == 1 ? Int(binary[0]) : Int(text ?? "") ?? 0
                    set("compilation", flag != 0)
                } else if let flag = text.flatMap(Int.init) {
                    set("compilation", flag != 0)
                }
            default: break
            }
            i += size
        }
        return (properties, cover)
    }

    // MARK: - Atom walking

    /// The bytes of the nested box at `path` (e.g. ["moov"]), or nil.
    static func child(of data: Data, path: [String]) -> Data? {
        var current = data
        for name in path {
            guard let range = childRange(of: current, named: name) else { return nil }
            current = current[range]
        }
        return current
    }

    /// The content range (past the 8-byte header) of the first child box named `name`.
    static func childRange(of data: Data, named name: String) -> Range<Data.Index>? {
        let target = Array(name.utf8)
        guard target.count == 4 else { return nil }
        var i = data.startIndex
        while i + 8 <= data.endIndex {
            let size = Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
            guard size >= 8, i + size <= data.endIndex else { return nil }
            if [data[i + 4], data[i + 5], data[i + 6], data[i + 7]].elementsEqual(target) {
                return (i + 8)..<(i + size)
            }
            i += size
        }
        return nil
    }
}
