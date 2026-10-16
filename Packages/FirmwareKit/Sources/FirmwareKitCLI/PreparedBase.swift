// firmwarekit pack-base --base DIR --out BLOB             a create output as one blob (the release build)
// firmwarekit unpack-base --blob BLOB --out DIR --seed S  that blob as a device of its own (the app, like create:
//                                                         JSON Lines on stdout, done names the lock)

import FirmwareKit
import FirmwareSchema
import Foundation

func packBaseCommand(_ command: FirmwareCommand.PackBase) -> Never {
    do {
        try PreparedBase.pack(base: URL(fileURLWithPath: command.base), to: URL(fileURLWithPath: command.out))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("firmwarekit pack-base: \(error)\n".utf8))
        exit(1)
    }
}

func unpackBaseCommand(_ command: FirmwareCommand.UnpackBase) async -> Int32 {
    let staging = URL(fileURLWithPath: command.out)
    do {
        emit(.begin(steps: 2))
        emit(.step(index: 1, name: "Unpacking"))
        try PreparedBase.unpack(URL(fileURLWithPath: command.blob), into: staging) { fraction in
            try Task.checkCancellation()
            emit(.progress(fraction))
        }
        emit(.step(index: 2, name: "Writing the identity"))
        try PreparedBase.reseed(staging, seed: command.seed)
        emit(.done(lock: "device.lock.json"))
        return 0
    } catch {
        if Task.isCancelled { return 143 }
        FirmwareDiagnostics.write(Data("firmwarekit: \(error)\n".utf8))
        emit(Preparer.errorEvent(error))
        return 1
    }
}
