import Foundation

/// The app a Release test run checks: LTM_RELEASE_APP (a Light Touch.app) or LTM_RELEASE_ARCHIVE (an .xcarchive, whose
/// only product is Applications/<one app>). xcodebuild passes them to the tests as TEST_RUNNER_LTM_RELEASE_APP etc.
public enum ReleaseApp {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// The Release plan sets LTM_RELEASE_REQUIRED=1: without an app its tests fail instead of standing aside.
    public static var required: Bool { environment["LTM_RELEASE_REQUIRED"] == "1" }
    /// Skip the prepare matrix (LTM_RELEASE_SKIP_PREPARE=1): development dry runs only; scripts/release refuses it
    /// for a real release.
    public static var skipPrepare: Bool { environment["LTM_RELEASE_SKIP_PREPARE"] == "1" }
    /// The app is an export (notarized, stapled): Gatekeeper and the ticket are checked too (LTM_RELEASE_EXPORTED=1).
    public static var exported: Bool { environment["LTM_RELEASE_EXPORTED"] == "1" }
    public static var given: Bool { environment["LTM_RELEASE_APP"] != nil || environment["LTM_RELEASE_ARCHIVE"] != nil }

    public enum Failure: Error, CustomStringConvertible {
        case missing
        case notAnAppArchive([String])
        public var description: String {
            switch self {
            case .missing: "no app: set LTM_RELEASE_APP or LTM_RELEASE_ARCHIVE (TEST_RUNNER_… through xcodebuild)"
            case .notAnAppArchive(let products):
                "not an app archive (Products: \(products)): Organizer can't distribute it"
            }
        }
    }

    public static func app() throws -> URL {
        if let path = environment["LTM_RELEASE_APP"] { return URL(fileURLWithPath: path).resolvingSymlinksInPath() }
        guard let path = environment["LTM_RELEASE_ARCHIVE"] else { throw Failure.missing }
        let products = URL(fileURLWithPath: path).appendingPathComponent("Products")
        let names = try FileManager.default.contentsOfDirectory(atPath: products.path).filter { !$0.hasPrefix(".") }
            .sorted()
        let apps = try FileManager.default.contentsOfDirectory(
            atPath: products.appendingPathComponent("Applications").path
        )
        .filter { $0.hasSuffix(".app") }
        guard names == ["Applications"], apps.count == 1 else { throw Failure.notAnAppArchive(names) }
        return products.appendingPathComponent("Applications/\(apps[0])").resolvingSymlinksInPath()
    }

    /// Every Mach-O in the bundle (not symlinks).
    public static func binaries(in app: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: app.appendingPathComponent("Contents"),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        return (enumerator?.compactMap { $0 as? URL } ?? []).filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true && BundleHygiene.isMachO(url)
        }.sorted { $0.path < $1.path }
    }

    /// The environment the bundle's tools run in: the user's basics, no LTM_ overrides (the bundle must stand alone).
    public static var cleanEnvironment: [String: String] {
        var clean = environment.filter {
            !$0.key.hasPrefix("LTM_") && !$0.key.hasPrefix("TEST_RUNNER_") && !$0.key.hasPrefix("XCTest")
        }
        clean["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return clean
    }
}
