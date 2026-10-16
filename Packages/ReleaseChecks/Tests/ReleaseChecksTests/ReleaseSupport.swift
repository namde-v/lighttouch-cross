import Foundation
import Testing

@testable import ReleaseChecks

/// The repository this test file sits in.
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The app's tests run when an app was given or the Release plan requires one (then a missing app fails).
let appGiven = ReleaseApp.given || ReleaseApp.required
