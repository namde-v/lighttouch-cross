#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import DeviceRuntime
import Foundation

// A stand-in helper for DeviceRuntimeTests: creates the status block, stamps a
// sentinel heartbeat, and sends the new-transport hello (the shm fd over the
// link socket, fd 3, exactly like a real helper) with <token>; then exits
// ("exit") or stays until killed ("stay").

#if os(Windows)
// Windows helper: the link socket is the connected socket the app passed via
// ltm_spawn; its numeric value arrives in LTM_LINK_SOCKET. Winsock needs
// WSAStartup in this process too (the C layer does not do it).
var wsadata = WSADATA()
guard WSAStartup(0x0202, &wsadata) == 0 else { exit(1) }
guard let linkValue = ProcessInfo.processInfo.environment["LTM_LINK_SOCKET"],
      let linkSocket = UInt64(linkValue)
else { exit(64) }
let arguments = CommandLine.arguments
guard arguments.count == 3 else { exit(64) }
// The status segment carries the C-contract hello name, so the app's
// ltm_recv_hello can re-open it by name (see TRANSPORT_REDESIGN.md).
let status = StatusBlock.create(mappingName: ShmSurface.helloMappingName(token: arguments[1], index: 0))
status[.heartbeat] = 7
let rc = DeviceRendezvous.sendHello(socket: Int32(truncatingIfNeeded: linkSocket), token: arguments[1], generation: 0, segments: [status.surface])
guard rc == 0 else { exit(1) }
if arguments[2] == "stay" {
    while true { Sleep(60_000) }
} else {
    // Linger so the app can open the named mapping before this process exits:
    // a named mapping dies with its creator's last handle, and the app opens
    // it only after reading the hello (POSIX has no such race — SCM_RIGHTS
    // gives the app its own fd reference). 2 s is far more than the app's
    // millisecond-scale accept + recv + open.
    Sleep(2_000)
}
exit(0)
#else
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
#endif
