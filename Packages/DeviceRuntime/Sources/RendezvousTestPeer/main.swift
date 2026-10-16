#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import DeviceRuntime

// A stand-in helper for DeviceRuntimeTests: creates the status block, stamps a
// sentinel heartbeat, and sends the new-transport hello (the shm fd over the
// link socket, fd 3, exactly like a real helper) with <token>; then exits
// ("exit") or stays until killed ("stay").

let arguments = CommandLine.arguments
guard arguments.count == 3 else { exit(64) }
let status = StatusBlock.create()
status[.heartbeat] = 7
let rc = DeviceRendezvous.sendHello(socket: 3, token: arguments[1], generation: 0, segments: [status.surface])
guard rc == 0 else { exit(1) }
if arguments[2] == "stay" {
    while true { sleep(60) }
}
exit(0)
