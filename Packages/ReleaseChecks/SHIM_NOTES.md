# ReleaseChecks — Linux port notes

What changed to make this package build and test green on Linux (Swift 6.4.1, Ubuntu 24.04),
and what is deliberately stubbed until a later port phase.

## Dependency shims (no behavior change)

- **zlib**: was a bare `import zlib` with no module for it. Added an `RCZlib` system-library target
  (`Sources/RCZlib/module.modulemap` + `shim.h` including `<zlib.h>`, `link "z"`, `pkgConfig: "zlib"` in
  Package.swift). `BundleHygiene.swift` and its tests now `import RCZlib`. Needs the dev headers:
  `zlib1g-dev` (already present on this machine; `pkg-config --libs zlib` → `-lz`).
  Named `RCZlib` rather than `CZlib` because HostRuntime (a dependency of the test target) already
  declares a `CZlib` system target and SwiftPM requires target names to be unique across the package
  graph; the two modulemaps are identical. Unifying on one shared target is a possible follow-up.
- **CryptoKit**: `Digest.swift` used `import CryptoKit` for SHA-256. Package.swift now depends on
  `apple/swift-crypto` (`from: "3.15.1"`, product `Crypto`), and `Digest.swift` does
  `#if canImport(CryptoKit) import CryptoKit #else import Crypto #endif`. Same `SHA256` API on both.

## macOS-only check logic (guarded, honest stubs on Linux)

- **MachOClosure** parses `lipo`/`otool`/`nm` output, so it cannot work on Linux. The tool-backed
  functions (`architectures`, `metadata`, `rpaths`, `dependencies`, `check`) throw
  `MachOClosure.Failure("Mach-O closure checks need macOS (lipo, otool, nm)")` on Linux via
  `#if os(macOS)`; the tool-free helpers (`version`, `expand`) are shared. Full ELF/PE closure
  checking is a later port phase.
- **BundleHygiene** compiles on Linux as-is (`fnmatch` via Glibc, `NSHomeDirectory()` via
  swift-corelibs-foundation). Its `problems()` still shells out to `aa`/`nm` for real bundles, so
  that path fails honestly (tool not found) on Linux; the zlib packed-device path (`inflate`,
  `packedProblems`) works fully on Linux through `CZlib`.
- **ReleaseApp / Shell**: compile unchanged; `ReleaseAppStaticTests` and `ReleaseBootTests` are
  `.enabled(if: appGiven)` (env `LTM_RELEASE_APP`/`LTM_RELEASE_ARCHIVE`), so they stand aside on
  Linux CI instead of being faked.

## Tests

- `MachOClosureTests`' two fixture tests build real arm64 Mach-O binaries with the macOS clang and
  need `lipo`/`otool`/`install_name_tool`: `#if os(macOS)`. On Linux two tests instead assert the
  stub errors and exercise `version`/`expand`.
- `BundleHygieneTests.aCompleteBundlePassesAndEachBreakageIsNamed` builds Mach-O fixtures with `cc`,
  uses `strip -S -x` and the bundle's `aa` tool: `#if os(macOS)`. `everyBuildCopiesTheGuestTools`
  reads `LightTouchMac.xcodeproj`, which the port tree doesn't ship: `#if os(macOS)`.
- New Linux tests cover the platform-free paths for real: zlib inflate round-trip + garbage rejection,
  packed-device accept/placeholder-identity/unit-identity/local-path/garbage-body, Mach-O magic
  detection, `Package.resolved` identity parsing, and the SHA-256 known vector (exercises
  swift-crypto's `Crypto` here).

## Deferred

- ELF/PE equivalents of `MachOClosure` (load-closure checking for Linux/Windows binaries).
- `BundleHygiene.problems()` against Linux/Windows bundle layouts (needs the cross-platform
  packager's output format); the `aa`/`nm`-dependent breakage checks are macOS-only for now.
- The Release test plans (ReleaseAppStaticTests/ReleaseBootTests) need a built cross-platform app
  and the `LTM_RELEASE_APP` harness on the target OS.
