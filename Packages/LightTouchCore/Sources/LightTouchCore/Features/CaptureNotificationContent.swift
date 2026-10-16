import Foundation
import HostRuntime

/// What capture and device notifications say, and the identity their actions find again (posted through an
/// `LTMNotifier`; see LTMNotifier.swift).
public enum CaptureNotificationContent {
    public nonisolated static let readyCategory = "DEVICE_READY"

    public static func ready(_ name: String, entryID: String) -> LTMNotificationContent {
        LTMNotificationContent(
            title: "\(name) is ready to use",
            categoryIdentifier: readyCategory,
            userInfo: ["entry": entryID]
        )
    }
}
