// swift-tools-version: 6.2
// LightTouchCore: the app's logic that needs no window: the device library and catalog, device records and boot
// pieces, the install and media pipelines, capture naming, the session's state machines and the input and zoom
// math. The app links it; LightTouchCoreTests (Swift Testing) is the Unit test plan's suite. Built like the app:
// MainActor by default with approachable concurrency.
import PackageDescription

let settings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "LightTouchCore",
    products: [.library(name: "LightTouchCore", type: .static, targets: ["LightTouchCore"])],
    dependencies: [
        .package(path: "../HostRuntime"),
        .package(path: "../FirmwareKit"),
        .package(path: "../DeviceServices"),
        .package(path: "../DeviceRuntime"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.0"),
        .package(url: "https://github.com/namde-v/ZIPFoundation.git", branch: "windows-msvc-fix"),
        // CryptoKit is Apple-only; swift-crypto's Crypto module is API-compatible.
        .package(url: "https://github.com/namde-v/swift-crypto.git", branch: "windows-msvc-fix"),
        // OSLog is Apple-only; swift-log carries the log calls.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        // Apple's `import System` is SDK-only; swift-system's SystemPackage is API-compatible.
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
    ],
    targets: [
        .target(
            name: "LightTouchCore",
            dependencies: [
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "FirmwareSchema", package: "FirmwareKit"),
                .product(name: "HostServiceWire", package: "DeviceServices"),
                .product(name: "HostServiceClient", package: "DeviceServices"),
                .product(name: "DeviceRuntime", package: "DeviceRuntime"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: settings
        ),
        // Gives each test process a private home and app state before any test runs.
        .target(name: "TestIsolation", path: "Tests/TestIsolation"),
        // The tests stay in the Swift 5 language mode for now (their fixtures share state across threads by design).
        .testTarget(
            name: "LightTouchCoreTests",
            dependencies: ["LightTouchCore", "TestIsolation"],
            swiftSettings: settings + [.swiftLanguageMode(.v5)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
