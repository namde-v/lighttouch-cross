// swift-tools-version: 6.0
// LTAppCore: the portable Swift app core behind the Qt UI's C ABI (ui/ABI.md).
//
// libLTAppCore.so exposes the `lt_` @_cdecl surface from ui/ABI.md, fronting the
// real view-models in the port packages (LightTouchCore et al). The Qt side
// includes Sources/LTBridgeC/include/lt_bridge.h as the contract header.
//
// Concurrency: no default MainActor isolation in this target — every @_cdecl
// export is a nonisolated top-level function. Commands hop to @MainActor via
// Task; queries read lock-protected snapshot caches; pure functions are
// lock-free value math. See ui/ABI.md §4.
import PackageDescription

let package = Package(
    name: "LTAppCore",
    products: [
        .library(name: "LTAppCore", type: .dynamic, targets: ["LTAppCore"]),
    ],
    dependencies: [
        .package(path: "../LightTouchCore"),
        .package(path: "../DeviceRuntime"),
        .package(path: "../HostRuntime"),
        .package(path: "../FirmwareKit"),
        .package(path: "../DeviceServices"),
    ],
    targets: [
        // The C contract header (ui/ABI.md §1.1): LTEvent, constants, and the
        // declarations of every lt_ export. Shipped for the Qt side to include.
        .target(
            name: "LTBridgeC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "LTAppCore",
            dependencies: [
                "LTBridgeC",
                .product(name: "LightTouchCore", package: "LightTouchCore"),
                .product(name: "DeviceRuntime", package: "DeviceRuntime"),
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "FirmwareSchema", package: "FirmwareKit"),
                .product(name: "HostServiceWire", package: "DeviceServices"),
                .product(name: "HostServiceClient", package: "DeviceServices"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "LTAppCoreTests",
            dependencies: ["LTAppCore"],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
