import Foundation
import Testing

@testable import FirmwareKit

struct CatalogTests {
    @Test func lookupRequiresOneEntryAndKnownFormat() throws {
        let entry = try FirmwareEntry.load(id: "k48ap-7B500", fromCatalog: Oracle.catalog)
        #expect(entry.board == "k48ap" && entry.build == "7B500")
        #expect(throws: FirmwareError.self) {
            try FirmwareEntry.load(id: "unknown", fromCatalog: Oracle.catalog)
        }
        try Oracle.withTemp { dir in
            let url = dir.appendingPathComponent("catalog.json")
            struct Catalog: Encodable {
                var format: Int
                var entries: [FirmwareEntry]
            }
            for invalid in [Catalog(format: 1, entries: [entry, entry]), Catalog(format: 2, entries: [entry])] {
                try JSONEncoder().encode(invalid).write(to: url)
                #expect(throws: FirmwareError.self) {
                    try FirmwareEntry.load(id: entry.id, fromCatalog: url)
                }
            }
        }
    }

    /// Every iPod touch 4G and iPhone 4 row composites through the GL bridge: with ca_ogl off CoreAnimation draws in
    /// software, which on these Retina panels scrolls at a fraction of the frame rate (6.0 beta 1 shipped that way).
    @Test func retinaRowsCompositeThroughTheGLBridge() throws {
        struct Catalog: Decodable { var entries: [FirmwareEntry] }
        let entries = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: Oracle.catalog)).entries
        let retina = entries.filter { ["n81ap", "n90ap"].contains($0.board) }
        #expect(retina.count > 100)
        let software = retina.filter { $0.recipe?.options["ca_ogl"] != true }.map(\.id)
        #expect(software.isEmpty, "\(software)")
    }

    @Test func sharedWireKeepsMetadataAndFutureTags() throws {
        let original = try Oracle.entry("k48ap-7B500")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        object["released"] = "2011-06-07"
        object["prerelease"] = "future-preview"
        object["prerelease_number"] = 4
        object["status"] = "future-status"
        var source = object["source"] as! [String: Any]
        source["resource"] = "embedded.ipsw"
        object["source"] = source
        var recipe = object["recipe"] as! [String: Any]
        recipe["boot"] = "kboot"
        recipe["keybag_ramdisk_from"] = "k48ap-sibling"
        object["recipe"] = recipe
        try Oracle.withTemp { dir in
            let url = dir.appendingPathComponent("entry.json")
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            let entry = try FirmwareEntry.load(from: url)
            #expect(entry.status == "future-status" && entry.prerelease == "future-preview")
            #expect(entry.source.resource == "embedded.ipsw" && entry.recipe?.boot == "kboot")
            let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! NSDictionary
            #expect(again == object as NSDictionary)
        }
    }
}
