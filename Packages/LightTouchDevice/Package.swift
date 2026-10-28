// swift-tools-version: 6.0
// LightTouchDevice: the device helper the app and firmwarekit launch per emulated device.
// Imported from upstream samhenrigold/LightTouchMac @ 5fc764d6 (top-level LightTouchDevice/,
// an Xcode target upstream, not a SwiftPM package) onto branch win/w-device-helper.
// The helper runs one emulated device per process: its one argument is its launch
// (HostRuntime HelperLaunch) as JSON, with modes connect (DeviceLink), headless,
// oneshot (firmwarekit's preparation boots) and machines (list the emulator's machines).
// It dlopen's libqemu-arm.dylib (Qemu.swift) and serves the web proxy (WebProxy.swift),
// so it depends on DeviceRuntime + HostRuntime. The C GuestTLS helper (SecureTransport
// TLS toward the guest) lives in its own target, following the port's LTMShm pattern.
import PackageDescription

let package = Package(
    name: "LightTouchDevice",
    products: [
        .executable(name: "LightTouchDevice", targets: ["LightTouchDevice"]),
    ],
    dependencies: [
        .package(path: "../DeviceRuntime"),
        .package(path: "../HostRuntime"),
    ],
    targets: [
        .executableTarget(
            name: "LightTouchDevice",
            dependencies: [
                "CGuestTLS",
                .product(name: "DeviceRuntime", package: "DeviceRuntime"),
                .product(name: "HostRuntime", package: "HostRuntime"),
            ]
        ),
        .target(name: "CGuestTLS", publicHeadersPath: "."),
    ]
)
