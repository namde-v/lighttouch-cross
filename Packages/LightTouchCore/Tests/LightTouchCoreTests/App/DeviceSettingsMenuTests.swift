import Foundation
import Testing

@testable import LightTouchCore

/// The Device menu's settings items: rotation applies at once; internet access and the debug port show a choice the
/// running device doesn't have yet in the tooltip, never the title; Local Network is named for the device.
struct DeviceSettingsMenuTests {
    let iPod = DeviceSettingsMenu.Device(marketingName: "iPod touch (2nd generation)", shortName: "iPod")

    @Test func automaticRotationShowsTheDevicesSetting() {
        var device = iPod
        #expect(
            DeviceSettingsMenu(device: device, desiredNetwork: true).validate(.autoRotate)
                == .init(isEnabled: true, isOn: true)
        )
        device.autoRotateEnabled = false
        #expect(
            DeviceSettingsMenu(device: device, desiredNetwork: true).validate(.autoRotate)
                == .init(isEnabled: true, isOn: false)
        )
        #expect(!DeviceSettingsMenu(device: nil, desiredNetwork: true).validate(.autoRotate).isEnabled)
    }

    @Test func internetChoicePendingUntilTheNextOpen() throws {
        let domain = "ltm-settings-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var device = iPod
        func validation() -> DeviceSettingsMenu.Validation {
            DeviceSettingsMenu(
                device: device,
                desiredNetwork: NetworkAccessPreference.desired(running: device.network, defaults: defaults)
            ).validate(.internet)
        }
        #expect(validation() == .init(isEnabled: true, isOn: true))
        NetworkAccessPreference.toggle(running: device.network, defaults: defaults)
        #expect(
            validation()
                == .init(
                    isEnabled: true,
                    isOn: false,
                    toolTip: "Takes effect the next time Light Touch opens the iPod."
                )
        )
        NetworkAccessPreference.toggle(running: device.network, defaults: defaults)
        #expect(
            validation() == .init(isEnabled: true, isOn: true),
            "back to what the device has: no tooltip, the title untouched"
        )
        device.network = false
        defaults.removeObject(forKey: NetworkAccessPreference.key)
        #expect(validation() == .init(isEnabled: true, isOn: false))
    }

    @Test func localNetworkIsNamedForTheDevice() {
        var device = iPod
        #expect(
            DeviceSettingsMenu(device: device, desiredNetwork: true).validate(.localNetwork)
                == .init(isEnabled: true, title: "Attach iPod touch (2nd generation) to Local Network", isOn: false)
        )
        device.localNetworkEnabled = true
        #expect(DeviceSettingsMenu(device: device, desiredNetwork: true).validate(.localNetwork).isOn == true)
        #expect(
            DeviceSettingsMenu(device: nil, desiredNetwork: true).validate(.localNetwork)
                == .init(isEnabled: false, title: "Attach to Local Network", isOn: false)
        )
    }

    /// Sam, 10-07: "Attach iPad to Local Network" with a preparing iPhone selected. The window's selection wins,
    /// stopped or not; another running device is only the target with no window.
    @Test func theSettingsFollowTheSelectionNotAnotherRunningDevice() {
        #expect(DeviceSettingsMenu.target(hasWindow: true, selected: nil as String?, running: ["iPad"]) == nil)
        #expect(DeviceSettingsMenu.target(hasWindow: true, selected: "iPhone", running: ["iPad"]) == "iPhone")
        #expect(DeviceSettingsMenu.target(hasWindow: false, selected: nil as String?, running: ["iPad"]) == "iPad")
        var stopped = DeviceSettingsMenu.Device(marketingName: "iPhone 4", shortName: "iPhone")
        stopped.isRunning = false
        let menu = DeviceSettingsMenu(device: stopped, desiredNetwork: true)
        #expect(
            menu.validate(.localNetwork)
                == .init(isEnabled: true, title: "Attach iPhone 4 to Local Network", isOn: false)
        )
        #expect(!menu.validate(.autoRotate).isEnabled && !menu.validate(.debugPort).isEnabled)
    }

    @Test func debugPortFollowsTheNextStartAndOffersLLDBOnlyWithAPort() {
        var device = iPod
        func menu() -> DeviceSettingsMenu { DeviceSettingsMenu(device: device, desiredNetwork: true) }
        #expect(menu().validate(.debugPort) == .init(isEnabled: true, isOn: false))
        #expect(!menu().validate(.copyLLDBCommand).isEnabled)
        #expect(DebugPortText.state(shortName: "iPod", enabled: false, port: nil) == "Off.")
        device.debugPortEnabled = true
        #expect(
            menu().validate(.debugPort)
                == .init(isEnabled: true, isOn: true, toolTip: "Takes effect the next time the iPod starts.")
        )
        #expect(
            DebugPortText.state(shortName: "iPod", enabled: true, port: nil) == "On from the next time the iPod starts."
        )
        device.debugPort = 4321
        device.lldbAttachCommand = "lldb -o 'gdb-remote 127.0.0.1:4321' KERNELCACHE"
        #expect(DebugPortText.state(shortName: "iPod", enabled: true, port: 4321) == "On, at 127.0.0.1:4321.")
        let commands = DebugPortText.commands(port: 4321, lldbWithSymbols: device.lldbAttachCommand).map(\.1)
        #expect(
            commands.count == 3 && commands[0].contains("gdb-remote 127.0.0.1:4321")
                && commands[1] == device.lldbAttachCommand
                && commands[2].contains("target remote 127.0.0.1:4321")
        )
        #expect(DebugPortText.commands(port: 4321, lldbWithSymbols: nil).count == 2)
        #expect(
            DebugPortText.state(shortName: "iPod", enabled: false, port: 4321).hasPrefix("Off from the next start.")
        )
        #expect(menu().validate(.debugPort).toolTip == nil)
        let copy = menu().validate(.copyLLDBCommand)
        #expect(copy.isEnabled && copy.toolTip?.contains("127.0.0.1:4321") == true)
        device.debugPortEnabled = false
        #expect(menu().validate(.debugPort).toolTip == "Takes effect the next time the iPod starts.")
    }
}
