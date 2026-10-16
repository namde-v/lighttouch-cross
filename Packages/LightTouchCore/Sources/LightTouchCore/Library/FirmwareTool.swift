import FirmwareSchema
import Foundation
import HostServiceWire
import Subprocess
#if canImport(System)
import System
#else
import SystemPackage
#endif

/// Narrow host boundary: the GUI requests operations; FirmwareKit owns formats.
public nonisolated enum FirmwareTool {
    /// FirmwareKit validates/migrates stopped storage and releases ownership
    /// before DeviceRuntime spawns the helper. No live NOR writer is hosted here.
    public static func admitBoot(device: URL, managed: Bool, executable: URL) async throws -> Bool {
        let data = try await run(
            FirmwareCommand.BootAdmit(
                device: device,
                recordPolicy: managed ? .managed : .standalone,
                allowRaw: !managed
            ),
            executable: executable
        )
        let report = try JSONDecoder().decode(FirmwareWire.BootAdmission.self, from: data)
        guard report.event == "admitted" else {
            throw DeviceToolsError.failed("The firmware worker did not admit this device.")
        }
        return report.changed
    }

    /// iPhone OS 1.x: `certificate` (DER) as a system anchor in the stopped device (`firmwarekit edit --action
    /// trust-anchor`, a stopped edit through the 1.x FTL). Nothing when the device already trusts it.
    public static func trustAnchor(device: URL, certificate: URL, executable: URL) async throws -> Bool {
        let data = try await run(
            FirmwareCommand.Edit(device: device, action: .trustAnchor, recordPolicy: .managed, cert: certificate),
            executable: executable
        )
        struct Report: Decodable { let changed: Bool }
        return try JSONDecoder().decode(Report.self, from: data).changed
    }

    public static func run(_ command: some FirmwareCommandLine, executable: URL) async throws -> Data {
        let child = try await Subprocess.run(
            .path(FilePath(executable.path)),
            arguments: Arguments(command.arguments),
            input: .none,
            output: .string(limit: 65536),
            error: .string(limit: 65536)
        )
        guard child.terminationStatus == .exited(0) else {
            throw DeviceToolsError.failed(child.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Data(child.standardOutput.utf8)
    }
}
