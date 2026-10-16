import DeviceRuntime
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

/// Attach to Local Network and the debug port: per device, off by default, saved; turning Local Network on asks
/// macOS and opens the running device in place; a debug port only for a boot that is built, and only when on.
struct DeviceOptionsTests {
    @Test func localNetworkIsPerDeviceAndOpensTheRunningDevice() throws {
        try withTemporaryDirectory { directory in
            let link = RecordingLink()
            var asked = 0
            let options = DeviceOptions(
                settings: DeviceSettingsFile(directory: directory),
                board: "n72",
                link: { link },
                requestLocalNetworkAccess: { asked += 1 }
            )
            #expect(!options.localNetworkEnabled)
            #expect(observes({ _ = options.localNetworkEnabled }) { options.toggleLocalNetwork() })
            #expect(options.localNetworkEnabled && asked == 1 && link.commands == [.netLocalNetwork(true)])
            #expect(DeviceSettings.load(directory).localNetwork == true)
            options.toggleLocalNetwork()
            #expect(!options.localNetworkEnabled && asked == 1, "turning it off asks nothing")
            #expect(link.commands == [.netLocalNetwork(true), .netLocalNetwork(false)])
        }
    }

    @Test func aDebugPortOnlyWhenOnAndBooting() throws {
        try withTemporaryDirectory { directory in
            let options = DeviceOptions(
                settings: DeviceSettingsFile(directory: directory),
                board: "n72",
                link: { nil },
                requestLocalNetworkAccess: {}
            )
            #expect(options.chooseDebugPort(booting: true) == nil && options.lldbAttachCommand == nil, "off by default")
            options.toggleDebugPort()
            #expect(options.debugPortEnabled && DeviceSettings.load(directory).debugPort == true)
            #expect(options.chooseDebugPort(booting: false) == nil, "no boot, no port")
            let port = try #require(options.chooseDebugPort(booting: true))
            #expect(
                options.debugPort == port
                    && options.lldbAttachCommand == DebugPort.lldbCommand(board: "n72", port: port)
            )
            options.toggleDebugPort()
            #expect(options.debugPort == port, "read at each start: this boot keeps its port")
        }
    }

    @Test func bootArgumentsFollowTheAppSettings() throws {
        let suite = "ltm-tests-boot-args-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DeviceOptions.bootArgs(defaults) == "amfi_allow_any_signature=1 cs_enforcement_disable=1")
        defaults.set(true, forKey: DeviceOptions.verboseBootDefaultsKey)
        #expect(DeviceOptions.bootArgs(defaults) == "amfi_allow_any_signature=1 cs_enforcement_disable=1 -v")
        defaults.set(true, forKey: DeviceOptions.kernelConsoleDefaultsKey)
        #expect(
            DeviceOptions.bootArgs(defaults)
                == "amfi_allow_any_signature=1 cs_enforcement_disable=1 -v serial=3 debug=0x8"
        )
    }
}
