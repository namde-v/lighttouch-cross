import Crypto
import Foundation
import Testing

@testable import FirmwareKit

/// The built-in device's blob: pack, unpack and a fresh identity give what `create --seed` gives.
struct PreparedBaseTests {
    static let images = ["illb": Data(repeating: 0xAB, count: 0x123)]

    static func identity(_ seed: String) throws -> UnitIdentity {
        try UnitIdentity.synthesizeIPod(seed: seed, modelNumber: "MB528", regionInfo: "LL/A")
    }

    static func nor(_ seed: String) throws -> Data {
        try N72NOR.build(identity: identity(seed), images: images, types: ["illb"], wrapTypes: [])
    }

    /// A base in the shape the n72 recipe leaves, made with `seed`, its lock naming this Mac's paths as create's do.
    static func base(_ dir: URL, seed: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("nand/cs0"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4160).write(to: dir.appendingPathComponent("nand/cs0/1.page"))
        try Data("ibot".utf8).write(to: dir.appendingPathComponent("iBoot.bin"))
        try Data().write(to: dir.appendingPathComponent("empty"))
        try nor(seed).write(to: dir.appendingPathComponent("nor.bin"))
        let id = try identity(seed)
        try id.write(to: dir.appendingPathComponent("identity.json"))
        let lock: [String: Any] = [
            "board": "n72ap", "boot_strategy": "iboot",
            "identity": ["seed": seed, "udid": id.udid!, "sha256": "x"],
            "machine": [
                "aes-uid": "engine", "wifi-mac": id["wifi-mac"]!, "bt-mac": id["bt-mac"]!,
                "ecid": id["unique-chip-id"]!,
            ],
            "outputs": [
                "nor": ["path": "nor.bin", "sha256": Preparer.sha256(try nor(seed))], "nand": ["listing_sha256": "l"],
            ],
            "inputs": [
                "ipsw": ["path": "/Users/someone/Library/Caches/x/5f4f.ipsw", "sha1": "5f4f"],
                "decrypted": "/tmp/cache/abc",
                "guest_tools": "/Users/someone/out/ipad-guest-tools", "identity": "identity.json",
            ],
            "tool": ["name": "firmwarekit", "helper": "/Users/someone/app/LightTouchDevice"],
            "guest_package": [
                "seed": 15, "itpack": ["path": "/Users/someone/out/ipad-guest-tools/armv6.itpack", "sha256": "s"],
                "hooks": ["/usr/lib/libappsync.dylib"],
            ],
        ]
        try Preparer.lockData(lock).write(to: dir.appendingPathComponent("device.lock.json"))
        for name in ["nand", "nor.bin", "iBoot.bin"] { try Preparer.readOnly(dir.appendingPathComponent(name)) }
    }

    static func lock(_ dir: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("device.lock.json")))
            as! [String: Any]
    }

    @Test func reidentifiedNORIsTheBuildForThatIdentity() throws {
        #expect(try N72NOR.reidentify(Self.nor("template"), identity: Self.identity("A")) == Self.nor("A"))
        #expect(try Self.nor("A") != Self.nor("B"))
    }

    @Test func unpackGivesEachDeviceTheIdentityCreateWould() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("prepared-base-\(UUID().uuidString)")
        defer {
            _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+w", tmp.path]).waitUntilExit()
            try? FileManager.default.removeItem(at: tmp)
        }
        let template = tmp.appendingPathComponent("template")
        let blob = tmp.appendingPathComponent("base.itbase")
        try Self.base(template, seed: "lighttouch-built-in")
        try PreparedBase.pack(base: template, to: blob)
        #expect(try !Data(contentsOf: blob).contains(Data("/Users/".utf8)))

        var udids: Set<String> = []
        for seed in ["6A1F0E2B-1111-4000-8000-000000000001", "6A1F0E2B-2222-4000-8000-000000000002"] {
            let out = tmp.appendingPathComponent(seed)
            var fractions: [Double] = []
            try PreparedBase.unpack(blob, into: out) { fractions.append($0) }
            #expect(fractions.last == 1 && fractions == fractions.sorted())
            try PreparedBase.reseed(out, seed: seed)
            // What `create --seed` would have written for this seed.
            let want = tmp.appendingPathComponent("want-\(seed)")
            try Self.base(want, seed: seed)
            for name in ["identity.json", "nor.bin", "nand/cs0/1.page", "iBoot.bin", "empty"] {
                #expect(
                    try Data(contentsOf: out.appendingPathComponent(name))
                        == Data(contentsOf: want.appendingPathComponent(name)),
                    "\(name)"
                )
            }
            let got = try Self.lock(out)
            let wanted = try Self.lock(want)
            #expect(
                NSDictionary(dictionary: got["machine"] as! [String: Any])
                    == NSDictionary(dictionary: wanted["machine"] as! [String: Any])
            )
            #expect(
                NSDictionary(dictionary: got["outputs"] as! [String: Any])
                    == NSDictionary(dictionary: wanted["outputs"] as! [String: Any])
            )
            let identity = got["identity"] as! [String: Any]
            #expect(try identity["seed"] as? String == seed && identity["udid"] as? String == Self.identity(seed).udid)
            #expect(
                identity["sha256"] as? String
                    == (try Preparer.digest(out.appendingPathComponent("identity.json"), SHA256()))
            )
            #expect((got["inputs"] as! [String: Any])["guest_tools"] as? String == "ipad-guest-tools")
            #expect(
                !String(decoding: try Data(contentsOf: out.appendingPathComponent("device.lock.json")), as: UTF8.self)
                    .contains("/Users/")
            )
            let mode = { (name: String) in
                (try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent(name).path)[
                    .posixPermissions
                ] as! Int)
            }
            #expect(try mode("identity.json") == 0o600 && mode("nor.bin") == 0o444 && mode("nand/cs0") & 0o222 == 0)
            udids.insert(identity["udid"] as! String)
        }
        #expect(udids.count == 2)

        // A torn blob or a name leaving the directory is refused.
        let bytes = try Data(contentsOf: blob)
        let torn = tmp.appendingPathComponent("torn.itbase")
        try bytes.prefix(bytes.count - 40).write(to: torn)
        #expect(throws: (any Error).self) { try PreparedBase.unpack(torn, into: tmp.appendingPathComponent("torn")) }
        let index = Data(#"{"entries":[{"name":"../outside","size":0,"mode":420}]}"#.utf8)
        let escaping = tmp.appendingPathComponent("escaping.itbase")
        try
            (Data("ITPACK01".utf8) + Data([UInt8(index.count), 0, 0, 0]) + index + Data([0x78, 0x9c, 3, 0, 0, 0, 0, 1]))
            .write(to: escaping)
        #expect(throws: (any Error).self) {
            try PreparedBase.unpack(escaping, into: tmp.appendingPathComponent("escaping"))
        }
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("outside").path))
    }
}
