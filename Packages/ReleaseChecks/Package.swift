// swift-tools-version: 6.0
// Checks of a built Light Touch.app (an archive's or an export's): signatures and entitlements per executable,
// slices and the dylib load closure, bundle hygiene, the bundled helper and services worker, and boots through the
// bundle. ReleaseChecksTests runs the fixture halves always (Unit plan) and the app halves in Release.xctestplan,
// which takes the app from LTM_RELEASE_APP or LTM_RELEASE_ARCHIVE (see CONTRIBUTING, Releases).
import PackageDescription

let package = Package(
    name: "ReleaseChecks",
    products: [.library(name: "ReleaseChecks", targets: ["ReleaseChecks"])],
    // HostRuntime (local, no dependencies of its own): the tests start the bundled helper with its HelperLaunch.
    dependencies: [
        .package(path: "../HostRuntime"),
        .package(url: "https://github.com/namde-v/swift-crypto.git", branch: "windows-msvc-fix"),
    ],
    targets: [
        .systemLibrary(name: "RCZlib", pkgConfig: "zlib"),
        .target(
            name: "ReleaseChecks",
            dependencies: ["RCZlib", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "ReleaseChecksTests",
            dependencies: ["ReleaseChecks", .product(name: "HostRuntime", package: "HostRuntime")]
        ),
    ]
)
