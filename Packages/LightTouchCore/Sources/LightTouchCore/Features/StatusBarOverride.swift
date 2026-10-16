// UIKit's status bar override data (+[UIStatusBarServer postStatusBarOverrideData:], 4.2 to 7.1.2), laid out for one
// firmware: what Apple's internal Status Bar Overrides pane posted, and Tweaks' Clean Status Bar (the agent's
// `statusbar` op sends it). The struct is UIKit's private StatusBarOverrideData: overrideItemIsEnabled[N] at 0, the
// override bits right after it, and the StatusBarRawData values from byte 28. Offsets from each build's method type
// encoding and the merge routines that read it (4.2.1, 4.3.3, 5.1.1, 6.1.6, 7.1.2 dyld caches): a firmware whose
// layout was not read gets none.

import Foundation

public nonisolated struct StatusBarOverride: Sendable {
    let size: Int
    /// overrideItemIsEnabled's count: the override bits start at this byte.
    let items: Int
    /// The bits as (byte, bit).
    let wifiBars: (Int, Int), dataNetwork: (Int, Int), batteryCapacity: (Int, Int), batteryState: (Int, Int)
    /// values' fields.
    let time: Int, gsmBars: Int, wifiBarsValue: Int

    /// The layout of `version`'s UIKit; nil where it was not read.
    public static func layout(version: String) -> StatusBarOverride? {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        switch (parts[0], parts[1]) {
        case (4, 2):
            return .init(
                size: 1992,
                items: 22,
                wifiBars: (23, 1),
                dataNetwork: (23, 2),
                batteryCapacity: (23, 3),
                batteryState: (23, 4),
                time: 50,
                gsmBars: 120,
                wifiBarsValue: 1456
            )
        case (4, 3):
            return .init(
                size: 1892,
                items: 22,
                wifiBars: (23, 1),
                dataNetwork: (23, 2),
                batteryCapacity: (23, 3),
                batteryState: (23, 4),
                time: 50,
                gsmBars: 120,
                wifiBarsValue: 1456
            )
        case (5, 1):
            return .init(
                size: 2092,
                items: 23,
                wifiBars: (24, 2),
                dataNetwork: (24, 3),
                batteryCapacity: (24, 5),
                batteryState: (24, 6),
                time: 51,
                gsmBars: 120,
                wifiBarsValue: 1656
            )
        case (6, 1):
            return .init(
                size: 1992,
                items: 24,
                wifiBars: (25, 1),
                dataNetwork: (25, 2),
                batteryCapacity: (25, 4),
                batteryState: (25, 5),
                time: 52,
                gsmBars: 120,
                wifiBarsValue: 1556
            )
        case (7, 1):
            return .init(
                size: 2000,
                items: 25,
                wifiBars: (26, 1),
                dataNetwork: (26, 2),
                batteryCapacity: (26, 4),
                batteryState: (26, 5),
                time: 53,
                gsmBars: 124,
                wifiBarsValue: 1560
            )
        default: return nil
        }
    }

    /// No overrides: posting it gives the status bar back to SpringBoard.
    public var cleared: Data { Data(count: size) }

    /// Apple's product-shot status bar: 9:41 AM, full cellular and Wi-Fi bars, a full battery that isn't charging.
    public var clean: Data {
        var d = Data(count: size)
        func bit(_ at: (Int, Int)) { d[at.0] |= UInt8(1 << at.1) }
        func int(_ value: Int32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { d.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        bit((items, 0))  // time string
        d.replaceSubrange(time..<time + 7, with: Data("9:41 AM".utf8))
        bit((items, 2))  // GSM signal bars
        int(5, at: gsmBars)
        bit(wifiBars)
        int(3, at: wifiBarsValue)
        bit(dataNetwork)
        int(5, at: wifiBarsValue + 4)  // Wi-Fi: the data network shows its bars
        bit(batteryCapacity)
        int(100, at: wifiBarsValue + 8)
        bit(batteryState)
        int(0, at: wifiBarsValue + 12)  // draining, not charging
        return d
    }
}
