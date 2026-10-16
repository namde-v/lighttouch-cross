# FirmwareKit — Linux Port Shim Notes

Every deviation from the macOS upstream, why it exists, and what is deferred.
Upstream lives at `~/workspace/lighttouch-cross/upstream/` and was never touched.

## Build environment

- Swift 6.4.1 via swiftly (`/home/hatch/.local/share/swiftly/toolchains/6.4.1/usr/bin` on `PATH`,
  `TMPDIR=/home/hatch/.cache/swift-tmp`). The `~/.local/share/swiftly/bin` shim is broken in this VM
  (looks for config under `/root/`); do not use it.
- 2 vCPU / ~1.4 GB RAM, no swap: always `swift build -j 1` (`-j1` is a different, wrong flag).
  `libsqlite3-dev` was installed via apt for the `CSQLite3` target (`zlib1g-dev` was already present).

## Package.swift

- Added `swift-crypto` (from 3.15.1, `.product(name: "Crypto", package: "swift-crypto")`) for the
  CryptoKit → Crypto migration, and `swift-system` (from 1.8.1, `SystemPackage`) for `import System`.
- Added system targets `CZlibFK` (`Sources/CZlibFK/module.modulemap` + `shim.h`, `link "z"`,
  `pkgConfig: "zlib"`) and `CSQLite3` (`Sources/CSQLite3/`, `link "sqlite3"`, apt provider
  `libsqlite3-dev`). Named `CZlibFK`, not `CZlib`: HostRuntime already vends a Clang module named
  `CZlib`, and ZIPFoundation (a dependency) vends another — module names must be unique across the
  package graph (see "Cross-package: HostRuntime CZlib → CZlibHost" below). Same for `CSQLite3`,
  which avoids any future clash with other SQLite shims.
- `import zlib` → `import CZlibFK`, `import SQLite3` → `import CSQLite3` everywhere (41+ sites).
- `import CryptoKit` → `import Crypto` (mechanical, all Sources and Tests).
- `platforms: [.macOS(...)]` removed (done before this port session).

## Crypto (CommonCrypto → swift-crypto)

- IMG3's AES-CBC now uses `AES._CBC.decrypt/encrypt(..., noPadding: true)` from `_CryptoExtras`;
  VFDecrypt's key unwrap uses `HMAC<Insecure.SHA1>.authenticationCode` + `AES._CBC.decrypt`.
  Covered by `VFDecryptTests.synthetic` and the IMG3 tests.

## Darwin → Glibc / WinSDK

All files that imported Darwin now use the 3-way conditional
(`#if os(Linux) import Glibc / #elseif os(Windows) import WinSDK / #else import Darwin`),
the same pattern HostRuntime uses.

## `import MachO` (Swift's Darwin-only overlay) → MachOKit

- `import MachO` removed from `Activation.swift`. The `MachOImage(ptr:)` + `mach_header` parsing
  now goes through MachOKit (already a dependency, already Linux-clean): MachOKit's
  `MachOImage.LoadCommands` is a `Sequence<LoadCommand>`, which fits the existing
  `codeSignature(_: some Sequence<LoadCommand>)` helper unchanged.

## AppleArchive — honest gap, NOT reimplemented

`GuestArchive.extract` decodes `.aar` files produced by macOS's `/usr/bin/aa`. Investigation:
- The Apple Archive format is proprietary and undocumented; the only non-Apple decoder found is an
  8-day-old, 1-star Rust project — not something to take as a Swift dependency.
- Neither libarchive nor any Swift package implements it; a from-scratch reimplementation would
  mean reverse-engineering a proprietary container format with no spec and no test corpus here.
- `extract` is now `#if canImport(AppleArchive)`-gated; on other platforms it throws
  `CocoaError(.featureUnsupported)` with a message saying guest `.aar` extraction needs macOS.
- Everything around it (seeding, hooks, offers) builds and runs; only the `.aar` decode step
  itself is unavailable. Deferred until a portable decoder exists.

## Carbon (TIS keyboard enumeration) → protocol

- New `HostKeyboardSource` protocol. `CarbonKeyboardSource` (macOS) keeps the original TIS code;
  `StubKeyboardSource` (Linux/Windows) returns `[]`. `SystemEdits.keyboardSource` is now a computed
  property selecting the right one. Real Linux keyboard enumeration (xkbcommon) is deferred —
  nothing in the current pipeline consumes a non-empty list on Linux.

## Compression framework → zlib

- The one `compression_decode_buffer(..., COMPRESSION_ZLIB)` call site (HFSPlus decmpfs inflate)
  now uses a small `rawInflate(_:max:what:)` helper over `CZlibFK` (`inflateInit2` with `-MAX_WBITS`).
- Tests: `NSData.compressed(using: .zlib)` is Apple-only. `FitCheckTests.deflateRaw` compresses with
  `Compression` on Apple platforms and with `CZlibFK` `deflateInit2_` (`-MAX_WBITS`, i.e. raw deflate
  — Apple's `.zlib` is raw deflate too; the test prepends the 2-byte zlib header itself, which
  `GuestPack.read` strips) on Linux.

## Disk images: hdiutil/diskutil → Linux backend

`DiskImage` had a `FIRMWAREKIT_DISK_IMAGE` env seam; a `.linux` backend is now wired behind it:
- attach/detach via `losetup`, listing via `losetup --list --json` (`parseLinuxAttachments`),
  resize via `truncate`, DMG→raw via `dmg2img`.
- `dmg2img` and `hfsprogs` are NOT installed in this VM and there are no loop devices, so the
  convert/mount paths are compile-verified but not integration-tested here. Documented as deferred.
- Pure functions (`parseAttach`, `parseLinuxAttachments`) have unit tests (`DiskImageTests.linuxBackend`).
- macOS-only test cases (`backends`, `backendsAgree`, `detachAllUnderRoot`, `convertToRaw`) are
  `#if os(macOS)`-gated.

## VolumeMount (mount/hdiutil)

- Linux: `mount -t hfsplus` / `umount` wired (needs root + hfsplus support; not exercised in this VM).
- `check` and `makeHFS` are honest `.unsupported` stubs — the exact `hfsprogs` spellings are
  unverified, so they throw instead of running a guessed command line.
- macOS-only tests (`contentProtection`, `busyVolumeIsDetached`, `folderCountsAloneAreRepaired`,
  `cancelledAttach…`, `cancelledMountedBody…`) are `#if os(macOS)`-gated.

## FSEvents

No FSEvents call sites exist in FirmwareKit's Sources or Tests (verified by grep), so no
inotify abstraction was needed. Nothing deferred.

## clonefile → copy fallback

- `StoppedVolumeEdit` and `VolumeExport`: `clonefile` replaced with FileManager copy fallback
  (same semantics the tests need; APFS clone acceleration is macOS-only).
- `BootRecipe.cloneFile(from:to:)` in HostRuntime (FICLONE-or-copy) is used where available.
- Tests calling `clonefile`/`setxattr` directly use `Tests/FirmwareKitTests/LinuxShims.swift`:
  a Linux `clonefile` shim (copy semantics) and a `setxattr` shim over the `lsetxattr`
  `@_silgen_name` declaration in `StoppedVolumeEdit.swift` (the tests pass position/options 0).

## xattr / chflags / FULLFSYNC

- `sys/xattr.h` is absent from Swift's Glibc overlay: `llistxattr`/`lgetxattr`/`lsetxattr` are
  declared via `@_silgen_name`; `ENODATA` stands in for `ENOATTR` on Linux.
- `chflags` is a no-op on Linux (no equivalent); `UF_COMPRESSED` defined as `0x20` where needed.
- `F_FULLFSYNC` → plain `fsync` on Linux.

## Preparer (proc_listchildpids / proc_pidinfo)

Reimplemented on Linux via `/proc`: child PIDs from `/proc/<pid>/task/<pid>/children`, start time
from `stat` field 22, `sysconf(_SC_CLK_TCK)`, zombie check on state `Z`.

## POSIX spellings

- `URLSession.shared` → `URLSession(configuration: .default)` + `import FoundationNetworking`
  (`SourceFetch.download`).
- `StorageCapacity`: the important-usage key is `#if canImport(Darwin)`-gated.
- `memmem` (GLIDispatch, K48NAND): Glibc takes non-optional pointers — unwrapped for both platforms.
- `SEEK_DATA`/`SEEK_HOLE` (K48NAND): not in Swift's Glibc overlay; local `Int32` constants
  (3 and 4, from Linux `stdio.h`).
- `SOCK_STREAM` (N72Keybag GDBRemote): Glibc imports it as `__socket_type`, not `Int32` —
  `Int32(SOCK_STREAM.rawValue)` on Linux (HostRuntime's DebugPort hit the same).
- `Darwin.close/write/send` → file-private `posixClose`/`posixWrite`/`posixSend` helpers
  (StorageGeneration, K48NAND, N72Keybag) — the types' own methods shadow the POSIX globals, so
  the old `Darwin.` qualification became per-platform helpers.
- `sockaddr_in.sin_len`: set only `#if canImport(Darwin)`.
- `DispatchSourceProcess` (FirmwareKitCLI `CommandLifetime`): swift-corelibs-libdispatch never
  ported process sources. On Linux the parent's death is polled for (1 s `getppid()` check in a
  `@MainActor` task, cancelled in `cancel(_:)`); macOS keeps the dispatch source.
- `mode_t` is `UInt16` on Darwin but `UInt32` on Linux: `SystemEdits.put(..., mode: mode_t(r.mode) & 0o7777)`.
- Linux `struct stat` has no `st_flags`: tests default flags to 0 on Linux.
- `NSDictionary.write(to:)` → `write(to:atomically:)`; `value(forKeyPath:)` (Apple-only) replaced
  with manual nested-dictionary walks in `SystemEditsTests`.

## Cross-package: HostRuntime CZlib → CZlibHost

Building FirmwareKit failed with `redefinition of module 'CZlib'`: SwiftPM passes every transitive
system target's modulemap to each dependent target, and HostRuntime's `CZlib` module collided with
ZIPFoundation's own `CZlib` module. Target names must also be unique across the package graph.
Fix (in `../HostRuntime`, 2026-10-15): renamed target+module `CZlib` → `CZlibHost`
(`Sources/CZlibHost/`, `import CZlibHost` in `LTMInflate.swift` and `GuestPack.swift`,
`Package.swift` target name + dep, note in HostRuntime's `SHIM_NOTES.md`). No behavior change —
same shim over the platform zlib. HostRuntime rebuilt and its full suite re-run: 52 passed,
1 pre-existing conditional skip (`closedOwnerCannotCloseReusedDescriptor`, needs
`FK_ISOLATED_DESCRIPTOR_REUSE=1`), 0 failures. FirmwareKit's own shim is `CZlibFK` for the same
reason. This was the only change made outside `Packages/FirmwareKit`.

## Deferred / not tested here

- Real xkbcommon keyboard enumeration (stub returns `[]`).
- `hfsprogs` `check`/`makeHFS` spellings (honest `.unsupported` stubs).
- `dmg2img` convert path and loop-mount integration tests (no loop devices / not installed in this VM).
- Guest `.aar` extraction on Linux (AppleArchive gap above).

## Test-environment findings (2026-10-15)

- **Run tests with `umask 022`.** This container's default umask is 0007, which breaks
  `PreparedBaseTests.unpackGivesEachDeviceTheIdentityCreateWould` (expects `nor.bin == 0o444`,
  i.e. a 022-created file after `readOnly`). Not a code bug.
- **The Swift test runner blocks nearly all signals** (`SigBlk` is `fffffffe3bfbea27`, incl.
  SIGTERM/SIGCHLD), and `posix_spawn`'d children inherit the mask — SIGTERM stays pending forever.
  `PreparerTests.terminatesDescendants` unblocks all signals around its `posix_spawn` (restoring the
  runner's mask afterwards) so the child gets a working mask. The `/proc` sweep itself was verified
  correct standalone; without the unblock the test cannot work under this runner.
- **corelibs-foundation ignores `.mutableContainersAndLeaves`**: `PropertyListSerialization`
  returns Swift `Dictionary`/`Array`, never `NSMutableDictionary`. `SystemEdits.rewritePlist`
  deep-converts to mutable Foundation containers on Linux (`mutablePlistValue`); all mutation
  sites go through it. (`NSMutableDictionary(contentsOf:)` does return a real mutable dictionary.)
- **`tar -x` as root tries `--same-owner`; this container cannot `chown` even as uid 0**
  (btrfs/EPERM), so `SystemEdits.installCydia`'s extract adds `--no-same-owner` on Linux.
- **`port/LightTouchMac/Resources/firmware-catalog.json`** (1.2 MB) was copied from the pristine
  upstream: the tests resolve it relative to the repo root (`Oracle.catalog`) and treat a missing
  catalog as a failure, not a skip. The port tree has no `LightTouchMac/` app dir yet.
- Mount-dependent integration tests are `#if os(macOS)`-gated: the 5 `VolumeMountTests`, the 4
  `DiskImageTests`, plus `N45FTLTests.stoppedEditInPlace` and `HFSPlusNameTests.slashInCatalogName`
  (both need `VolumeMount.withMounted`; this VM has no loop devices).
- **`StorageRecordPaths.recordPath` double-slash (HostRuntime, fixed 2026-10-16)**: the prefix was
  `relativeRoot.path + "/"`, i.e. `"//"` when the device sits directly under `/tmp`, which no path
  matches — every `publish` threw `.invalidRecord` with `TMPDIR=/tmp`. Now keeps a trailing slash
  as-is. Found via FirmwareKit's `StorageGenerationTests`.
- **`plistEdits` force-cast crash**: the test did `propertyList(...) as! NSMutableDictionary`; on
  Linux corelibs returns a Swift `Dictionary`, so the cast traps (SIGABRT). The test now routes
  through `SystemEdits.mutablePlistValue` (made internal) on Linux.
- **`TrustStore1xTests.trustsThroughAStoppedEdit`** is `.enabled(if:)`-gated to macOS: it needs
  `VolumeMount.makeHFS`/`withMounted`, and Linux `makeHFS` is an honest `.unsupported` stub.
- **`JailbreakTests.cydoKeepsItsSetUserIDMode`** is `.enabled(if:)`-gated on the temp dir actually
  keeping the setgid bit: this container's default TMPDIR filesystem (btrfs/overlay) strips setgid
  even though `chmod(2)` reports success, so the fixture tar records 0o4755 instead of 0o6755. Run
  with `TMPDIR=/tmp` (tmpfs) to exercise it; with the default TMPDIR it skips with a clear message.

## Deferred / not tested here

- Real xkbcommon keyboard enumeration (stub returns `[]`).
- `hfsprogs` `check`/`makeHFS` spellings (honest `.unsupported` stubs).
- `dmg2img` convert path and loop-mount integration tests (no loop devices / not installed in this VM).
- Guest `.aar` extraction on Linux (AppleArchive gap above).

## Verification

- `swift build -j 1`: green (all targets incl. FirmwareKitCLI, FirmwareSchema, CActivation C target).
- `swift test -j 1 --no-parallel` (with `umask 022`, `TMPDIR=/home/hatch/.cache/swift-tmp`):
  **236 tests in 51 suites, all passed** (exit 0, 0 failures; 166 individual cases passed).
  Skips are all legitimate: firmware-corpus tests (`FK_TEST_CORPUS=1` not set),
  `trustsThroughAStoppedEdit` (needs HFS volume tooling, macOS-only),
  `cydoKeepsItsSetUserIDMode` (needs setgid-capable TMPDIR; passes with `TMPDIR=/tmp`),
  plus fixture-gated tests (developer payload, lockdownd, release payload).
- Also verified with `TMPDIR=/tmp`: 236/236 passed (exercises the setgid test too).
