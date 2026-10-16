// swift-tools-version: 6.0
// The build's own tools (scripts/ltm-build runs them): scripts/vendor, the Mach-O closure check of the native builds
// (ReleaseChecks' MachOClosure), the universal merge of per-architecture native roots, and the pinned dependency
// sources (fetch, stage-git, note) with the native and static build records.
import PackageDescription

#if os(Windows)
// The ltm-build executable is excluded on Windows: it depends on the
// BuildTools library, which would force SwiftPM to build BuildTools without
// -enable-testing, breaking the @testable imports in BuildToolsTests
// (SwiftPM builds each target once per configuration). The library and its
// tests are what CI exercises.
let executableTargets: [Target] = []
let executableProducts: [Product] = []
#else
let executableTargets: [Target] = [
    .executableTarget(
        name: "ltm-build",
        dependencies: ["BuildTools", .product(name: "ArgumentParser", package: "swift-argument-parser")]
    ),
]
let executableProducts: [Product] = [.executable(name: "ltm-build", targets: ["ltm-build"])]
#endif

let package = Package(
    name: "BuildTools",
    products: executableProducts,
    dependencies: [
        .package(path: "../ReleaseChecks"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/namde-v/swift-crypto.git", branch: "windows-msvc-fix"),
    ],
    targets: [
        .target(
            name: "BuildTools",
            dependencies: [
                .product(name: "ReleaseChecks", package: "ReleaseChecks"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "BuildToolsTests",
            dependencies: ["BuildTools", .product(name: "ReleaseChecks", package: "ReleaseChecks")]
        ),
    ] + executableTargets
)
