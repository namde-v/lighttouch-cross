import Foundation

/// A user-initiated ProcessInfo activity, held while `held` is true: a download, preparation, install,
/// recording or file transfer keeps the Mac from idle sleep (and the app out of App Nap) until it ends.
/// On Linux there is no such API; the flag still tracks intent for callers.
public struct UserActivity {
    public let reason: String
    #if os(macOS)
    private var token: NSObjectProtocol?
    #else
    private var heldFlag = false
    #endif

    public init(_ reason: String) { self.reason = reason }

    // (The #if wraps the whole property: an if-config inside the accessor
    // block loses the setter on some toolchains.)
    #if os(macOS)
    public var held: Bool {
        get { token != nil }
        set {
            guard newValue != held else { return }
            if newValue {
                token = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .userInitiated], reason: reason)
            } else if let token {
                ProcessInfo.processInfo.endActivity(token)
                self.token = nil
            }
        }
    }
    #else
    public var held: Bool {
        get { heldFlag }
        set { heldFlag = newValue }
    }
    #endif
}
