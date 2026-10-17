// swift-tools-version: 6.0
// FirmwareKit: IPSW -> emulated device preparation.
// Swift owns device preparation. Tests use frozen reference hashes and
// optional corpus inputs; strict acceptance fails when selected prerequisites are absent. Each module lives in its own
// subdirectory of Sources/FirmwareKit so agents can add modules without editing this file.
//
// Dependencies are pinned to exact versions and recorded with their licenses in build-support/dependencies.json
// (BuildTools' dependency sources manifest): ZIPFoundation (IPSW members), MachOKit (Mach-O headers, fat
// files, code signatures), swift-subprocess (`diskutil image` / `hdiutil` through DiskImage), Unrar.swift (a "rar"
// source's IPSW: RARLAB's UnRAR, extraction only), swift-argument-parser (the firmwarekit command
// lines, FirmwareSchema's FirmwareCommand).
//
// Linux port notes (see SHIM_NOTES.md): CryptoKit -> swift-crypto's Crypto
// (+ _CryptoExtras for AES._CBC, replacing CommonCrypto's CCCrypt/CCHmac);
// `import System` -> swift-system's SystemPackage; bare `import zlib` /
// `import SQLite3` -> CZlib / CSQLite3 system-library targets below.
import PackageDescription

#if os(Windows)
// The firmwarekit executable is excluded on Windows: it depends on the
// FirmwareKit library, which would force SwiftPM to build FirmwareKit without
// -enable-testing, breaking the @testable imports in FirmwareKitTests
// (SwiftPM builds each target once per configuration). The library and its
// tests are what CI exercises.
let executableTargets: [Target] = []
let executableProducts: [Product] = []
#else
let executableTargets: [Target] = [
    .executableTarget(
        name: "FirmwareKitCLI",
        dependencies: [
            "FirmwareKit",
            .product(name: "HostRuntime", package: "HostRuntime"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),
]
let executableProducts: [Product] = [
    .executable(name: "firmwarekit", targets: ["FirmwareKitCLI"]),
]
#endif

let package = Package(
    name: "FirmwareKit",
    products: [
        .library(name: "FirmwareKit", targets: ["FirmwareKit"]),
        .library(name: "FirmwareSchema", type: .static, targets: ["FirmwareSchema"]),
    ] + executableProducts,
    dependencies: [
        .package(path: "../HostRuntime"),
        .package(url: "https://github.com/namde-v/ZIPFoundation.git", branch: "windows-msvc-fix"),
        .package(url: "https://github.com/p-x9/MachOKit.git", exact: "0.53.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.0"),
        .package(url: "https://github.com/namde-v/Unrar.swift.git", branch: "windows-msvc-fix"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        // CryptoKit is Apple-only; swift-crypto's Crypto module is API-compatible
        // for the SHA256 / Insecure.SHA1 uses, and _CryptoExtras provides AES._CBC
        // (replacing CommonCrypto's CCCrypt AES-CBC and CCHmac-SHA1).
        // NOTE (swift-crypto identity): MachOKit 0.53.0 also depends on
        // swift-crypto, but via github.com/apple/swift-crypto, while we pin
        // github.com/namde-v/swift-crypto (Windows MSVC fixes). SwiftPM derives
        // the same package identity ("swift-crypto") from both URLs and warns
        // "Conflicting identity" (escalates to an error in a future SwiftPM).
        // Benign today: the branch requirement wins, so SwiftPM resolves ONE
        // checkout (this fork, windows-msvc-fix) that both consumers link
        // against -- Linux and Windows builds prove it. SwiftPM has no
        // dependency-override/alias API for source-control deps, so the only
        // Package.swift-level cure is a namde-v/MachOKit fork whose
        // swift-crypto URL points at namde-v/swift-crypto (or upstreaming the
        // Windows fixes to apple/swift-crypto). Deferred: zero functional gain
        // today, and a fourth fork adds sync maintenance.
        .package(url: "https://github.com/namde-v/swift-crypto.git", branch: "windows-msvc-fix"),
        // Apple's `import System` is SDK-only; swift-system's SystemPackage
        // provides FilePath/FilePermissions/Arguments on Linux.
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
    ],
    targets: [
        .target(
            name: "FirmwareSchema",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        .target(name: "CActivation", cSettings: [.define("LT_ACTIVATION_LIBRARY")]),
        // The platform's zlib (the Compression framework is Apple-only).
        // Linux needs zlib1g-dev installed; macOS uses the SDK's zlib.
        // Named CZlibFK: HostRuntime already vends a CZlib target and target
        // names must be unique across the package graph.
        .systemLibrary(
            name: "CZlibFK",
            providers: [.apt(["zlib1g-dev"])]
        ),
        // The platform's SQLite (the SQLite3 Swift overlay is Apple-only).
        // Linux needs libsqlite3-dev installed.
        .systemLibrary(
            name: "CSQLite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "FirmwareKit",
            dependencies: [
                "CActivation", "FirmwareSchema",
                // CZlibFK/CSQLite3 only where zlib/SQLite exist: their modulemaps'
                // link directives break the Windows link (no z.lib/sqlite3.lib).
                // Imports are gated with #if !os(Windows) to match.
                .target(name: "CZlibFK", condition: .when(platforms: [.macOS, .linux])),
                .target(name: "CSQLite3", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "MachOKit", package: "MachOKit", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "Subprocess", package: "swift-subprocess"),
                // Unrar only where its C++ links: the Windows MSVC build has
                // undefined symbols (MarkOfTheWeb etc.); RARSource is gated out there.
                .product(name: "Unrar", package: "Unrar.swift", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        .testTarget(
            name: "FirmwareKitTests",
            dependencies: [
                "FirmwareKit", "FirmwareSchema",
                .target(name: "CZlibFK", condition: .when(platforms: [.macOS, .linux])),
                .target(name: "CSQLite3", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ] + executableTargets
)
