import Foundation

/// A line to the helper's stderr (the app's pipe into the device's native.log). A write that can't land is dropped:
/// once the app is gone that pipe has no reader, and FileHandle.write(_:) raises on EPIPE, which aborted the helper
/// in its own "link closed" shutdown, before the halt flushed the device's storage.
func writeStandardError(_ text: String, to handle: FileHandle = .standardError) {
    try? handle.write(contentsOf: Data(text.utf8))
}

func helperLog(_ message: String, to handle: FileHandle = .standardError) {
    // gettimeofday(3) does not exist on Windows; Date() is the portable clock
    // (same epoch seconds, same %.3f millisecond rendering).
    let line =
        String(format: "[LightTouchDevice %d %.3f] ", getpid(), Date().timeIntervalSince1970) + message
        + "\n"
    writeStandardError(line, to: handle)
}
