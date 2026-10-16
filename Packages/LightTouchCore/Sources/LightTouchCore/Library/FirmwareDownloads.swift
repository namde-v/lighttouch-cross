// IPSW downloads from Apple's CDN, or a mirror of the same file.
//
// A background URLSession, so a download goes on while the app is quit: the
// next launch makes the session again under the same identifier and its
// delegate picks the task back up. Tasks are named by the IPSW's sha1. A
// failure keeps the resume data in <sha1>.resume and the next start resumes
// from it; a cancel discards the download, its .resume included. A finished file is size- and SHA1-checked before it
// becomes <sha1>.ipsw. A source that is gone (an HTTP error, a host that
// doesn't resolve or answer) or serves other bytes moves the download on to
// the entry's next source (FirmwareWire.Entry.Source.urls); the last one's failure is the download's.

import FirmwareSchema
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(Linux)
// Not in swift-corelibs-foundation; corelibs URLSession never produces resume
// data, so the lookup below simply misses and downloads restart from scratch.
private nonisolated(unsafe) let NSURLSessionDownloadTaskResumeData = "NSURLSessionDownloadTaskResumeData"
#endif

public nonisolated final class FirmwareDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case progress(Double)
        /// Resumed from saved data at this offset.
        case resumed(offset: Int64)
        case finished(URL)
        case failed(FirmwareError)
        /// The earlier sources failed; the download goes on from this one.
        case mirror(URL)
        /// Cancelled; nothing of the download is kept.
        case cancelled
    }

    public static let identifier = "\(StorageLocations.bundleIdentifier).ipsw"

    /// The session configuration downloads run under. macOS uses a background
    /// session so a download goes on while the app is quit; corelibs
    /// FoundationNetworking has no background sessions, so on Linux downloads
    /// run in-process and don't survive a relaunch (see SHIM_NOTES.md).
    public static let defaultSessionConfiguration: URLSessionConfiguration = {
        #if os(Linux)
        return .default
        #else
        return .background(withIdentifier: identifier)
        #endif
    }()

    public let store: IPSWStore
    private let expectedBytes: @Sendable (String) -> Int64?
    private let sources: @Sendable (String) -> [URL]
    private let install: (@Sendable (String, URL, URL?) throws -> URL)?
    private let onEvent: @Sendable (String, Event) -> Void
    private let lock = NSLock()
    private var cancelling: Set<String> = []
    /// Made in init, once self can be its delegate.
    private var session: URLSession?

    /// `expectedBytes` gives the catalog's size for a sha1, also for a task
    /// a previous launch started; `sources` its URLs in the order to try them. `install` turns a finished
    /// download (sha1, file, the URL it came from) into the IPSW: a "rar" source or mirror is unwrapped; nil: size and
    /// sha1 checked.
    /// Events arrive on a private serial queue.
    public init(
        store: IPSWStore,
        configuration: URLSessionConfiguration = FirmwareDownloads.defaultSessionConfiguration,
        expectedBytes: @escaping @Sendable (String) -> Int64?,
        sources: @escaping @Sendable (String) -> [URL] = { _ in [] },
        install: (@Sendable (String, URL, URL?) throws -> URL)? = nil,
        onEvent: @escaping @Sendable (String, Event) -> Void
    ) {
        self.store = store
        self.expectedBytes = expectedBytes
        self.sources = sources
        self.install = install
        self.onEvent = onEvent
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// The sha1s of the session's tasks, including ones a previous launch started and any whose end hasn't been
    /// delivered yet (so a relaunch doesn't start them again).
    public func active(_ completion: @escaping @Sendable ([String]) -> Void) {
        session?.getAllTasks { tasks in completion(tasks.compactMap(\.taskDescription)) }
    }

    /// Starts or resumes the download of `url`, which must hash to `sha1`.
    public func start(sha1: String, url: URL) throws {
        try StorageLocations.privateDirectory(store.downloads)
        lock.withLock { _ = cancelling.remove(sha1) }
        #if os(Linux)
        if url.isFileURL {
            // swift-corelibs-foundation's URLSession doesn't fetch file://
            // URLs; a local file needs no network stack, so it goes straight
            // through the finish path.
            finishLocalFile(sha1: sha1, url: url)
            return
        }
        #endif
        guard let session else { throw FirmwareError.failed("The download couldn’t start.") }
        let saved = store.resumeData(sha1)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: saved) {
            task = session.downloadTask(withResumeData: data)
            try? FileManager.default.removeItem(at: saved)
        } else {
            task = session.downloadTask(with: url)
        }
        task.taskDescription = sha1
        task.resume()
    }

    /// Stops the download and deletes its resume data; `.cancelled` follows.
    public func cancel(sha1: String) {
        lock.withLock { _ = cancelling.insert(sha1) }
        session?.getAllTasks { [self] tasks in
            for task in tasks where task.taskDescription == sha1 { task.cancel() }
            try? FileManager.default.removeItem(at: store.resumeData(sha1))
            onEvent(sha1, .cancelled)
        }
    }

    /// The source after the one `task` fetched from, started as `sha1`'s download; false when there is none.
    private func next(after task: URLSessionTask, sha1: String) -> Bool {
        next(after: task.originalRequest?.url, sha1: sha1)
    }

    private func next(after failedURL: URL?, sha1: String) -> Bool {
        let urls = sources(sha1)
        guard let session, let failed = failedURL, let index = urls.firstIndex(of: failed),
            index + 1 < urls.count,
            !lock.withLock({ cancelling.contains(sha1) })
        else { return false }
        let url = urls[index + 1]
        logEvent(
            "firmware: \(failed.host ?? failed.absoluteString) failed for \(sha1); trying \(url.host ?? url.absoluteString)"
        )
        try? FileManager.default.removeItem(at: store.resumeData(sha1))
        #if os(Linux)
        if url.isFileURL {
            finishLocalFile(sha1: sha1, url: url)
        } else {
            let task = session.downloadTask(with: url)
            task.taskDescription = sha1
            task.resume()
        }
        #else
        let task = session.downloadTask(with: url)
        task.taskDescription = sha1
        task.resume()
        #endif
        onEvent(sha1, .mirror(url))
        return true
    }

    /// Tests: stop the session without touching the tasks' saved state.
    public func invalidate() { session?.invalidateAndCancel() }

    private func saveResumeData(_ data: Data, sha1: String) {
        try? StorageLocations.privateDirectory(store.downloads)
        try? data.write(to: store.resumeData(sha1), options: .atomic)
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        guard let sha1 = downloadTask.taskDescription else { return }
        onEvent(sha1, .resumed(offset: fileOffset))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let sha1 = downloadTask.taskDescription, Self.succeeded(downloadTask) else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes(sha1) ?? 0
        if total > 0 { onEvent(sha1, .progress(min(1, Double(totalBytesWritten) / Double(total)))) }
    }

    /// The file at `location` is deleted when this returns, so it moves out
    /// first; checking it is quick enough for the delegate queue (about 1 s for 500 MB).
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let sha1 = downloadTask.taskDescription else { return }
        finish(sha1: sha1, location: location, sourceURL: downloadTask.originalRequest?.url, task: downloadTask)
    }

    /// Shared finish path for URLSession downloads and local files.
    private func finish(sha1: String, location: URL, sourceURL: URL?, task: URLSessionTask?) {
        let partial = store.partial(sha1)
        let status = (task?.response as? HTTPURLResponse)?.statusCode ?? 200
        do {
            if let task, !Self.succeeded(task) {
                throw FirmwareError.failed("The download failed (HTTP \(status)).")
            }
            try StorageLocations.privateDirectory(store.downloads)
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: location, to: partial)
            onEvent(
                sha1,
                .finished(
                    try install.map { try $0(sha1, partial, sourceURL) }
                        ?? store.install(partial, sha1: sha1, bytes: expectedBytes(sha1))
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: partial)
            // An HTTP error or other bytes than the catalog's: the next source, if any.
            let error = error as? FirmwareError ?? .failed(error.localizedDescription)
            if error == .corrupted || (task.map { !Self.succeeded($0) } ?? false),
                next(after: sourceURL, sha1: sha1)
            { return }
            onEvent(sha1, .failed(error))
        }
    }

    #if os(Linux)
    /// A file:// source: copy it and run the finish path on the delegate
    /// queue, so events stay ordered with URLSession ones.
    private func finishLocalFile(sha1: String, url: URL) {
        guard let session else {
            onEvent(sha1, .failed(.failed("The download couldn’t start.")))
            return
        }
        session.delegateQueue.addOperation { [self] in
            let tmp = self.store.downloads.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.copyItem(at: url, to: tmp)
                self.finish(sha1: sha1, location: tmp, sourceURL: url, task: nil)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                if !self.next(after: url, sha1: sha1) {
                    self.onEvent(sha1, .failed(.failed(error.localizedDescription)))
                }
            }
        }
    }
    #endif

    /// A 2xx response, or none (file URLs).
    private static func succeeded(_ task: URLSessionTask) -> Bool {
        (200..<300).contains((task.response as? HTTPURLResponse)?.statusCode ?? 200)
    }

    /// Errors that mean the source is gone rather than the network flaking: the next source, not resume data.
    private static let unreachable: Set<Int> = [
        NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost,
        NSURLErrorFileDoesNotExist, NSURLErrorBadServerResponse,
    ]

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let sha1 = task.taskDescription else { return }
        let nsError = error as NSError
        // A cancel reports through its own completion and keeps nothing.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled,
            lock.withLock({ cancelling.contains(sha1) })
        {
            return
        }
        if nsError.domain == NSURLErrorDomain, Self.unreachable.contains(nsError.code), next(after: task, sha1: sha1) {
            return
        }
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { saveResumeData(data, sha1: sha1) }
        onEvent(sha1, .failed(.failed("The download stopped: \(error.localizedDescription)")))
    }
}
