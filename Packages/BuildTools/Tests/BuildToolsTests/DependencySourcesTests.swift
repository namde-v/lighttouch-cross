import Foundation
import ReleaseChecks
import Testing

@testable import BuildTools

/// Archive integrity and source staging, without network or a dependency build.
struct DependencySourcesTests {
    let content = Data("fixed source archive contents".utf8)

    func fixture(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = url(MergeNative.real(files.temporaryDirectory.path)).appendingPathComponent(
            "dependency-sources-\(UUID().uuidString)"
        )
        let cache = root.appendingPathComponent("archive cache")
        let manifest = root.appendingPathComponent("dependencies.json")
        try files.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { remove(root) }
        try writeJSON(
            [
                "schema_version": 1,
                "packages": [
                    [
                        "name": "example", "groups": ["native"], "archive": "example-1.tar.gz",
                        "cache_aliases": ["example.tar.gz"], "url": "https://example.invalid/source.tar.gz",
                        "sha256": sha256Hex(content),
                    ]
                ],
            ],
            to: manifest
        )
        try body(root, cache, manifest)
    }

    func failure(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch { return "\(error)" }
    }

    @Test func cachedArchivesAreVerifiedNeverReplacedByTheNetwork() throws {
        try fixture { root, cache, manifest in
            let destination = root.appendingPathComponent("sources")
            func fetch(
                offline: Bool = true,
                download: @escaping (String, URL) throws -> Void = { _, _ in Issue.record("downloaded") }
            ) -> String? {
                failure {
                    try DependencySources.fetch(
                        manifest: manifest,
                        group: "native",
                        destination: destination,
                        caches: [cache],
                        offline: offline,
                        download: download
                    )
                }
            }
            #expect(fetch()?.contains("offline source missing") == true)
            try Data("corrupted cached bytes".utf8).write(to: cache.appendingPathComponent("example.tar.gz"))
            #expect(
                fetch(offline: false)?.contains("SHA-256 mismatch") == true,
                "a bad cache must fail, not fall back to the network"
            )
            #expect(!files.fileExists(atPath: destination.appendingPathComponent("example-1.tar.gz").path))
            try content.write(to: cache.appendingPathComponent("example.tar.gz"))
            #expect(fetch() == nil)
            #expect(try Data(contentsOf: destination.appendingPathComponent("example-1.tar.gz")) == content)
            let record = try readJSON(destination.appendingPathComponent("native-sources.json"))
            #expect(
                (record["packages"] as? [[String: Any]])?.first?["obtained_from"] as? String
                    == cache.appendingPathComponent("example.tar.gz").path
            )
            try Data("modified since last fetch".utf8).write(to: destination.appendingPathComponent("example-1.tar.gz"))
            #expect(fetch()?.contains("SHA-256 mismatch") == true, "an existing archive is verified again")
            remove(destination)
            remove(cache.appendingPathComponent("example.tar.gz"))
            #expect(
                fetch(offline: false) { _, to in try Data("wrong download".utf8).write(to: to) }?.contains(
                    "SHA-256 mismatch"
                ) == true
            )
            #expect((try? files.contentsOfDirectory(atPath: destination.path)) == [], "a bad download is removed")
        }
    }

    @Test func stagingKeepsEditsAndRefusesUntrackedSource() throws {
        try fixture { root, _, _ in
            let repository = root.appendingPathComponent("repository")
            try files.createDirectory(at: repository, withIntermediateDirectories: true)
            func git(_ arguments: String...) throws -> String {
                try output(["git", "-C", repository.path] + arguments)
            }
            _ = try git("init", "-q")
            try "*.o\nbuild/\n".write(
                to: repository.appendingPathComponent(".gitignore"),
                atomically: true,
                encoding: .utf8
            )
            try "original source\n".write(
                to: repository.appendingPathComponent("main.c"),
                atomically: true,
                encoding: .utf8
            )
            try Data("metadata".utf8).write(to: repository.appendingPathComponent(".DS_Store"))
            _ = try git("add", ".")
            _ = try git(
                "-c",
                "user.name=Source test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-qm",
                "fixture"
            )
            try "current edited source\n".write(
                to: repository.appendingPathComponent("main.c"),
                atomically: true,
                encoding: .utf8
            )
            try Data("stale build product".utf8).write(to: repository.appendingPathComponent("main.o"))
            let staged = root.appendingPathComponent("staged")
            let record = root.appendingPathComponent("staged.json")
            try DependencySources.stageGit(source: repository, destination: staged, record: record)
            #expect(
                try String(contentsOf: staged.appendingPathComponent("main.c"), encoding: .utf8)
                    == "current edited source\n"
            )
            for absent in ["main.o", ".git", ".DS_Store"] {
                #expect(!files.fileExists(atPath: staged.appendingPathComponent(absent).path), "\(absent)")
            }
            let written = try readJSON(record)
            #expect(written["modified"] as? Bool == true)
            #expect(written["commit"] as? String == (try git("rev-parse", "HEAD")))
            try "untracked source\n".write(
                to: repository.appendingPathComponent("new-feature.c"),
                atomically: true,
                encoding: .utf8
            )
            let again = root.appendingPathComponent("staged-2")
            #expect(
                failure { try DependencySources.stageGit(source: repository, destination: again, record: record) }?
                    .contains("new-feature.c") == true
            )
            #expect(!files.fileExists(atPath: again.path))
        }
    }

    @Test func noteNamesTheArchiveAndPatches() throws {
        try fixture { _, _, manifest in
            let note = try DependencySources.note(manifest: manifest, name: "example", patches: ["a.patch"])
            #expect(note.hasPrefix("example : https://example.invalid/source.tar.gz\nSHA256: \(sha256Hex(content))\n"))
            #expect(note.hasSuffix("Patches: a.patch (in this directory), applied with patch -p1"))
        }
    }
}
