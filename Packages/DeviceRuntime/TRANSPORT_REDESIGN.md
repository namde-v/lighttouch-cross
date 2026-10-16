# DeviceRuntime transport redesign (Linux)

The helper<->app transport, redesigned for Linux. This is not a port: the
macOS mechanisms (IOSurface, Mach IPC, the bootstrap rendezvous, code-signing
attestation) do not exist on Linux, so the transport was rebuilt on POSIX
primitives. The wire protocol (length-framed JSON) and the status-block slot
layout are unchanged.

## Old vs new

| macOS (upstream) | Linux (this package) |
|---|---|
| `IOSurface` shared-memory framebuffer + status block | POSIX `shm_open` + `mmap` segments (`ShmSurface`) |
| `IOSurfaceCreateMachPort` per surface, moved in a Mach message | shm fds moved with `SCM_RIGHTS` ancillary data on the link socket |
| Rendezvous: helper looks up `<bundle>.devices.<pid>` in the bootstrap namespace, sends a Mach hello | No rendezvous namespace. The helper's first bytes on the link socket are the hello (token + protocol version + generation + segment sizes, with the fds attached) |
| Attestation: `SecCodeCheckValidity` against a Team-ID / designated requirement, so a random process can't squat the shared bootstrap name | None needed. The app spawns the helper itself over a private socketpair; the one-time token on the helper's argv is the authentication. A process the app did not spawn cannot hold the socket. SO_PEERCRED pid check where available (defense in depth) |
| `vImageOverwriteChannelsWithScalar_ARGB8888` forcing alpha opaque | A plain loop over the pixels |
| `mach_absolute_time()` publish ticks | `clock_gettime(CLOCK_MONOTONIC)` nanoseconds (`ltm_monotonic_ns`) |
| sRGB ICC profile tagged on each surface | No color management on this path; pixels are assumed sRGB everywhere (documented at each use) |
| `SecKeyCreateRandomKey` / `SecKeyCreateSignature` (RSA/SHA-1) | swift-crypto `_CryptoExtras` (`_RSA.Signing.PrivateKey`, `Insecure.SHA1`) |
| `SecIdentityCreate` private SPI for the TLS leaf identity | Gone. `identity(for:key:)` returns `WebProxyLeafIdentity` (DER certificate + private key) for the future TLS-terminating proxy to consume |
| `DispatchSource.makeProcessSource` for helper exit | A watcher thread blocked in `waitpid` (no kqueue on Linux; no exit race) |
| `SO_NOSIGPIPE` per descriptor | `MSG_NOSIGNAL` on `send()` (Linux); `SO_NOSIGPIPE` kept on Darwin |

## Trust model

- The app creates a `socketpair(AF_UNIX, SOCK_STREAM)`, spawns the helper
  with the child's end dup'd to fd 3 (`ltm_spawn`, which also closes every
  other inherited fd in the child), and generates a 128-bit one-time token
  passed on the helper's argv inside `HelperLaunch.Mode.connect`.
- The helper's first act must be `DeviceRendezvous.sendHello` on fd 3. The
  app's `receiveHello` validates token, protocol version, segment count, and
  the sender pid: the app sets `SO_PASSCRED` on its socket end, so the kernel
  attaches the sender's `SCM_CREDENTIALS` to the hello, and the pid must be
  the one the app spawned. (`SO_PEERCRED` cannot be used here: on a
  socketpair it reports the socket's creator — the app itself — not the
  child that later inherited the fd.)
- `HelperLaunch.Mode.connect.service` is vestigial (kept for HostRuntime API
  stability; it used to name the bootstrap service). It is passed as `""`.
- `DeviceLink.Configuration.requirement` (the code-signing requirement
  override) is gone: there is nothing to attest against anymore.

## Wire format

Unchanged, byte-for-byte:

- Control: 4-byte big-endian length + one JSON `AppMessage` / `HelperMessage`
  (`DeviceLinkProtocol.swift`). `DeviceLinkWire.protocolVersion` stays 2: the
  messages and the status slots are untouched. (The old doc comment also named
  the Mach hello as versioned; the new hello rides the link socket itself, so
  a cross-transport version skew cannot occur.)
- Status block: the `StatusSlot` enum (offsets, `magic`/`layoutVersion`) is
  identical; only the container changed (IOSurface -> 4 KiB shm).
- Frame handshake: `front` / `frameSerial` / `held` seq-cst protocol identical.

New (replacing the Mach hello):

```
ltm_shm_hello_hdr (112 bytes, then SCM_RIGHTS with 1 or 4 fds):
    char     token[64]        NUL-terminated one-time token
    uint32   protocol_version DeviceLinkWire.protocolVersion
    uint32   nsegments        1 (status only) or 4 (status + 3 frames)
    uint64   generation       ring generation; 0 = status only
    uint64   byte_counts[4]   shm size per segment, in fd order
```

Rules, enforced by `ltm_recv_hello`: the header must be the first bytes on
the socket; `nsegments` is 1 or 4; `generation == 0` iff `nsegments == 1`;
the fd count matches `nsegments`. The app sizes frame segments from the
status block's `width`/`height` slots, so the helper must `activate()` the
ring before sending a generation>0 hello.

## File layout

```
Sources/LTMShm/                 C target (replaces LTMLinkC)
    ltm_shm.h                   status-block atomics (unchanged semantics),
                                the shm hello structs + send/recv/spawn/clock API
    ltm_shm.c                   SCM_RIGHTS send/recv, SO_PEERCRED check,
                                posix_spawn with fd 3 + close-others sweep,
                                CLOCK_MONOTONIC
Sources/DeviceRuntime/
    PlatformLibc.swift          NEW: ltmClose / ltmSockStream / ltmKill helpers
    SharedStatus.swift          REWRITTEN: ShmSurface (shm segments), StatusBlock,
                                FrameRingWriter/Reader over ShmSurface, plain-loop
                                alpha blit, monotonic publish ticks
    DeviceRendezvous.swift      REWRITTEN: sendHello/receiveHello over the link
                                socket; DeviceRendezvousError; no bootstrap, no
                                Mach, no attestation
    DeviceLink.swift            REWRITTEN: spawn -> shm hello -> JSON hello;
                                watcher-thread reaping; no rendezvous server
    DeviceLinkProtocol.swift    EDITED: MSG_NOSIGNAL writes, platform close;
                                framing untouched
    WebProxyCA.swift             REWRITTEN: swift-crypto RSA/SHA-1, DER encoder
                                kept, SecIdentity SPI deleted
    DeviceSessionProcess.swift  UNCHANGED (uses DeviceLink's preserved API)
    HostInputAutomation.swift   UNCHANGED
Sources/RendezvousTestPeer/     REWRITTEN: exercises the real helper contract
                                (status shm + hello on fd 3 with argv token)
Tests/DeviceRuntimeTests/
    DeviceTransportTests.swift  REWRITTEN: end-to-end spawn->hello->map tests,
                                in-process ring tests, WebProxyCA sign/verify
```

## What the helper (LightTouchDevice) must do

The helper is a separate package, but the contract it must implement is:

1. Parse argv as `HelperLaunch` JSON; take `token` from `.connect`.
2. `StatusBlock.create()`; on ring setup: `resize`, `activate`, then
   `DeviceRendezvous.sendHello(socket: 3, token:guid generation:segments:)`
   as the very first write on fd 3 (generation 0 = status block only).
3. Speak the unchanged JSON control protocol on fd 3 afterwards.
4. `WebProxyLeafIdentity` documents what its WebProxy's TLS termination
   consumes per host (DER certificate + private key).

## Windows shape (implemented in C; Swift call sites pending)

The C transport layer (`Sources/LTMShm/ltm_shm.{h,c}`) implements the Windows
half; the Swift `#if os(Windows)` call sites are still stubbed
(`fatalError`) for the Windows wave.

- `ShmSurface`: named file mappings (`CreateFileMapping`/`MapViewOfFile`)
  replacing `shm_open`/`mmap`. Each segment is a NAMED mapping
  `"LTMShm_<token>_<index>"` (token = the one-time hello token, index 0..3);
  the name scheme is part of the C contract (see `ltm_shm.h`).
- The hello cannot carry handles (Winsock has no SCM_RIGHTS): the helper
  sends the same `ltm_shm_hello_hdr` over a loopback TCP socket (Winsock has
  no `socketpair`), and the app re-opens each segment by name with
  `OpenFileMapping` inside `ltm_recv_hello` (new `-ENOENT` error if a mapping
  is missing). The fds[] parameter to `ltm_send_hello` is ignored on Windows.
- `ltm_spawn`: `CreateProcess` with `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` so
  only the stdio handles and the link socket are inherited; the link socket
  HANDLE's numeric value is passed to the helper via the `LTM_LINK_SOCKET`
  environment variable; stdin NUL, stdout/stderr on out_fd. Returns the pid
  (a DWORD truncated to the API's int); CreateProcess failures map to
  -ENOENT/-EACCES/-EIO.
- No pid check in `ltm_recv_hello`: there is no SCM_CREDENTIALS equivalent
  for loopback sockets, so the one-time token is the authentication (the
  socket is still private to this spawn).
- `ltm_monotonic_ns`: `QueryPerformanceCounter`.
- `ltm_recv_hello` treats the caller's timeout as a total deadline for the
  whole header (select re-armed around each recv).
