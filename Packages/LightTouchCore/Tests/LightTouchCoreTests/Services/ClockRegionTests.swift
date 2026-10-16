import Foundation
import Testing

@testable import LightTouchCore

/// ClockRegion turns a Mac locale (its region override and 24-hour switch included) into lockdown's Locale id and
/// 24-hour flag (lockdown-tz --locale/--24h).
struct ClockRegionTests {
    func region(_ id: String) -> ClockRegion { ClockRegion(Locale(identifier: id)) }

    @Test func localeAndClockFormat() {
        #expect(region("en_GB") == ClockRegion(locale: "en_GB", uses24HourClock: true))
        #expect(region("en_US") == ClockRegion(locale: "en_US", uses24HourClock: false))
        #expect(
            region("en_US@hours=h23") == ClockRegion(locale: "en_US", uses24HourClock: true),
            "the Mac's 24-hour switch"
        )
        #expect(region("en_GB@hours=h12").uses24HourClock == false, "the Mac's 12-hour switch")
        #expect(region("de_DE@rg=chzzzz").locale == "de_CH", "a region override gives its region")
    }

    @Test func lockdownTZArguments() {
        #expect(region("en_US").arguments == ["--locale", "en_US", "--24h", "0"])
        #expect(region("en_GB").arguments == ["--locale", "en_GB", "--24h", "1"])
    }
}
