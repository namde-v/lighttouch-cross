// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeviceRuntime",
    products: [.library(name: "DeviceRuntime", type: .static, targets: ["DeviceRuntime"])],
    dependencies: [
        .package(path: "../HostRuntime"),
        // WebProxyCA's RSA-2048 keygen and SHA-1 signing (Security.framework is Apple-only).
        .package(url: "https://github.com/namde-v/swift-crypto.git", branch: "windows-msvc-fix"),
    ],
    targets: [
        // POSIX shm hello (SCM_RIGHTS), status-block atomics, posix_spawn.
        .target(name: "LTMShm", publicHeadersPath: "."),
        .target(
            name: "DeviceRuntime",
            dependencies: [
                "HostRuntime",
                "LTMShm",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .executableTarget(name: "RendezvousTestPeer", dependencies: ["DeviceRuntime"]),
        .testTarget(
            name: "DeviceRuntimeTests",
            dependencies: ["DeviceRuntime", "RendezvousTestPeer", "LTMShm"]
        ),
    ]
)
