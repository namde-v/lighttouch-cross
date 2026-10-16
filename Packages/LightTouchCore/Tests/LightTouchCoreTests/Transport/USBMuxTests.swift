import Foundation
import Testing

@testable import LightTouchCore

/// usbmuxd that dies is started again on the sockets the emulator dials, a few times; given up, a new boot starts it.
struct USBMuxTests {
    /// State audit A-11: an unexpected daemon death left app management off until Force Stop then Start.
    @Test func aDaemonThatDiesStartsAgainOnItsSockets() async throws {
        try await withScratchDirectory { directory in
            let starts = directory.appendingPathComponent("starts")
            let daemon = directory.appendingPathComponent("usbmuxd")
            try "#!/bin/sh\necho \"$USBMUXD_QEMU_ADDR\" >> '\(starts.path)'\nsleep 0.2\n".write(
                to: daemon,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemon.path)
            let paths = DeviceInstance.Paths(
                directory: directory,
                base: directory,
                overlay: directory,
                writableNOR: nil,
                snapshot: directory.appendingPathComponent("snapshot"),
                usbmuxConf: directory.appendingPathComponent("conf"),
                work: directory.appendingPathComponent("work"),
                logs: directory.appendingPathComponent("logs")
            )
            func launches() -> [String] {
                ((try? String(contentsOf: starts, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            }
            var gaveUp = false
            let mux = USBMux(binary: daemon.path) { gaveUp = true }
            let session = try #require(mux.start(paths: paths))
            await eventually("started again") { launches().count >= 2 }
            #expect(mux.session?.guestAddress == session.guestAddress, "the same sockets")
            await eventually("given up") { gaveUp }
            // Settle: under batch load a restart in flight can land after
            // gaveUp is set; the limit (not the exact moment) is what's under test.
            try? await Task.sleep(for: .milliseconds(500))
            #expect(launches().count == 1 + USBMux.restartLimit && mux.session == nil)
            #expect(Set(launches()) == [session.guestAddress])

            mux.ensureRunning()
            #expect(mux.session?.guestAddress == session.guestAddress, "a new boot starts it on the same sockets")
            await eventually("started for the new boot") { launches().count == 2 + USBMux.restartLimit }
            mux.stop()
        }
    }

    /// A crashed app's daemons are reparented to launchd and outlive it; launch reaps every device's orphan (one
    /// lasted until its device happened to start again), never a daemon whose parent is alive.
    @Test func launchReapsOrphanedDaemons() async throws {
        try await withScratchDirectory { state in
            let source = state.appendingPathComponent("daemon.c")
            // One binary, two modes: "orphan" self-detaches (the parent
            // prints the daemon's pid and exits at once; the daemon closes
            // every inherited fd so the test's pipe sees EOF promptly, then
            // is reparented to init), otherwise it just sleeps as the
            // caller's child. A shell `&` background is racy here: the daemon
            // briefly inherits the pipe's write end, hanging the read below
            // for its whole lifetime on some runs.
            try """
                #include <unistd.h>
                #include <fcntl.h>
                #include <string.h>
                #include <signal.h>
                int main(int argc, char **argv) {
                    // Swift's Process spawns children with SIGTERM (and more)
                    // blocked; a daemon that inherits that mask never dies
                    // from the reaper's SIGTERM. Unblock everything up front.
                    sigset_t unblock;
                    sigemptyset(&unblock);
                    sigprocmask(SIG_SETMASK, &unblock, NULL);
                    if (argc > 1 && strcmp(argv[1], "orphan") == 0) {
                        pid_t daemon = fork();
                        if (daemon != 0) {
                            char buf[16]; int n = 0; pid_t p = daemon; char rev[16]; int r = 0;
                            if (p == 0) rev[r++] = '0';
                            while (p > 0) { rev[r++] = '0' + (p % 10); p /= 10; }
                            while (r > 0) buf[n++] = rev[--r];
                            write(1, buf, n);
                            return 0;
                        }
                        setsid();
                        long maxfd = sysconf(_SC_OPEN_MAX);
                        for (long fd = 3; fd < maxfd; fd++) close((int)fd);
                        int d = open("/dev/null", O_RDWR);
                        if (d >= 0) {
                            dup2(d, 0); dup2(d, 1); dup2(d, 2);
                            if (d > 2) close(d);
                        }
                    }
                    sleep(60);
                    return 0;
                }
                """.write(to: source, atomically: true, encoding: .utf8)
            let daemon = state.appendingPathComponent("usbmuxd")
            try LibraryFixtures.run("/usr/bin/cc", ["-o", daemon.path, source.path])
            func device() throws -> (DeviceInstance, URL) {
                let id = UUID()
                let instance = DeviceInstance(
                    id: id,
                    name: "device",
                    board: "n72ap",
                    firmware: "ipod-3.1.3",
                    created: .now,
                    base: .init(kind: .prepared, path: "Devices/\(id)/base"),
                    storage: .init(
                        key: id.uuidString,
                        overlay: "Devices/\(id)/overlay",
                        snapshot: "Devices/\(id)/snapshot",
                        usbmuxConf: "Devices/\(id)/usbmuxd-conf"
                    )
                )
                let pidFile = instance.paths(state: state, logs: state).usbmuxPID
                try FileManager.default.createDirectory(
                    at: pidFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                return (instance, pidFile)
            }
            // The orphan: the "orphan" mode detaches; its parent prints the daemon's pid and exits at once.
            let orphan = try #require(
                pid_t(
                    try LibraryFixtures.run(daemon.path, ["orphan"])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
            await eventually("reparented") { StorageLocations.daemonIdentity(orphan)?.parent == 1 }
            let (crashed, crashedPID) = try device()
            try "\(orphan)\n".write(to: crashedPID, atomically: true, encoding: .utf8)
            // A running app's daemon: its parent (this process) is alive.
            let owned = Process()
            owned.executableURL = daemon
            try owned.run()
            defer { owned.terminate() }
            let (running, runningPID) = try device()
            try "\(owned.processIdentifier)\n".write(to: runningPID, atomically: true, encoding: .utf8)

            #expect(USBMux.reapOrphans([crashed, running], state: state, logs: state) == [orphan])
            await eventually("the orphan exited") { StorageLocations.daemonIdentity(orphan) == nil }
            #expect(owned.isRunning && FileManager.default.fileExists(atPath: runningPID.path))
            #expect(!FileManager.default.fileExists(atPath: crashedPID.path))
        }
    }
}
