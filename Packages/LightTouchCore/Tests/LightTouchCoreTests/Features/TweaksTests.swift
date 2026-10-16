import Foundation
import Testing

@testable import LightTouchCore

/// Tweaks: which firmware each switch works on (and why not elsewhere), the keys it means there, what turning one off
/// removes, the status bar override's per-version layout, the settings' persistence, and the apply against a fake
/// guest: the plist written as mobile's, SpringBoard restarted only for its domains, the agent's live ops.
@Suite(.serialized) struct TweaksTests {
    init() { TweakApplier.respringPause = .milliseconds(1) }

    @Test func eachTweakWorksOnItsVersionsOnly() {
        func ok(_ t: Tweak, _ v: String, tools: Bool = true, pinned: Bool = false) -> Bool {
            t.isAvailable(version: v, guestTools: tools, clockPinned: pinned)
        }
        #expect(ok(.keynoteClock, "3.1.3") && ok(.keynoteClock, "4.0") && !ok(.keynoteClock, "4.2.1"))
        #expect(ok(.emojiEverywhere, "4.2.1") && !ok(.emojiEverywhere, "5.1.1") && !ok(.emojiEverywhere, "2.1"))
        #expect(ok(.slowAnimations, "3.0") && !ok(.slowAnimations, "2.2.1") && ok(.slowAnimations, "7.1.2"))
        #expect(ok(.developerSettings, "6.1.6") && ok(.developerSettings, "4.2.1") && !ok(.developerSettings, "4.0"))
        #expect(ok(.cleanStatusBar, "4.2.1") && ok(.cleanStatusBar, "7.1.2") && !ok(.cleanStatusBar, "4.0"))
        #expect(!ok(.cleanStatusBar, "6.0"), "a layout nobody read")
        #expect(!ok(.signalNumbers, "1.0", tools: false) && ok(.timeMachine, "1.0", tools: false))
        #expect(!ok(.timeMachine, "6.0", pinned: true), "a beta's own pinned clock wins")
    }

    /// A guest root holding a developer-disk-images/<minor>/ pair for each of `minors`.
    func developerImages(in dir: URL, _ minors: [String]) throws -> URL {
        let guest = dir.appendingPathComponent("guest")
        for minor in minors {
            let folder = guest.appendingPathComponent("developer-disk-images/\(minor)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["DeveloperDiskImage.dmg", "DeveloperDiskImage.dmg.signature"] {
                try Data().write(to: folder.appendingPathComponent(name))
            }
        }
        return guest
    }

    @Test func developerImagePicksTheVersionsMinor() throws {
        try withTemporaryDirectory { dir in
            let guest = try developerImages(in: dir, ["4.2", "5.1", "7.0", "7.1"])
            func pick(_ version: String) -> String? {
                DeveloperDiskImage.image(version: version, in: guest)?.deletingLastPathComponent().lastPathComponent
            }
            #expect(pick("4.2.1") == "4.2" && pick("4.2") == "4.2", "4.2.1 and the 4.2 betas")
            #expect(pick("5.1.1") == "5.1" && pick("7.0") == "7.0" && pick("7.1.2") == "7.1")
            #expect(pick("4.1") == nil && pick("6.1.6") == nil, "no image for the minor")
            #expect(DeveloperDiskImage.image(version: "7.1.2", in: nil) == nil, "a build without the guest archive")
            try FileManager.default.removeItem(
                at: guest.appendingPathComponent("developer-disk-images/5.1/DeveloperDiskImage.dmg.signature")
            )
            #expect(pick("5.1.1") == nil, "no signature beside it")
        }
    }

    @Test func captionsAreTheKeys() {
        #expect(Tweak.signalNumbers.caption(version: "3.1.3") == "SBShowRSSI, SBShowGSMRSSI")
        #expect(Tweak.emojiEverywhere.caption(version: "6.1.6") == "KeyboardEmojiEverywhere", "the same when disabled")
        #expect(Tweak.safariDebug.caption(version: "5.1.1") == "com.apple.mobilesafari ConsoleEnabled")
        #expect(Tweak.safariDebug.caption(version: "6.1.6") == "com.apple.webinspectord RemoteInspectorEnabled")
        #expect(Tweak.timeMachine.caption(version: "4.2.1") == "rtc-epoch")
        #expect(Tweak.timeMachine.caption(version: "7.1.2") == "rtc-epoch")
    }

    @Test func theKeysFollowTheFirmware() {
        var s = TweakSettings()
        s.on = [.signalNumbers, .keynoteClock, .slowAnimations, .emojiEverywhere, .safariDebug]
        let ids = { (v: String) in s.defaults(version: v).map(\.id) }
        #expect(
            ids("4.0") == [
                "com.apple.springboard SBShowRSSI", "com.apple.springboard SBShowGSMRSSI",
                "com.apple.springboard SBFakeTime", "com.apple.UIKit UIAnimationDragCoefficient",
                "com.apple.Preferences KeyboardEmojiEverywhere", "com.apple.mobilesafari ConsoleEnabled",
            ]
        )
        #expect(
            ids("6.1.6") == [
                "com.apple.springboard SBShowRSSI", "com.apple.springboard SBShowGSMRSSI",
                "com.apple.UIKit UIAnimationDragCoefficient", "com.apple.webinspectord RemoteInspectorEnabled",
            ],
            "no keynote clock or emoji switch there; Safari's switch is the Web Inspector"
        )
        #expect(
            s.defaults(version: "6.1.6").first { $0.key == "UIAnimationDragCoefficient" }?.value == .int(10),
            "an integer: CFPreferencesGetAppIntegerValue reads a real as 0"
        )
    }

    @Test func timeMachineLeavesNetworkTimeOn() async throws {
        // The machine's network answers NTP in its clock: timed keeps automatic time and zone, so the zone follows.
        var s = TweakSettings()
        s.on = [.timeMachine]
        for version in ["4.3.3", "5.1.1", "6.1.6", "7.1.2"] {
            #expect(s.defaults(version: version).isEmpty, "\(version)")
        }
        // What an earlier Time Machine wrote goes, and timed restarts to read it.
        s.written = [
            "com.apple.timed TMAutomaticTimeEnabled", "com.apple.timed TMAutomaticTimeOnlyEnabled",
            "com.apple.timed DisableAutomaticTime",
        ]
        let changes = s.changes(version: "7.1.2")
        #expect(changes.map(\.id) == s.written && changes.allSatisfy { $0.value == nil })
        let link = FakeGuestLink()
        let timed = "/var/mobile/Library/Preferences/com.apple.timed.plist"
        link.files[timed] = try PropertyListSerialization.data(
            fromPropertyList: [
                "TMAutomaticTimeEnabled": false, "TMAutomaticTimeOnlyEnabled": false, "DisableAutomaticTime": true,
                "TMAutomaticTimeZoneEnabled": true,
            ],
            format: .binary,
            options: 0
        )
        let guest = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
        let applied = try await TweakApplier.apply(s, version: "7.1.2", guest: guest, again: false)
        #expect(applied.written.isEmpty && !applied.resprung)
        let left = try PropertyListSerialization.propertyList(from: link.files[timed]!, format: nil) as? [String: Bool]
        #expect(left == ["TMAutomaticTimeZoneEnabled": true], "only Time Machine's keys go")
        #expect(link.spawns == [["/bin/launchctl", "stop", "com.apple.timed"]], "timed rereads")
    }

    @Test func turningOffRemovesOnlyWhatItWrote() {
        var s = TweakSettings()
        s.on = [.signalNumbers]
        s.written = [
            "com.apple.springboard SBShowRSSI", "com.apple.springboard SBShowGSMRSSI",
            "com.apple.springboard SBFakeTime",
        ]
        let changes = s.changes(version: "3.1.3")
        #expect(changes.filter { $0.value == nil }.map(\.key) == ["SBFakeTime"])
        #expect(changes.filter { $0.value != nil }.map(\.key) == ["SBShowRSSI", "SBShowGSMRSSI"])
        s.on = []
        s.written = []
        #expect(s.changes(version: "3.1.3").isEmpty, "a key the user set some other way is left alone")
    }

    @Test func statusBarOverridesFollowEachUIKit() throws {
        // 7.1.2: 25 item switches, the bits at 25-26, values at 28 (UIKit's merge routine, 0x2fc7abd0).
        let d = try #require(StatusBarOverride.layout(version: "7.1.2")).clean
        #expect(d.count == 2000)
        #expect(d[25] == 0b101 && d[26] == 0b0011_0110, "time and GSM bars; Wi-Fi bars, data network, battery")
        #expect(String(decoding: d[53..<60], as: UTF8.self) == "9:41 AM")
        func int(_ at: Int) -> Int32 { d[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) } }
        #expect(int(124) == 5 && int(1560) == 3 && int(1564) == 5 && int(1568) == 100 && int(1572) == 0)
        let five = try #require(StatusBarOverride.layout(version: "5.1.1")).clean
        #expect(five.count == 2092 && five[23] == 0b101 && five[24] == 0b0110_1100)
        #expect(String(decoding: five[51..<58], as: UTF8.self) == "9:41 AM")
        #expect(StatusBarOverride.layout(version: "4.3.3")?.cleared == Data(count: 1892))
        #expect(StatusBarOverride.layout(version: "4.1") == nil && StatusBarOverride.layout(version: "7.0") == nil)
    }

    @Test func settingsPersistAndOlderOnesDecode() throws {
        var s = DeviceSettings()
        var t = TweakSettings()
        t.on = [.timeMachine, .coreAnimationColors]
        t.clock = Date(timeIntervalSince1970: 1_183_100_400)
        t.coreAnimationColor = .offscreenRendered
        t.written = ["com.apple.UIKit UIAnimationDragCoefficient"]
        s.tweaks = t
        try withTemporaryDirectory { dir in
            try s.save(dir)
            #expect(DeviceSettings.load(dir).tweaks == t)
        }
        let old = try PropertyListDecoder().decode(
            TweakSettings.self,
            from: PropertyListSerialization.data(
                fromPropertyList: ["on": ["signalNumbers", "gone"], "developerImage": "/x/DeveloperDiskImage.dmg"],
                format: .xml,
                options: 0
            )
        )
        #expect(old.on == [.signalNumbers] && old.clock == TweakSettings.macworld2007)
        #expect(t.clock(clockPinned: false) == t.clock && t.clock(clockPinned: true) == nil)
        #expect(TweakSettings().clock(clockPinned: false) == nil, "off: no clock")
    }

    @Test func applyWritesMobilesPlistAndRespringsOnlyForSpringBoard() async throws {
        let link = FakeGuestLink()
        let guest = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
        let sb = "/var/mobile/Library/Preferences/com.apple.springboard.plist"
        link.files[sb] = try PropertyListSerialization.data(
            fromPropertyList: ["SBHideACPower": true],
            format: .binary,
            options: 0
        )
        var s = TweakSettings()
        s.on = [.signalNumbers, .emojiEverywhere]
        let first = try await TweakApplier.apply(s, version: "4.2.1", guest: guest, again: false)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: link.files[sb]!, format: nil) as? [String: Bool]
        )
        #expect(plist == ["SBHideACPower": true, "SBShowRSSI": true, "SBShowGSMRSSI": true], "merged, not replaced")
        #expect(link.owners[sb] == "501:501" && link.modes[sb] == "600")
        #expect(first.resprung && link.spawns.contains(["/bin/launchctl", "stop", "com.apple.SpringBoard"]))
        #expect(first.written.count == 3)
        s.written = first.written
        link.spawns = []
        let again = try await TweakApplier.apply(s, version: "4.2.1", guest: guest, again: true)
        #expect(!again.resprung && link.spawns.isEmpty, "nothing changed: no respring")
        s.on = [.signalNumbers]
        let off = try await TweakApplier.apply(s, version: "4.2.1", guest: guest, again: true)
        #expect(!off.resprung, "Settings' domain: no respring")
        let prefs = try #require(link.files["/var/mobile/Library/Preferences/com.apple.Preferences.plist"])
        #expect(
            (try PropertyListSerialization.propertyList(from: prefs, format: nil) as? [String: Any])?.isEmpty == true
        )
    }

    @Test func liveOpsGoThroughTheAgentAndAnOldOneIsNamed() async throws {
        let link = FakeGuestLink()
        link.v4 = true
        let guest = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
        var s = TweakSettings()
        s.on = [.cleanStatusBar, .coreAnimationColors]
        _ = try await TweakApplier.apply(s, version: "6.1.6", guest: guest, again: false)
        #expect(link.statusBars == [StatusBarOverride.layout(version: "6.1.6")!.clean])
        #expect(link.caDebug == ["\(0x4 | 0x2 | 0x4000 | 0x20000 | 0x1) 4"])
        s.on = []
        _ = try await TweakApplier.apply(s, version: "6.1.6", guest: guest, again: true)
        #expect(link.statusBars.last == Data(count: 1992) && link.caDebug.last?.hasSuffix(" 0") == true, "off again")
        let fresh = FakeGuestLink()
        fresh.v4 = true
        _ = try await TweakApplier.apply(
            s,
            version: "6.1.6",
            guest: GuestServices(agent: GuestAgent(link: fresh, cache: GuestAgentCache())),
            again: false
        )
        #expect(fresh.statusBars.isEmpty && fresh.caDebug.isEmpty, "a fresh boot with them off: nothing to clear")
        let old = FakeGuestLink()
        s.on = [.cleanStatusBar]
        let result = try await TweakApplier.apply(
            s,
            version: "6.1.6",
            guest: GuestServices(agent: GuestAgent(link: old, cache: GuestAgentCache())),
            again: false
        )
        #expect(result.missing == [.cleanStatusBar] && !old.ops.contains("statusbar"))
    }

    @Test func hiddenAppsAreTheOnesTheGuestHas() async throws {
        let link = FakeGuestLink()
        let guest = GuestServices(agent: GuestAgent(link: link, cache: GuestAgentCache()))
        func info(_ id: String) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
        }
        link.files["/Applications/FieldTest.app/Info.plist"] = try info("com.apple.fieldtest")
        link.files["/Applications/iOS Diagnostics.app/Info.plist"] = try info("com.apple.iosdiagnostics")
        link.files["/Applications/DemoApp.app/Info.plist"] = try info("com.example.notdemo")
        #expect(try await HiddenApp.present(on: guest).map(\.name) == ["Field Test", "Diagnostics"])
    }

    @Test func thePanelSavesPerDeviceAndRefusesWhatCantWork() throws {
        try withTemporaryDirectory { dir in
            let file = DeviceSettingsFile(directory: dir)
            let guest = try developerImages(in: dir, ["6.1"])
            let tweaks = DeviceTweaks(
                settings: file,
                version: "6.1.6",
                guestTools: true,
                clockPinned: false,
                guestRoot: guest
            )
            let model = TweaksPanelModel(tweaks: tweaks, guest: nil)
            model.set(.signalNumbers, on: true)
            model.set(.emojiEverywhere, on: true)
            model.set(.developerSettings, on: true)
            #expect(DeviceSettings.load(dir).tweaks?.on == [.signalNumbers, .developerSettings], "no emoji on 6.1.6")
            #expect(tweaks.developerImage?.path == guest.path + "/developer-disk-images/6.1/DeveloperDiskImage.dmg")
            let none = DeviceTweaks(
                settings: file,
                version: "5.1.1",
                guestTools: true,
                clockPinned: false,
                guestRoot: guest
            )
            #expect(!none.isAvailable(.developerSettings), "no 5.1 image: the row is disabled")
            #expect(tweaks.bootClock == nil)
            model.set(.timeMachine, on: true)
            #expect(tweaks.bootClock == TweakSettings.macworld2007)
        }
    }
}
