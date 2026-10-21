#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Foundation
import Testing

@testable import LightTouchCore

/// Diagnostics export: the app's own crash reports, the system summary, and an atomic archive that a failing,
/// empty, missing or cancelled archiver never half-writes, with concurrent exports keeping their own scratch.
struct DiagnosticsExportTests {
    let fm = FileManager.default

    nonisolated func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    nonisolated func children(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    @Test func crashReportsAreTheAppsOwnNewestFirstWithinThirtyDays() throws {
        try withTemporaryDirectory { reports in
            for (name, age) in [
                ("LightTouch-2026-10-07-101010.ips", 60.0), ("LightTouchDevice-2026-10-07-101011.ips", 30.0),
                ("Safari-2026-10-07-101012.ips", 10.0), ("LightTouchServices-2026-08-01-101010.ips", 40 * 86_400.0),
                ("LightTouchDevice-notes.txt", 5.0),
            ] {
                let url = reports.appendingPathComponent(name)
                try Data("report".utf8).write(to: url)
                try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
            }
            let found = DiagnosticsExport.crashReports(
                executables: ["LightTouch", "LightTouchDevice", "LightTouchServices"],
                in: reports
            )
            #expect(
                found.map(\.lastPathComponent) == [
                    "LightTouchDevice-2026-10-07-101011.ips", "LightTouch-2026-10-07-101010.ips",
                ]
            )
        }
    }

    @Test func systemSummaryNamesTheOSAndArchitecture() {
        let summary = DiagnosticsExport.systemSummary()
        #if os(Linux)
        #expect(summary.contains("Linux "))
        #elseif os(Windows)
        #expect(summary.contains("Windows "))
        #else
        #expect(summary.contains("macOS ") && summary.contains(ProcessInfo.processInfo.operatingSystemVersionString))
        #endif
        #expect(summary.contains("arm64") || summary.contains("x86_64"))
    }

    /// An archiver stand-in: `fail` writes a partial archive and exits 9, `empty` an empty one, `cancel` records its
    /// pid in staging/ready and sleeps until killed.
    func archiver(in directory: URL) throws -> URL {
        #if os(Linux)
        // zip -r -q <archive> <staging-name>, run from the staging parent:
        // $3 is the archive, $4 the staging directory's name.
        let script = """
            staging="$(pwd)/$4"
            case "$(cat "$staging/info.txt")" in
                fail) printf incomplete > "$3"; exit 9 ;;
                empty) : > "$3"; exit 0 ;;
                cancel) printf '%s\\n' "$$" > "$staging/ready"; exec /bin/sleep 60 ;;
            esac
            exit 1

            """
        #else
        // ditto -c -k --sequesterRsrc --keepParent <staging> <archive>:
        // $5 is the staging directory, $6 the archive.
        let script = """
            case "$(cat "$5/info.txt")" in
                fail) printf incomplete > "$6"; exit 9 ;;
                empty) : > "$6"; exit 0 ;;
                cancel) printf '%s\\n' "$$" > "$5/ready"; exec /bin/sleep 60 ;;
            esac
            exit 1

            """
        #endif
        return try LibraryFixtures.script(directory.appendingPathComponent("archive-helper"), script)
    }

    // Unix-only: shells out to /usr/bin/unzip and checks kill(pid, 0).
    #if !os(Windows)
    @Test func exportIsAtomicAndCancellable() async throws {
        try await LibraryFixtures.withScratch { root in
            let scratch = root.appendingPathComponent("diagnostic temp")
            let exports = root.appendingPathComponent("exports")
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try fm.createDirectory(at: exports, withIntermediateDirectories: true)
            let log = root.appendingPathComponent("app.log")
            try Data("sample events".utf8).write(to: log)
            let report = root.appendingPathComponent("LightTouchDevice-2026-10-07-101011.ips")
            try Data("report".utf8).write(to: report)

            // A real ditto archive: valid, with the info and the crash report, and no scratch left.
            let success = exports.appendingPathComponent("success.zip")
            try await DiagnosticsExport.write(
                to: success,
                logs: [log],
                info: "real ditto archive",
                crashReports: [report],
                temporaryRoot: scratch
            )
            #expect(try children(scratch).isEmpty)
            try LibraryFixtures.run("/usr/bin/unzip", ["-tq", success.path])
            #expect(
                try LibraryFixtures.run("/usr/bin/unzip", ["-p", success.path, "LightTouchMac-diagnostics/info.txt"])
                    == "real ditto archive"
            )
            let listing = try LibraryFixtures.run("/usr/bin/unzip", ["-Z1", success.path]).split(separator: "\n")
            #expect(listing.contains("LightTouchMac-diagnostics/CrashReports/LightTouchDevice-2026-10-07-101011.ips"))

            // A failing, empty or missing archiver: an error, the existing archive kept, nothing left behind.
            let helper = try archiver(in: root)
            let preserved = exports.appendingPathComponent("preserved.zip")
            try Data("existing user archive".utf8).write(to: preserved)
            func untouched() throws {
                #expect(try text(preserved) == "existing user archive")
                #expect(try children(scratch).isEmpty)
                #expect(try children(exports).allSatisfy { !$0.lastPathComponent.hasPrefix(".LightTouch-") })
            }
            for (info, executable) in [
                ("fail", helper), ("empty", helper), ("missing", root.appendingPathComponent("no-archiver")),
            ] {
                await #expect(throws: (any Error).self, "\(info)") {
                    try await DiagnosticsExport.write(
                        to: preserved,
                        logs: [log],
                        info: info,
                        temporaryRoot: scratch,
                        archiver: executable
                    )
                }
                try untouched()
            }

            // One export's archiver still running while another completes: neither deletes the other's scratch.
            let cancelled = Task {
                try await DiagnosticsExport.write(
                    to: preserved,
                    logs: [log],
                    info: "cancel",
                    temporaryRoot: scratch,
                    archiver: helper
                )
            }
            var ready: URL?
            let deadline = Date().addingTimeInterval(10)
            while ready == nil, Date() < deadline {
                ready = try children(scratch).map { $0.appendingPathComponent("LightTouchMac-diagnostics/ready") }
                    .first { !((try? text($0))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
                if ready == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
            guard let ready else {
                cancelled.cancel()
                Issue.record("the archiver did not start")
                return
            }
            let pid = try #require(Int32(text(ready).trimmingCharacters(in: .whitespacesAndNewlines)))
            let concurrent = exports.appendingPathComponent("concurrent.zip")
            try await DiagnosticsExport.write(
                to: concurrent,
                logs: [log],
                info: "concurrent real archive",
                temporaryRoot: scratch
            )
            #expect(try fm.fileExists(atPath: ready.path) && children(scratch).count == 1)
            #expect(try text(ready.deletingLastPathComponent().appendingPathComponent("info.txt")) == "cancel")
            #expect(
                try LibraryFixtures.run(
                    "/usr/bin/unzip",
                    ["-p", concurrent.path, "LightTouchMac-diagnostics/info.txt"]
                ) == "concurrent real archive"
            )

            // Cancelled: CancellationError, the child gone, nothing written.
            let cancelledAt = Date()
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(
                Date().timeIntervalSince(cancelledAt) < 10,
                "the cancel waited for the archiver instead of stopping it"
            )
            #expect(kill(pid, 0) != 0, "the cancelled archiver is still running")
            try untouched()
            #expect(try text(log) == "sample events")
        }
    }
    #endif

    /// The archive's logs, info and crash reports carry no identity: the home folder, the user's and the Mac's
    /// names, the device's own identifiers and anything shaped like one are gone from the text, and a crash report
    /// loses its identifying members while its stacks and binary images stay byte for byte.
    // Unix-only: shells out to /usr/bin/unzip (and the default archiver is ditto/zip).
    #if !os(Windows)
    @Test func exportIsScrubbed() async throws {
        try await LibraryFixtures.withScratch { root in
            let identity = DiagnosticsExport.HostIdentity(
                home: "/Users/jappleseed",
                names: ["jappleseed", "Johnny Appleseed", "Johnnys-MacBook-Pro"]
            )
            let leaks = [
                "/Users/jappleseed", "jappleseed", "Johnny Appleseed", "Johnnys-MacBook-Pro", "johnny@icloud.com",
                "00:1e:c2:aa:bb:cc", "6f1ed002ab5595859014ebf0951522d9a1b2c3d4", "00008020-001A2B3C4D5E6F70",
                "8874EC96-6945-4F6F-AD3D-96DDEBB6F52B", "012345678901237", "C02XK1ZQJGH5", "seed-4f8a2c",
            ]
            let log = root.appendingPathComponent("serial.log")
            try """
                2026-10-08T04:23:40Z opened /Users/jappleseed/Library/Devices/8874EC96-6945-4F6F-AD3D-96DDEBB6F52B
                lockdown: UDID 6f1ed002ab5595859014ebf0951522d9a1b2c3d4 (00008020-001A2B3C4D5E6F70) seed seed-4f8a2c
                wifi 00:1e:c2:aa:bb:cc imei 012345678901237 serial C02XK1ZQJGH5 on Johnnys-MacBook-Pro
                Apple ID johnny@icloud.com, user jappleseed (Johnny Appleseed)
                emulator build 1538771e7dcf3b9c933d599ef98c04ce
                """.write(to: log, atomically: true, encoding: .utf8)
            let rotated = root.appendingPathComponent("serial.log.1")
            try "older: Johnny Appleseed’s iPhone at /Users/jappleseed".write(
                to: rotated,
                atomically: true,
                encoding: .utf8
            )
            let stacks = """
                  "threads" : [{"id" : 1234,"frames" : [{"imageOffset" : 16588,"symbol" : "main","imageIndex" : 0}]}],
                  "usedImages" : [{"uuid" : "59d15082-65eb-3584-a2a3-77fe117b8dec","base" : 4294967296,
                  "path" : "/Applications/Light Touch.app/Contents/MacOS/LightTouch","name" : "LightTouch"}]
                """
            let report = root.appendingPathComponent("LightTouch-2026-10-08-101010.ips")
            try """
                {"app_name":"LightTouch","incident_id":"8231277F-99CB-4CC0-BC6A-EC990F9904ED","os_version":"macOS 27.0"}
                {
                  "procPath" : "/Users/jappleseed/Applications/Light Touch.app/Contents/MacOS/LightTouch",
                  "crashReporterKey" : "4CE2ED4F-7491-7733-6730-2843A1FD34AD",
                  "bootSessionUUID" : "B69885FD-2DD0-4563-A355-7844D18BF0A6",
                  "sleepWakeUUID" : "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9",
                  "incident" : "8231277F-99CB-4CC0-BC6A-EC990F9904ED",
                  "Hardware UUID" : "11111111-2222-3333-4444-555555555555",
                  "responsibleProc" : "Johnnys-MacBook-Pro helper",
                \(stacks)
                }
                """.write(to: report, atomically: true, encoding: .utf8)
            let archive = root.appendingPathComponent("scrubbed.zip")
            try await DiagnosticsExport.write(
                to: archive,
                logs: [log, rotated],
                info: "device: Johnny Appleseed’s iPhone 8874EC96-6945-4F6F-AD3D-96DDEBB6F52B base /Users/jappleseed/x",
                crashReports: [report],
                secrets: ["seed-4f8a2c"],
                identity: identity
            )
            func member(_ name: String) throws -> String {
                try LibraryFixtures.run("/usr/bin/unzip", ["-p", archive.path, "LightTouchMac-diagnostics/" + name])
            }
            let texts = try ["serial.log", "serial.log.1", "info.txt"].map(member)
            for (name, text) in zip(["serial.log", "serial.log.1", "info.txt"], texts) {
                for leak in leaks { #expect(!text.localizedCaseInsensitiveContains(leak), "\(name): \(leak)") }
            }
            #expect(texts[0].contains("emulator build 1538771e7dcf3b9c933d599ef98c04ce"))
            #expect(texts[1] == "older: <redacted>’s iPhone at ~")
            #expect(texts[2] == "device: <redacted>’s iPhone <uuid> base ~/x")

            let crash = try member("CrashReports/LightTouch-2026-10-08-101010.ips")
            for leak in [
                "/Users/jappleseed", "Johnnys-MacBook-Pro", "8231277F-99CB-4CC0-BC6A-EC990F9904ED",
                "4CE2ED4F-7491-7733-6730-2843A1FD34AD", "B69885FD-2DD0-4563-A355-7844D18BF0A6",
                "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", "11111111-2222-3333-4444-555555555555",
            ] {
                #expect(!crash.contains(leak), "\(leak)")
            }
            #expect(crash.contains(stacks), "the stacks and images are untouched")
            #expect(crash.contains(#""procPath" : "~/Applications/Light Touch.app/Contents/MacOS/LightTouch""#))
            #expect(crash.contains(#""crashReporterKey" : "<redacted>""#))
            // Still a header line and a JSON report.
            let parts = crash.split(separator: "\n", maxSplits: 1).map { Data($0.utf8) }
            #expect(parts.count == 2 && parts.allSatisfy { (try? JSONSerialization.jsonObject(with: $0)) != nil })
        }
    }
    #endif
}
