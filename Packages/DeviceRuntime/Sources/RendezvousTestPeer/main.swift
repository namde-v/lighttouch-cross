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
// DIAGNOSTIC (temporary, round 2): crash-proof stage markers. Swift's print()
// to a redirected file is block-buffered, so a peer crash loses every buffered
// marker — round 1's peer log came back empty for exactly this reason (or
// because the peer died before its first print). These markers append to the
// same temp file the test dumps (path via LTM_PEER_LOG env), one
// CreateFileA/WriteFile/CloseHandle per marker, so each marker survives even
// if the peer traps right after it. Best-effort: no env path, no markers.
func peerLog(_ msg: String) {
    guard let path = ProcessInfo.processInfo.environment["LTM_PEER_LOG"], !path.isEmpty else { return }
    let bytes = Array((msg + "\n").utf8)
    path.withCString { cpath in
        // OPEN_ALWAYS is 4 (winbase.h); FILE_END is 2.
        guard let handle = CreateFileA(cpath, DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(4), DWORD(FILE_ATTRIBUTE_NORMAL), nil),
              handle != INVALID_HANDLE_VALUE else { return }
        _ = SetFilePointer(handle, 0, nil, DWORD(2))
        bytes.withUnsafeBytes { raw in
            var written: DWORD = 0
            _ = WriteFile(handle, raw.baseAddress, DWORD(raw.count), &written, nil)
        }
        CloseHandle(handle)
    }
}

// Windows helper: the link socket is the connected socket the app passed via
// ltm_spawn; its numeric value arrives in LTM_LINK_SOCKET. Winsock needs
// WSAStartup in this process too (the C layer does not do it).
peerLog("peer: starting")
var wsadata = WSADATA()
guard WSAStartup(0x0202, &wsadata) == 0 else { peerLog("peer: WSAStartup FAILED"); exit(1) }
print("peer: WSAStartup ok")
peerLog("peer: WSAStartup ok")
guard let linkValue = ProcessInfo.processInfo.environment["LTM_LINK_SOCKET"],
      let linkSocket = UInt64(linkValue)
else { peerLog("peer: no LTM_LINK_SOCKET"); exit(64) }
print("peer: LTM_LINK_SOCKET=\(linkSocket)")
peerLog("peer: LTM_LINK_SOCKET=\(linkSocket)")
let arguments = CommandLine.arguments
guard arguments.count == 3 else { peerLog("peer: argc=\(arguments.count)"); exit(64) }
peerLog("peer: argc ok")
// The status segment carries the C-contract hello name, so the app's
// ltm_recv_hello can re-open it by name (see TRANSPORT_REDESIGN.md).
let status = StatusBlock.create(mappingName: ShmSurface.helloMappingName(token: arguments[1], index: 0))
print("peer: status ok")
peerLog("peer: status ok")
status[.heartbeat] = 7
let rc = DeviceRendezvous.sendHello(socket: Int32(truncatingIfNeeded: linkSocket), token: arguments[1], generation: 0, segments: [status.surface])
guard rc == 0 else { peerLog("peer: sendHello rc=\(rc)"); exit(1) }
print("peer: sendHello rc=0")
peerLog("peer: sendHello rc=0")
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
