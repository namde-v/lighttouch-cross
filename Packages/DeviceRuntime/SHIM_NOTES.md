# DeviceRuntime — Linux port shim notes

Deviations from `upstream/` made so this package builds and tests green on
Linux (Swift 6.4.1, Ubuntu 24.04). Nothing under `upstream/` was touched.
Every change below is in `port/Packages/DeviceRuntime` only. The transport
itself was redesigned (see TRANSPORT_REDESIGN.md); these are the remaining
per-change deviations.

## 1. `Sources/LTMShm/` replaces `Sources/LTMLinkC/`

- The atomics (`ltm_load`/`ltm_store`/`ltm_load_seq`/`ltm_store_seq`/`ltm_add`)
  are unchanged (`__atomic_*` builtins are GCC/Clang-portable).
- The Mach rendezvous (`ltm_check_in`/`ltm_send_hello`/`ltm_recv_hello` over
  Mach ports, `bootstrap_check_in`) is deleted. The new `ltm_send_hello` /
  `ltm_recv_hello` move a fixed 112-byte header plus 1 or 4 shm fds via
  `SCM_RIGHTS` on the link socket, with `poll()` timeouts, `MSG_NOSIGNAL`
  sends, and a sender-pid check via `SCM_CREDENTIALS` (`SO_PASSCRED` is set
  on the receiving socket; `SO_PEERCRED` would report the socketpair's
  creator, not the child).
- `ltm_spawn` is kept, minus Mach: glibc has no
  `POSIX_SPAWN_CLOEXEC_DEFAULT`, so the "nothing else inherited" behavior is
  emulated by enumerating `/proc/self/fd` in the parent and adding
  `posix_spawn_file_actions_addclose` for every fd except 0,1,2,3 (the dup2
  targets are queued first, so stdio and the link socket survive). Negligible
  TOCTOU if an fd is closed between the enumeration and the spawn.
- New: `ltm_monotonic_ns()` (`CLOCK_MONOTONIC`, nanoseconds).
- `_WIN32` hits `#error`: the Windows transport (named file mappings) is not
  implemented yet, and a loud failure beats a silent wrong one.

## 2. `SharedStatus.swift`: IOSurface -> `ShmSurface`

- `ShmSurface` wraps one POSIX shm segment (`shm_open(O_CREAT|O_EXCL)` +
  `ftruncate` + `mmap`, mode 0600). The name is unlinked immediately after
  creation: no named segment outlives a crashed helper; the app needs only
  the fd from the hello. Helper side keeps the fd open for the hello, then
  drops it; the mapping persists independently.
- `makeSurface` is gone; `ShmSurface.createStatus()` / `.createFrame(width:height:)`
  (helper side) and `.open(fd:byteCount:width:height:bytesPerRow:)` (app side).
- `StatusSlot`, `SharedStatus`, `QemuState`, `GuestPackageReport`, the slot
  offsets, `magic`/`layoutVersion`, and the `front`/`frameSerial`/`held`
  seq-cst handshake are byte-for-byte unchanged.
- vImage alpha-opaque blit -> a plain loop (`row[x] |= 0xFF00_0000`,
  little-endian BGRA). Same result, no Accelerate.
- `mach_absolute_time()` -> `ltm_monotonic_ns()`. Same role (stall
  detection); not wall time.
- The sRGB ICC tagging (`CGColorSpace.sRGB.copyICCData()` +
  `IOSurfaceSetValue(kIOSurfaceColorSpace)`) is deleted. There is no color
  management on this path; every consumer must treat the BGRA bytes as sRGB,
  as documented on `ShmSurface` and in TRANSPORT_REDESIGN.md. On a wide-gamut
  Linux compositor the guest's red will render as the display's red, exactly
  the artifact the tag used to prevent on macOS.
- `isInUse` used to also reflect Core Animation's asynchronous use of a
  surface; now it is the writer's lock only (there is no external consumer).
  The `front`/`held` exclusion already keeps the reader off the writer's
  surface, so behavior is equivalent here.
- Frame segments are tightly packed (`bytesPerRow == width * 4`); the padded
  branch of `copy` is kept for API compatibility but never triggers on
  segments this writer creates.

## 3. `DeviceRendezvous.swift`: no more bootstrap/Mach/attestation

- `DeviceRendezvousServer` (shared check-in, receive thread, pid-keyed
  registrations) is deleted. `DeviceRendezvous.defaultRequirement`,
  `.teamIdentifier`, and `.check` (code-signing attestation) are deleted.
- New API: `sendHello(socket:token:generation:segments:)` (helper side, moves
  the fds) and `receiveHello(socket:token:pid:timeout:)` (app side, maps the
  segments, sizes frames from the status block). Failures are
  `DeviceRendezvousError` (timeout / helperDied / tokenMismatch /
  protocolMismatch / senderMismatch / malformed / system(errno)).
- A generation>0 hello requires the helper to have `activate()`d the ring
  first (width/height published before the hello goes out); the macOS build
  sent Mach ports whose surfaces carried their own sizes.

## 4. `DeviceLink.swift`

- `start()` now: socketpair -> `ltm_spawn` (fd 3) -> `receiveHello` on a
  background queue (the hello is the first bytes on the socket, so it must be
  taken before `LinkChannel` starts framing JSON) -> `LinkChannel` ->
  JSON `.hello` request. The old `DeviceRendezvousServer` spawn/register path
  is gone.
- `Configuration.requirement` (code-signing requirement override) is deleted;
  `HelperLaunch.Mode.connect.service` is passed as `""` (vestigial; kept for
  HostRuntime API stability).
- `DispatchSource.makeProcessSource` (no kqueue on Linux) -> a watcher thread
  blocked in `waitpid` (EINTR-retried). No exit race, so the old 10 ms
  re-poll is gone.
- `frontSurface()` now returns `ShmSurface` (was `IOSurface`); callers
  composite `surface.baseAddress` (BGRA, sRGB) themselves. Downstream GUI
  code that assigned the surface to a layer's `contents` needs its own
  compositing path.
- `deinit` no longer unregisters from a rendezvous server; the watcher thread
  still reaps, so dropping the link cannot leave a zombie.

## 5. `DeviceLinkProtocol.swift`

- `SO_NOSIGPIPE` does not exist on Linux: kept under `#if canImport(Darwin)`;
  on Linux, channel writes use `send(..., MSG_NOSIGNAL)` in an EINTR-retrying
  `writeAll` loop instead of `FileHandle.write`. (HostRuntime's PipeOutput
  instead ignores SIGPIPE process-wide because its writes go through
  DispatchIO, which has no send call to flag; here `send()` is available, so
  the suppression stays per-socket.)
- `Darwin.close` -> `ltmClose` (PlatformLibc.swift); `SOCK_STREAM` ->
  `ltmSockStream` (Glibc types it as `__socket_type`).
- The 4-byte big-endian length framing, `maxMessageBytes`, and all
  `AppMessage`/`HelperMessage` cases are untouched.

## 6. `WebProxyCA.swift`: Security.framework -> swift-crypto

- `Package.swift` gains `.package(url: "https://github.com/apple/swift-crypto.git",
  from: "3.15.1")`; the target links `Crypto` and `_CryptoExtras`
  (note: the product name is `_CryptoExtras`, with the underscore).
- `SecKey` -> `_RSA.Signing.PrivateKey`; keygen is
  `_RSA.Signing.PrivateKey(keySize: .bits2048)`; signing is
  `signature(for: Insecure.SHA1.hash(data: tbs), padding: .insecurePKCS1v1_5)`
  (still SHA-1 for iOS 3's TLS 1.0 stack).
- `SecCertificate` -> the DER bytes (`certificateDER: Data`, what
  `SecCertificateCopyData` produced). Downstream `WebProxySetup` must read
  `.certificateDER` directly instead of `SecCertificateCopyData(.certificate)`.
- The hand-rolled `DER` encoder is kept verbatim (including `pkcs8`, now
  unused); the on-disk PEM layout (`PRIVATE KEY` = PKCS#8, then
  `CERTIFICATE`) is byte-compatible with CAs the macOS build wrote, so a
  device keeps the CA its guest already trusts.
- The key/certificate match check that compared
  `SecKeyCopyExternalRepresentation` values now compares the certificate's
  subjectPublicKeyInfo against `key.publicKey.derRepresentation`.
- The `SecIdentityCreate` private-SPI hack is deleted. `identity(for:key:)`
  now returns `WebProxyLeafIdentity` (DER certificate + private key): that is
  what the future TLS-terminating proxy feeds its TLS stack as server
  certificate / server key.
- `flock`/`open`/`O_NOFOLLOW`/`inet_pton` come from Glibc; behavior (lock
  file, 0600 key file, IP-literal SAN handling) is unchanged.

## 7. `import Darwin` -> per-platform C library import

Every `import Darwin` / `import IOSurface` / `import Security` /
`import Accelerate` / `import CoreGraphics` became the standard
`#if os(Linux) import Glibc / #elseif os(Windows) import WinSDK / #else import Darwin`
block (new files: `PlatformLibc.swift`, rewritten `SharedStatus.swift`,
`DeviceRendezvous.swift`, `DeviceLink.swift`, `DeviceLinkProtocol.swift`,
`WebProxyCA.swift`, `RendezvousTestPeer/main.swift`, tests).

## 8. Tests

- `DeviceRendezvousTests.swift` (Mach hello, code-signing) deleted;
  `DeviceTransportTests.swift` covers the new transport end to end:
  spawn-peer -> SCM_RIGHTS hello -> map -> read status block (magic, layout
  version, sentinel heartbeat, helper pid); wrong-token rejection;
  in-process status/ring/alpha-blit checks; WebProxyCA prepare/load/leaf
  with the leaf's RSA/SHA-1 signature verified against the CA key.
- `RendezvousTestPeer` now links `DeviceRuntime` and exercises the real
  helper contract (shm create + `sendHello` on fd 3 with the argv token).
- No test is skipped: everything here runs headless (shm, sockets, RSA).

## What remains

- The `#elseif os(Windows)` branches (WinSDK imports, `fatalError` stubs,
  `ltm_shm.h`'s `#error`) are shaped for the Windows wave but uncompiled.
- The helper itself (LightTouchDevice, another package) must implement the
  new contract (TRANSPORT_REDESIGN.md, "What the helper must do"); nothing in
  this package spawns a real helper yet.
- Downstream breaks (other packages, other agents): `frontSurface()` returns
  `ShmSurface` not `IOSurface` (GUI compositing); `WebProxyCA.certificate` is
  now `certificateDER: Data`; `DeviceLink.Configuration.requirement` is gone;
  `DeviceRendezvousServer` / `defaultRequirement` / `teamIdentifier` /
  `check` are gone; `LTMShm` replaces `LTMLinkC`.
