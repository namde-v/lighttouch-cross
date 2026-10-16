// The cross-platform replacement for OSLog: swift-log behind the same
// call shape (`LTMLogger(subsystem:category:)` with `info`/`error`/etc. taking
// plain strings). OSLog's privacy annotations have no swift-log equivalent;
// call sites drop `, privacy: .public` from their interpolations.
import Foundation
import Logging
import Synchronization

// Call sites use it from nonisolated contexts, so the whole type opts out of
// the package's default MainActor isolation.
public nonisolated struct LTMLogger: Sendable {
    private let logger: Logger

    public init(subsystem: String, category: String) {
        LTMLogging.bootstrap()
        var logger = Logger(label: "\(subsystem).\(category)")
        logger.logLevel = .debug
        self.logger = logger
    }

    public func trace(_ message: String) { logger.trace("\(message)") }
    public func debug(_ message: String) { logger.debug("\(message)") }
    public func info(_ message: String) { logger.info("\(message)") }
    public func notice(_ message: String) { logger.notice("\(message)") }
    public func warning(_ message: String) { logger.warning("\(message)") }
    public func error(_ message: String) { logger.error("\(message)") }
    public func critical(_ message: String) { logger.critical("\(message)") }
}

public nonisolated enum LTMLogging {
    private static let once = Mutex(false)

    /// Install a stderr handler once, unless the app bootstrapped swift-log
    /// itself first. Safe to call repeatedly.
    public static func bootstrap() {
        let first = once.withLock { already in
            defer { already = true }
            return !already
        }
        guard first else { return }
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .debug
            return handler
        }
    }
}
