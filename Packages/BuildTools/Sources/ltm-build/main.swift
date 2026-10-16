// scripts/ltm-build SUBCOMMAND ...: the build's tools (Packages/BuildTools); `scripts/ltm-build help SUBCOMMAND`.
// LTM_ROOT is the repository (the wrapper sets it).
import ArgumentParser
import BuildTools
import Foundation
import ReleaseChecks

let repository = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["LTM_ROOT"] ?? FileManager.default.currentDirectoryPath
)
let dependencyManifest = repository.appendingPathComponent("build-support/dependencies.json")

func path(_ text: String) -> URL { URL(fileURLWithPath: text) }

struct LTMBuild: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ltm-build",
        subcommands: [
            VendorCommand.self, CheckMachO.self, MergeNativeCommand.self, Sources.self, StaticRecord.self,
            NativeRecord.self,
        ]
    )
}

struct VendorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "vendor", discussion: Vendor.usage)
    @Flag(help: "Print the vendor directory for the current pins.") var print = false

    func run() throws {
        let vendor = Vendor(root: repository)
        Swift.print(try print ? vendor.directory().path : vendor.build().path)
    }
}

struct CheckMachO: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-macho",
        abstract: "Every slice's macOS load closure."
    )
    @Option var minos = "14.0"
    @Option(help: "Default: every slice.") var arch: [String] = []
    @Flag var noWeakImports = false
    @Argument(transform: path) var files: [URL]

    func run() throws {
        for file in files {
            for arch in arch.isEmpty ? try MachOClosure.architectures(file) : arch {
                for binary in try MachOClosure.check(file, minimum: minos, arch: arch, noWeakImports: noWeakImports) {
                    print("\(arch): \(binary.path)")
                }
            }
        }
    }
}

struct MergeNativeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge-native",
        abstract: "Per-architecture native roots into one universal root."
    )
    @Argument(transform: path) var output: URL
    @Argument(transform: path) var roots: [URL]

    func run() throws { try MergeNative.merge(output: output, roots: roots) }
}

struct Sources: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources",
        abstract: "The pinned dependency sources.",
        subcommands: [Fetch.self, StageGit.self, Note.self]
    )

    struct Fetch: ParsableCommand {
        @Option var group: String
        @Option(transform: path) var destination: URL
        @Option(transform: path) var cache: [URL] = []
        @Flag var offline = false
        @Option(transform: path) var manifest: URL?

        func run() throws {
            try DependencySources.fetch(
                manifest: manifest ?? dependencyManifest,
                group: group,
                destination: destination,
                caches: cache,
                offline: offline
            )
        }
    }

    struct StageGit: ParsableCommand {
        @Option(transform: path) var source: URL
        @Option(transform: path) var destination: URL
        @Option(transform: path) var record: URL

        func run() throws { try DependencySources.stageGit(source: source, destination: destination, record: record) }
    }

    struct Note: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "A shipped package's SOURCE.txt.")
        @Argument var name: String
        @Argument var patches: [String] = []
        @Option(transform: path) var manifest: URL?

        func run() throws {
            print(try DependencySources.note(manifest: manifest ?? dependencyManifest, name: name, patches: patches))
        }
    }
}

struct StaticRecord: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "build-static-deps.sh's static-build.json.")
    @Argument(transform: path) var root: URL
    @Argument var arch: String

    func run() throws { try Records.writeStatic(source: repository, root: root, arch: arch) }
}

struct NativeRecord: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "build-package-native.sh's native-build.json.")
    @Argument(transform: path) var root: URL
    @Argument(transform: path) var staticPrefix: URL
    @Argument(transform: path) var qemu: URL
    @Argument(transform: path) var usbmuxd: URL
    @Argument var arch: String

    func run() throws {
        try Records.writeNative(
            source: repository,
            root: root,
            staticPrefix: staticPrefix,
            qemu: qemu,
            usbmuxd: usbmuxd,
            arch: arch
        )
    }
}

LTMBuild.main()
