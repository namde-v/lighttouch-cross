// Help > Copy Bug Report Info: a short plain-text summary (the build, the Mac, the devices, recent errors) fenced as
// a Markdown code block, for the bug report form's "Light Touch info" field. Identity is scrubbed
// (DiagnosticsExport.scrub) before it reaches the clipboard.

import Foundation
import HostRuntime
import HostServiceWire

public nonisolated enum BugReportInfo {
    /// One device's facts, as the app knows them; nil members are left out of the block.
    public struct Device: Sendable {
        public var marketingName: String
        public var board: String
        public var iosVersion: String
        public var iosBuild: String
        public var entryID: String
        /// The window's status line ("Running", "Powered off", ...), or "Not running" without a session.
        public var state: String
        /// A zoom other than Fit (ZoomMode.defaultsValue).
        public var zoom: String?
        /// A free-form panel ("WxH").
        public var panel: String?
        public var internet: Bool?
        public var localNetwork: Bool
        public var guestTools: String?
        public var emulatorBuild: String?
        public var recipeVersion: Int?
        public var skipSetup: Bool?
        public var jailbreak: Bool?
        public var carrier: CarrierSettings?
        /// The installed list, when the device has answered.
        public var apps: [InstalledApp]?

        public init(
            marketingName: String,
            board: String,
            iosVersion: String,
            iosBuild: String,
            entryID: String,
            state: String,
            localNetwork: Bool
        ) {
            self.marketingName = marketingName
            self.board = board
            self.iosVersion = iosVersion
            self.iosBuild = iosBuild
            self.entryID = entryID
            self.state = state
            self.localNetwork = localNetwork
        }
    }

    /// The block: `system` (DiagnosticsExport.systemSummary), the bezel choice when not the default, each device
    /// (the selected one first, as the caller orders them) and the recent errors, scrubbed with `secrets` besides the
    /// Mac's own identity.
    public static func text(
        system: String,
        bezel: String? = nil,
        devices: [Device],
        recentErrors: [String],
        secrets: [String] = [],
        identity: DiagnosticsExport.HostIdentity = .current
    ) -> String {
        var lines = system.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let bezel { lines.append("Device bezels: \(bezel)") }
        if devices.isEmpty { lines += ["", "No device"] }
        for d in devices {
            lines += ["", "\(d.marketingName) (\(d.board)), iOS \(d.iosVersion) (\(d.iosBuild)), catalog \(d.entryID)"]
            var facts = ["State: \(d.state)"]
            if let zoom = d.zoom { facts.append("Zoom: \(zoom)") }
            if let panel = d.panel { facts.append("Free-form screen: \(panel)") }
            facts.append(
                (d.internet.map { "Internet: \($0 ? "on" : "off"); " } ?? "")
                    + "Local Network: \(d.localNetwork ? "on" : "off")"
            )
            if let tools = d.guestTools { facts.append("Guest tools: \(tools)") }
            if let build = d.emulatorBuild { facts.append("Emulator build: \(build)") }
            if let recipe = d.recipeVersion {
                facts.append(
                    "Prepared base: recipe \(recipe)" + (d.skipSetup == true ? ", Skip Setup" : "")
                        + (d.jailbreak == true ? ", Jailbreak" : "")
                )
            }
            if let c = d.carrier {
                facts.append(
                    "Carrier: \(c.carrier) (\(c.mccMNC)), \(c.registered ? "registered" : "not registered"), "
                        + "SIM \(c.simPresent ? "in" : "out"), \(c.bars) bars"
                )
            }
            if let apps = d.apps {
                facts.append("Apps (\(apps.count)):")
                facts += apps.map { "  \($0.id) — \($0.name) \($0.version)" }
            }
            lines += facts.map { "  " + $0 }
        }
        if !recentErrors.isEmpty {
            lines += ["", "Recent errors:"] + recentErrors.map { "  " + $0 }
        }
        let body = DiagnosticsExport.scrub(lines.joined(separator: "\n"), secrets: secrets, identity: identity)
        return "```text\n" + body + "\n```\n"
    }

    /// The last `limit` lines of the app's event log that report a failure, each cut to `width` characters.
    public static func recentErrors(log: URL, limit: Int = 5, width: Int = 200) -> [String] {
        // ponytail: reads the log's last 256 KB; the rotated app.log.1 is left out.
        guard let handle = try? FileHandle(forReadingFrom: log) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        let failure = /(?i)error|fail|couldn[’']t|can[’']t|crash|refused|didn[’']t|unexpected/
        return text.split(separator: "\n").filter { $0.contains(failure) }.suffix(limit).map {
            $0.count > width ? String($0.prefix(width - 1)) + "…" : String($0)
        }
    }
}
