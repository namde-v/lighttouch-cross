// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HostRuntime",
    products: [.library(name: "HostRuntime", type: .static, targets: ["HostRuntime"])],
    dependencies: [
        // CryptoKit is Apple-only; swift-crypto's Crypto module is API-compatible
        // for the SHA256 / Insecure.SHA1 uses in IPhoneIdentity.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.1"),
    ],
    targets: [
        // The platform's zlib (NSData.decompressed(using: .zlib) is
        // Compression-framework-only). Linux needs zlib1g-dev installed;
        // macOS uses the SDK's zlib.
        // Named CZlibHost: ZIPFoundation (a FirmwareKit dependency) also vends a Clang module named
        // CZlib, and module names must be unique across the package graph.
        .systemLibrary(
            name: "CZlibHost",
            providers: [.apt(["zlib1g-dev"])]
        ),
        .target(
            name: "HostRuntime",
            dependencies: [
                "CZlibHost",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "HostRuntimeTests", dependencies: ["HostRuntime"]),
    ]
)
