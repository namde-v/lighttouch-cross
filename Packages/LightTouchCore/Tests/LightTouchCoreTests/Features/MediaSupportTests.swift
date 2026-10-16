import Foundation
import Testing

@testable import LightTouchCore

/// Which libraries each catalog firmware may add media to (MediaSupport), against the builds the guest helpers have
/// been verified on (qemu-ios contrib/it-media/README.md and its booted round trips). Fails when an unverified
/// firmware is offered an import, a verified one is refused, or the refusal loses its plain words.
struct MediaSupportTests {
    /// Every catalog entry's verified destinations; anything not listed takes none. Booted round trips
    /// (the former live media check): 7D11, 7E18 and 7B367; 7C145, 7B405 and 7B500 share their 3.x services.
    /// Music on the iPad's 5.1.1 (9B206) through ML3's importer; other 5.x builds have not been round-tripped.
    /// 4.2.1 (both boards) fails (it-media README), so 4.x stays refused.
    static let verified: [String: Set<String>] = [
        "n72ap-7E18": ["Music", "Videos", "Photos"],
        "n72ap-7C145": ["Music", "Photos"], "n72ap-7D11": ["Music", "Photos"],
        "k48ap-7B367": ["Music", "Photos"], "k48ap-7B405": ["Music", "Photos"], "k48ap-7B500": ["Music", "Photos"],
        "k48ap-9B206": ["Music"],
    ]
    static let nouns = ["Music": "music", "Videos": "videos", "Photos": "photos"]

    struct Entry: Decodable {
        let id: String
        let version: String
        let media: [String]?
        let prerelease: String?
    }
    struct Catalog: Decodable { let entries: [Entry] }

    @Test func everyCatalogFirmware() throws {
        let entries = try JSONDecoder().decode(
            Catalog.self,
            from: Data(
                contentsOf: repositoryRoot.appendingPathComponent("LightTouchMac/Resources/firmware-catalog.json")
            )
        ).entries
        #expect(entries.count > 10)
        #expect(Set(Self.verified.keys).isSubset(of: Set(entries.map(\.id))), "a verified firmware left the catalog")
        for entry in entries {
            let firmware = MediaSupport.Firmware(
                version: entry.version,
                name: "iOS \(entry.version)",
                media: entry.media ?? [],
                prerelease: entry.prerelease != nil
            )
            let want = Self.verified[entry.id] ?? []
            for destination in ["Music", "Videos", "Photos"] {
                #expect(
                    MediaSupport.supports(destination, on: firmware) == want.contains(destination),
                    "\(entry.id) \(destination)"
                )
                #expect(
                    MediaSupport.refusal(destination, on: firmware)
                        == (want.contains(destination)
                            ? nil : "Adding \(Self.nouns[destination]!) isn’t supported on iOS \(entry.version) yet."),
                    "\(entry.id) \(destination)"
                )
            }
            #expect(MediaSupport.supportsAny(firmware) == !want.isEmpty, "\(entry.id): Import Media…")
        }
    }
}
