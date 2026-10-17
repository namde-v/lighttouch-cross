import Foundation

/// Preparation and launch assembly shared by the GUI and headless session callers.
/// The caller must hold the device's storage lease before calling prepare.
/// Explicit URLs are caller-selected: this component does not authorize managed
/// record paths or enforce containment. Maintenance ownership checks stay with
/// the application's storage transaction boundary.
public struct PreparedDeviceBoot {
    public enum Failure: Error, Equatable { case baseMismatch }
    private let board: Board
    private let boot: URL
    private let nand: URL
    private let baseNOR: URL
    private let writableNOR: URL?
    private let overlay: URL
    private let bootrom: String
    private let strategy: String?
    private let gidBlobs: String?
    private let dieID: String?
    private let machine: [String: String]

    public static func prepare(
        board: Board,
        base: URL,
        overlay: URL,
        writableNOR: URL?,
        storageKey: String?,
        bootrom: String,
        dieID: String? = nil,
        panel: String? = nil,
        clock: Date? = nil
    ) throws -> Self {
        let lock = try DeviceLock.read(base: base)
        let strategy = lock?.bootStrategy
        let required = try board.requiredFiles(strategy: strategy)
        let files = try BootRecipe.preparedFiles(
            base: base,
            overlay: overlay,
            writableNOR: writableNOR,
            boot: required.boot,
            also: required.files
        )
        if !board.isKBoot, files.writableNOR == nil {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "writable NOR"])
        }
        if board.isKBoot {
            _ = try BootRecipe.preparedIPadBoot(
                strategy: strategy,
                image: files.boot.path,
                writableNOR: files.writableNOR?.path,
                gidBlobs: base.appendingPathComponent("gid-blobs.bin").path
            )
        }
        if let storageKey, try !pinOverlay(overlay, toBase: storageKey) { throw Failure.baseMismatch }
        let identityURL = base.appendingPathComponent("identity.json")
        let identity = (try? Data(contentsOf: identityURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let unitDieID = dieID ?? (identity?["die-id"] as? [String])?.joined(separator: ":")
        return Self(
            board: board,
            boot: files.boot,
            nand: files.nand,
            baseNOR: base.appendingPathComponent("nor.bin"),
            writableNOR: files.writableNOR,
            overlay: overlay,
            bootrom: bootrom,
            strategy: strategy,
            gidBlobs: board.soc == .s5l8900 ? nil : base.appendingPathComponent("gid-blobs.bin").path,
            dieID: unitDieID,
            machine: (lock?.machineOptions(base: base) ?? [:]).merging(
                (panel.map { ["panel": $0] } ?? [:])
                    // Tweaks' Time Machine: the PMU's clock (and the agent's time sync) start at that moment.
                    .merging(clock.map { ["rtc-epoch": String(Int64($0.timeIntervalSince1970))] } ?? [:]) { $1 }
            ) { $1 }
        )
    }

    /// Explicit adapter for pre-library N72 regression fixtures with separate images.
    /// Prepared device records always use prepare; no firmware policy is inferred here.
    public static func legacyN72(
        nand: URL,
        nor: URL,
        iBoot: String,
        gidBlobs: String?,
        machine: [String: String],
        overlay: URL,
        bootrom: String
    ) throws -> Self {
        let destination = try writableNOR(base: nor, overlay: overlay)
        return Self(
            board: .n72,
            boot: URL(fileURLWithPath: iBoot.isEmpty ? "nor.bin" : iBoot),
            nand: nand,
            baseNOR: nor,
            writableNOR: destination,
            overlay: overlay,
            bootrom: bootrom,
            strategy: iBoot.isEmpty ? "bootrom" : "iboot",
            gidBlobs: gidBlobs,
            dieID: nil,
            machine: machine
        )
    }

    /// Legacy raw-image fixtures use an exact 1 MiB private NOR copy.
    public static func writableNOR(base: URL, overlay: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
        let destination = overlay.appendingPathComponent("nor.bin")
        if !fm.fileExists(atPath: destination.path) {
            let staged = overlay.appendingPathComponent(".nor-\(Foundation.UUID().uuidString).tmp")
            defer { try? fm.removeItem(at: staged) }
            try fm.copyItem(at: base, to: staged)
            let size = try fm.attributesOfItem(atPath: staged.path)[.size] as? NSNumber
            guard size?.intValue == 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            let handle = try FileHandle(forWritingTo: staged)
            defer { try? handle.close() }
            try handle.synchronize()
            try fm.moveItem(at: staged, to: destination)
        }
        let attributes = try fm.attributesOfItem(atPath: destination.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.size] as? NSNumber)?.intValue == 1_048_576
        else { throw CocoaError(.fileReadCorruptFile) }
        return destination
    }

    public static func pinOverlay(_ overlay: URL, toBase identity: String) throws -> Bool {
        let fm = FileManager.default
        let stamp = overlay.appendingPathComponent(".base-identity")
        let contents = (try? fm.contentsOfDirectory(atPath: overlay.path)) ?? []
        if contents.isEmpty {
            try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
            try Data(identity.utf8).write(to: stamp, options: .atomic)
            return true
        }
        return (try? String(contentsOf: stamp, encoding: .utf8)) == identity
    }

    /// The writable NOR's path; prepare requires one for every board but the iPads.
    private func writableNORPath() throws -> String {
        guard let writableNOR else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "writable NOR"]) }
        return writableNOR.path
    }

    /// `hardware`: the emulator's facts about the board (its hello's DeviceInfo; else Machines'): the -M machine,
    /// the modem, the USB host.
    public func configuration(
        hardware: DeviceInfo? = nil,
        bootArgs: String,
        usbAddress: String?,
        wifi: Bool,
        guestPackage: String?,
        serial: String,
        audio: [String],
        netdev: String?,
        restore: [String] = [],
        webProxy: WebProxyEndpoint? = nil,
        cellular: BootRecipe.Cellular = .on,
        carrier: CarrierSettings? = nil,
        refreshHz: Int = 60
    ) throws -> BootConfig {
        guard let hardware = hardware ?? board.hardware else {
            throw CocoaError(
                .featureUnsupported,
                userInfo: [NSLocalizedDescriptionKey: "The emulator library has no machine for \(board.rawValue)."]
            )
        }
        var config: BootConfig
        switch board.soc {
        case .s5l8900:
            config = BootRecipe.iPod1G(
                .init(
                    bootrom: bootrom,
                    iBoot: boot.path,
                    nand: nand.path,
                    writableNOR: try writableNORPath(),
                    overlay: overlay.path,
                    usbAddress: usbAddress,
                    wifi: wifi,
                    guestPackage: guestPackage,
                    machineOptions: machine
                ),
                hardware: hardware,
                serial: serial,
                audio: audio,
                netdev: netdev
            )
        case .s5l8720:
            config = BootRecipe.iPod(
                .init(
                    bootArgs: bootArgs,
                    iBoot: strategy == "bootrom" ? "" : boot.path,
                    bootrom: bootrom,
                    nand: nand.path,
                    nor: baseNOR.path,
                    writableNOR: try writableNORPath(),
                    overlay: overlay.path,
                    usbAddress: usbAddress,
                    wifi: wifi,
                    gidBlobs: gidBlobs,
                    guestPackage: guestPackage,
                    machineOptions: machine
                ),
                hardware: hardware,
                serial: serial,
                audio: audio,
                netdev: netdev,
                restore: restore
            )
        case .s5l8920, .s5l8930:
            let bootPath = try BootRecipe.preparedIPadBoot(
                strategy: strategy,
                image: boot.path,
                writableNOR: writableNOR?.path,
                gidBlobs: gidBlobs
            )
            var ipad = BootRecipe.IPad(
                boot: bootPath,
                nand: nand.path,
                overlay: overlay.path,
                dieID: dieID,
                usbAddress: usbAddress,
                wifi: wifi,
                guestPackage: guestPackage,
                machineOptions: machine
            )
            ipad.cellular = cellular
            config = BootRecipe.iPad(
                ipad,
                hardware: hardware,
                serial: serial,
                audio: audio,
                netdev: netdev,
                restore: restore
            )
        }
        // The device's saved Carrier panel settings: the modem starts with them (radio boards only).
        if let carrier, hardware.hasCellular { config.argv += carrier.globals }
        // The SIM keeps its PIN, PUK and tries left with the device's own state, as a card in the tray does.
        if hardware.hasCellular {
            config.argv += ["-global", "ios-baseband.sim-file=\(overlay.appendingPathComponent("sim").path)"]
        }
        config.argv += board.refreshGlobals(refreshHz)
        config.webProxy = webProxy
        return config
    }
}
