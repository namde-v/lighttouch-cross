import Foundation

/// Watches the captured file itself so a Finder move to Trash dismisses its banner.
@MainActor
public final class CaptureFileMonitor {
    private var watch: FileEventWatch?

    public init?(url: URL, onRemoval: @escaping @MainActor () -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        watch = FileEventWatch(
            paths: [(url.path, [.delete, .rename, .revoke])],
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.watch != nil else { return }
                // Renaming or moving the file also invalidates the banner's URL.
                guard !FileManager.default.fileExists(atPath: url.path) else { return }
                self.cancel()
                onRemoval()
            }
        }
        guard (watch?.count ?? 0) > 0 else {
            watch = nil
            return nil
        }
    }

    public func cancel() {
        watch?.cancel()
        watch = nil
    }
    // deinit releases `watch`, whose own deinit cancels the watches.
    deinit {}
}
