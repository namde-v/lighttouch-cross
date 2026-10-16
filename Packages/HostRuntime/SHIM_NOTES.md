# HostRuntime — Linux port shim notes

Deviations from `upstream/` made so this package builds and tests green on
Linux (Swift 6.4.1, Ubuntu 24.04). Nothing under `upstream/` was touched.
Every change below is in `port/Packages/HostRuntime` only.

## 1. CoreGraphics → `Sources/HostRuntime/LTMGeometry.swift` (new)

CoreGraphics is Apple-only. Audited every use site (`Board.swift`,
`DeviceInfo.swift`): geometry only — `CGSize(width:height:)`,
`CGRect(x:y:width:height:)`, `CGFloat` scalars, stored properties. No
drawing, no color, no images.

`LTMGeometry.swift` defines `CGFloat` (= `Double`, as on 64-bit Apple
platforms), `CGSize`, `CGPoint`, `CGRect`, `CGVector` with the same names
and the used API surface (`width`/`height`, `x`/`y`, `origin`/`size`,
`zero`, labeled inits, `==` via `Equatable`, plus `Hashable`, `Sendable`,
`Codable` so `Board`'s `Codable`/`Sendable` synthesis keeps compiling).

Deviation: `Codable` uses keyed containers (`"width"`/`"height"` etc.).
Board's wire format on Linux is therefore not guaranteed to match Apple's
CoreGraphics encoding. Nothing in the test suite encodes `Board`, so this
is unexercised. The `Int` overloads (`CGSize(width: Int, height: Int)` etc.)
mirror CoreGraphics' own overloads used by `DeviceInfo.screenPixels`.

The `import CoreGraphics` lines were deleted from `Board.swift` and
`DeviceInfo.swift`.

## 2. `import Darwin` → per-platform C library import

Every `import Darwin` became:

```swift
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
```

Files: `DebugPort.swift`, `PipeOutput.swift`, `Storage/HeldLease.swift`
(added — it used `strerror` without importing Darwin), `Storage/StorageLease.swift`,
`Storage/StoragePathAuthority.swift`, `Tests/.../PipeOutputTests.swift`,
`Tests/.../StorageLeaseTests.swift`.

Removed as unused: `import Darwin` in `PreparedDeviceBoot.swift` (only
`CocoaError`, which is Foundation), `Tests/.../DebugPortTests.swift`,
`Tests/.../StoppedRecordOwnerTests.swift`.

### Sharp edges

- **`F_SETNOSIGPIPE` (`PipeOutput.swift`)**: does not exist on Linux.
  Chose `signal(SIGPIPE, SIG_IGN)` installed once (a `private static let`
  token touched from `init`), NOT `MSG_NOSIGNAL`, because writes go through
  `DispatchIO`, not `send()`, so there is no send call to flag. Trade-off
  vs upstream: Darwin suppresses SIGPIPE per descriptor; the Linux version
  is process-global and inherited by spawned subprocesses. Documented in a
  code comment. The test's `F_GETNOSIGPIPE` assertion became a Linux-only
  check (via `sigaction` query) that SIGPIPE is still ignored.
- **`sin_len` (`DebugPort.swift`)**: `sockaddr_in` has no `sin_len` on
  Linux/Windows; the assignment is now `#if canImport(Darwin)`.
- **`SOCK_STREAM` (`DebugPort.swift`)**: Glibc imports it as `__socket_type`,
  not `Int32`; the `socket()` call uses `Int32(SOCK_STREAM.rawValue)` on
  Linux. (The whole function will need a rework for Winsock in the Windows
  wave — `socket()` there returns `SOCKET`, not `Int32`.)
- **`copyfile(COPYFILE_CLONE)` (`BootRecipe.swift`)**: Darwin-only. Added a
  private `BootRecipe.cloneFile(from:to:)` helper: Apple platforms keep the
  original call; Linux tries a reflink clone via the `FICLONE` ioctl
  (`0x40049409`, not in Swift's Glibc module) and falls back to a plain
  `FileManager` copy. Either way the destination exists afterwards, as the
  caller requires.
- **`Darwin.close` qualification (`StorageLease.swift`, tests)**: the
  class's own `close()` method shadows the global, so upstream qualified
  with `Darwin.`. Replaced with a file-private `posixClose(_:)` helper that
  calls `Glibc.close` / `WinSDK.close` / `Darwin.close` per platform.
  The Windows branch is written but untested (no Windows machine in Wave 1).

## 3. CryptoKit → swift-crypto

`Package.swift` gained `.package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.1")`
and the target gained `.product(name: "Crypto", package: "swift-crypto")`.
`IPhoneIdentity.swift`: `import CryptoKit` → `import Crypto`. The
`SHA256` / `Insecure.SHA1` call sites are source-compatible, unchanged.

## 4. `import os` / `OSAllocatedUnfairLock` → `Synchronization` / `Mutex`

`import os` → `import Synchronization`; `OSAllocatedUnfairLock(initialState: x)`
→ `Mutex(x)` in `PipeOutput.swift`, `Storage/HeldLease.swift`,
`Storage/StorageLease.swift`, and `Tests/.../StorageLeaseTests.swift`.
`Mutex.withLock` has the same `inout` closure shape, so call sites are
unchanged. No `OSLog`/`Logger` usage exists in this package, so swift-log
was NOT added.

## 5. `NSData.decompressed(using: .zlib)` → CZlib + `LTMInflate.swift` (new)

`GuestPack.read` inflated its payload with the Compression framework
(Apple-only). Added a `CZlib` system-library target (`Sources/CZlib/`,
modulemap over the platform zlib, `link "z"`) and
`Sources/HostRuntime/LTMInflate.swift` with `inflateRawDeflate(_:)`:
- Apple platforms (`canImport(Compression)`): unchanged behavior, still
  `(data as NSData).decompressed(using: .zlib)`.
- Linux/Windows: zlib `inflateInit2_(&stream, -MAX_WBITS, ...)` — raw
  deflate, no header expected, adler trailer ignored — matching the
  2-byte header strip and the old comment exactly. Corrupt streams throw
  `CocoaError(.fileReadCorruptFile)`; an empty stream decodes to empty
  `Data` (a valid empty package).

Build requirement: zlib headers at compile time (`zlib1g-dev` on
Debian/Ubuntu; declared as the apt provider) and libz at link time.
macOS uses the SDK's zlib; untested here.

## 6. `CFGetTypeID` / `CFBooleanGetTypeID` / `CFNumberIsFloatType` → objCType sniffing

`DeviceLock.swift`'s `JSONValue.init(_:)` told JSON booleans/floats apart via
CoreFoundation type IDs, which swift-corelibs-foundation doesn't expose.
Added private `jsonIsBoolean(_:)` / `jsonIsFloat(_:)` helpers: Apple
platforms keep the original CF calls; elsewhere the NSNumber ObjC type
encoding is used (`"c"` for booleans — corelibs' `__NSCFBoolean` from
JSONSerialization, `NSNumber(value: Bool)`, or a bridged Swift `Bool`;
`"f"`/`"d"` for floats/doubles, matching `CFNumberIsFloatType`). Known
divergence: an `NSNumber` deliberately wrapping `Int8`/`UInt8` reads as
`.bool` on Linux but `.int` on Darwin; JSONSerialization never produces
those, and the tests don't cover them.

## 7. Other Apple-only imports

Full audit (`grep -rhn "^import " Sources/ Tests/ | sort -u`): only
`Foundation`, `Testing`, `HostRuntime`, `Crypto` (swift-crypto),
`Synchronization`, and the per-platform C library remain. No other
Apple-only frameworks (no AppKit/SwiftUI/AVFoundation/IOSurface/etc.) are
used by this package.

- **`st_ino` type (`StorageLeaseTests.swift`)**: `UInt64` on Darwin,
  `UInt` (`__ino_t`) on Linux; the inode comparisons now go through
  `UInt64(...)`.
- **`posix_spawn` path argument (`StorageLeaseTests.swift`)**: `argv[0]` is
  `UnsafeMutablePointer<CChar>?`; Darwin's import is implicitly-unwrapped,
  Glibc's is not — force-unwrap (it was just assigned from `strdup`).

## What remains macOS/Windows-specific

- The `#elseif os(Windows)` branches (WinSDK imports, `posixClose`,
  PipeOutput's no-SIGPIPE branch) are written for the Windows wave but have
  never been compiled — no Windows toolchain is available in Wave 1.
- `StorageLeaseTests.pendingEditRefusalUnlocksWhileChildrenSpawn` spawns
  `/usr/bin/true` via `posix_spawn`; it is Linux/macOS-only in practice
  (no `/usr/bin/true` on Windows) and will need a Windows equivalent later.
- `PipeOutput`'s SIGPIPE handling is process-global on Linux (see §2); if a
  future caller needs per-descriptor semantics, that needs a different
  transport than DispatchIO.
- `LTMGeometry.swift`'s `Codable` wire format may differ from CoreGraphics
  (see §1); do not treat persisted `Board` JSON/plists as cross-platform
  compatible without a migration check.

## 8. CZlib → CZlibHost (2026-10-15, cross-package rename)

`ZIPFoundation` (a FirmwareKit dependency) vends its own Clang module named
`CZlib` (`Sources/CZLib/module.modulemap`). SwiftPM passes every transitive
system target's modulemap to each dependent target's compile, so building
FirmwareKit (which depends on HostRuntime *and* ZIPFoundation) failed with
`redefinition of module 'CZlib'`. Target names must also be unique across the
package graph, so both the target and the module were renamed `CZlib` →
`CZlibHost` (`Sources/CZlibHost/`, `import CZlibHost` in `LTMInflate.swift`
and `GuestPack.swift`). Same shim over the platform zlib, no behavior change.
FirmwareKit carries its own identical shim as `CZlibFK` for the same reason.

## 9. recordPath double-slash (2026-10-15, cross-package fix)

`StorageRecordPaths.recordPath` built its prefix as `relativeRoot.path + "/"`. When the device sits
directly under `/tmp` (relativeRoot `/`), that is `"//"`, which no path has as a prefix, so every
call threw `.invalidRecord`. Now uses the path as-is when it already ends in `/`. Found via
FirmwareKit's StorageGenerationTests with TMPDIR=/tmp.
