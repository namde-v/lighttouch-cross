import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import LightTouchCore

/// The suites that share process-wide state (CatalogClient's base URL and scratch, IPALibrary's root, the install
/// queue's statics, the URL stub) run one at a time inside this one.
@Suite(.serialized) enum SharedState {}

/// The repository, for the recorded fixtures under tests/fixtures.
/// (#filePath through any symlink: tests/offline links this file in.)
nonisolated let repositoryRoot = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

nonisolated func fixture(_ path: String) -> URL { repositoryRoot.appendingPathComponent("tests/fixtures/" + path) }

/// An in-process Legacy Store: while installed, every URLSession.shared request is answered by `respond`, so nothing
/// leaves the machine. A reply may stream its body in chunks with a pause between them.
nonisolated final class LegacyStoreStub: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = Data()
        var chunk = 0
        var pause: TimeInterval = 0
        static func json(_ object: Any, status: Int = 200) -> Reply {
            Reply(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }
        static func file(_ url: URL) -> Reply { Reply(body: try! Data(contentsOf: url)) }
        static func error(_ status: Int) -> Reply { Reply(status: status, body: Data("{}".utf8)) }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var respond: (@Sendable (URLComponents) -> Reply)?
    nonisolated(unsafe) private static var seen: [URLComponents] = []
    private let stopped = NSLock()
    nonisolated(unsafe) private var isStopped = false

    /// Every request since `install`, in order.
    static var requests: [URLComponents] { lock.withLock { seen } }

    /// Answer with `respond` for the life of `body`, with CatalogClient pointed at it, its scratch under
    /// `state`/work, IPALibrary rooted at `state` and the client's diagnostics going to `log`.
    @MainActor static func serving<T>(
        state: URL,
        log: @escaping (String) -> Void = { _ in },
        _ respond: @escaping @Sendable (URLComponents) -> Reply,
        _ body: () async throws -> T
    ) async rethrows -> T {
        lock.withLock {
            self.respond = respond
            seen = []
        }
        URLProtocol.registerClass(LegacyStoreStub.self)
        // URLSession.shared snapshots the registered protocols at creation; a stub registered after any session
        // was made is shadowed by the native HTTP protocol on Linux. Give the client a session with the stub first.
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [LegacyStoreStub.self]
        let stubSession = URLSession(configuration: configuration)
        let before = (CatalogClient.baseURL, CatalogClient.scratchDirectory, CatalogClient.log, IPALibrary.stateRoot, CatalogClient.session)
        CatalogClient.baseURL = URL(string: "http://catalog.test")!
        CatalogClient.scratchDirectory = state.appendingPathComponent("work", isDirectory: true)
        CatalogClient.log = log
        CatalogClient.session = stubSession
        IPALibrary.stateRoot = state
        defer {
            (CatalogClient.baseURL, CatalogClient.scratchDirectory, CatalogClient.log, IPALibrary.stateRoot, CatalogClient.session) = before
            URLProtocol.unregisterClass(LegacyStoreStub.self)
            lock.withLock { self.respond = nil }
        }
        return try await body()
    }

    override class func canInit(with request: URLRequest) -> Bool { lock.withLock { respond != nil } }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        guard
            let respond = Self.lock.withLock({
                Self.seen.append(components)
                return Self.respond
            })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let reply = respond(components)
        Thread.detachNewThread { [self] in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(reply.body.count)]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            #if os(Linux) || os(Windows)
            // corelibs-foundation's URLSession mishandles multiple didLoad
            // calls from a URLProtocol (data tasks keep only the first chunk;
            // download tasks hang or trap — 0xC000001D on Windows). Send the
            // body in one didLoad; preserve the streaming timing for the
            // cancellation test by delaying up front instead of between chunks.
            if reply.chunk > 0, reply.pause > 0 {
                let chunks = (reply.body.count + reply.chunk - 1) / reply.chunk
                let delay = reply.pause * Double(chunks)
                Thread.sleep(forTimeInterval: delay)
            } else if reply.pause > 0 {
                Thread.sleep(forTimeInterval: reply.pause)
            }
            if stopped.withLock({ isStopped }) { return }
            if !reply.body.isEmpty {
                client?.urlProtocol(self, didLoad: reply.body)
            }
            client?.urlProtocolDidFinishLoading(self)
            #else
            let size = reply.chunk > 0 ? reply.chunk : max(reply.body.count, 1)
            var offset = 0
            while offset < reply.body.count {
                if stopped.withLock({ isStopped }) { return }
                let end = min(offset + size, reply.body.count)
                client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<end))
                offset = end
                if reply.pause > 0 { Thread.sleep(forTimeInterval: reply.pause) }
            }
            client?.urlProtocolDidFinishLoading(self)
            #endif
        }
    }

    override func stopLoading() { stopped.withLock { isStopped = true } }
}

nonisolated extension URLComponents {
    /// The query as a dictionary (each name once).
    var items: [String: String] {
        Dictionary((queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }
}

/// A fresh directory for async work, removed afterwards (TestSupport's helpers take synchronous bodies).
func withTemporaryState<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ltm-tests-" + UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

/// What a test's diagnostics hook received.
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
