// swift-tools-version: 6.0
// The build's own tools (scripts/ltm-build runs them): scripts/vendor, the Mach-O closure check of the native builds
// (ReleaseChecks' MachOClosure), the universal merge of per-architecture native roots, and the pinned dependency
// sources (fetch, stage-git, note) with the native and static build records.
import PackageDescription

let package = Package(
    name: "BuildTools",
    products: [.executable(name: "ltm-build", targets: ["ltm-build"])],
    dependencies: [
        .package(path: "../ReleaseChecks"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.1"),
    ],
    targets: [
        .target(
            name: "BuildTools",
            dependencies: [
                .product(name: "ReleaseChecks", package: "ReleaseChecks"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "ltm-build",
            dependencies: ["BuildTools", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(
            name: "BuildToolsTests",
            dependencies: ["BuildTools", .product(name: "ReleaseChecks", package: "ReleaseChecks")]
        ),
    ]
)
