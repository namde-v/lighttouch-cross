// The cross-platform replacement for UserNotifications: what a notification
// says, and a seam for posting it. Linux shells to `notify-send` when present
// (no-op with a log line otherwise); the WinRT toast branch is stubbed for
// the Windows wave; Apple platforms keep UNUserNotificationCenter.
#if canImport(UserNotifications)
import UserNotifications
#endif
import Foundation
import Subprocess
#if canImport(System)
import System
#else
import SystemPackage
#endif

/// What capture and device notifications say, and the identity their actions find again.
public struct LTMNotificationContent: Sendable {
    public var title: String
    public var categoryIdentifier: String
    public var userInfo: [String: String]

    public init(title: String, categoryIdentifier: String, userInfo: [String: String] = [:]) {
        self.title = title
        self.categoryIdentifier = categoryIdentifier
        self.userInfo = userInfo
    }
}

public protocol LTMNotifier: Sendable {
    func post(_ content: LTMNotificationContent) async
}

/// The host's own notification center.
public struct SystemNotifier: LTMNotifier {
    public init() {}

    public func post(_ content: LTMNotificationContent) async {
        #if os(Linux)
        let candidates = ["/usr/bin/notify-send", "/usr/local/bin/notify-send"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            logEvent("notification not shown (notify-send isn’t installed): \(content.title)")
            return
        }
        do {
            _ = try await Subprocess.run(
                .path(FilePath(bin)),
                arguments: [content.title],
                input: .none,
                output: .discarded,
                error: .discarded
            )
        } catch {
            logEvent("notification failed: \(error.localizedDescription)")
        }
        #elseif os(Windows)
        // WinRT toasts: stubbed for the Windows wave (see SHIM_NOTES.md).
        logEvent("notification not shown (WinRT toasts aren’t implemented yet): \(content.title)")
        #elseif canImport(UserNotifications)
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.categoryIdentifier = content.categoryIdentifier
        notification.userInfo = content.userInfo
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: notification,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logEvent("notification failed: \(error.localizedDescription)")
        }
        #else
        logEvent("notification not shown (no notifier on this platform): \(content.title)")
        #endif
    }
}
