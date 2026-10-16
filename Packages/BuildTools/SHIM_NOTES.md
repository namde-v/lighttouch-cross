# BuildTools — Linux port notes

What changed to make this package build and test green on Linux (Swift 6.4.1, Ubuntu 24.04),
and what is deliberately stubbed until a later port phase.

## Dependency shims (no behavior change)

- **CryptoKit**: `Support.swift` used `import CryptoKit` for streaming SHA-256 file hashing
  (`sha256(_:)`, used by `DependencySources` and `Records`). Package.swift now depends on
  `apple/swift-crypto` (`from: "3.15.1"`, product `Crypto`), and `Support.swift` does
  `#if canImport(CryptoKit) import CryptoKit #else import Crypto #endif`. Same `SHA256` API on both.

## macOS-build-specific logic (guarded, honest stubs on Linux)

- **MergeNative** merges per-architecture native roots with `lipo`, `install_name_tool`, `otool`
  and re-signs with `codesign`: `relink`, both `merge` functions throw
  `ToolError("merging native roots needs macOS (otool, install_name_tool, lipo, codesign)")` on
  Linux via `#if os(macOS)`. The tool-free helpers (`skipped`, `isMachO`, `relocations`,
  `relocated`, `real`) are shared. A universal merge of ELF/PE roots is a later port phase.
- **Records.toolchain()** shells out to `xcodebuild`/`xcrun`: on Linux it throws
  `ToolError("recording the toolchain needs macOS (xcodebuild, xcrun)")`, so `writeStatic` /
  `writeNative` refuse honestly. Recording the cross toolchain (clang version, target SDK) is a
  later port phase.
- **Vendor.build()**: the whole pipeline produces macOS artifacts (universal Mach-O dylibs,
  ad-hoc-signed tools, the `.app` resource layout, `xcodebuild` for the helper). On Linux it throws
  `ToolError("scripts/vendor builds macOS artifacts: not available on this platform")`. The
  internal steps still compile (they are subprocess invocations, unreachable through the public API
  on Linux), and `Vendor.directory()` / `pinKey()` / `treeHash()` / `lock()` remain usable.
- **ltm-build CLI** (`Sources/ltm-build/main.swift`) compiles on Linux unchanged (swift-argument-parser
  is cross-platform). `vendor`, `check-macho` and `merge-native` throw the honest stub errors above;
  `sources fetch|stage-git|note` are platform-free and work; `static-record` / `native-record` need
  the macOS toolchain stub.

## Tests

- `MergeNativeTests.mergesRelocatesAndRefuses` builds Mach-O slices with `cc -arch arm64` /
  `-mmacosx-version-min` and checks with `lipo`/`otool`: `#if os(macOS)`. On Linux two tests instead
  assert the merge stub error and exercise the tool-free helpers (`skipped`, `relocated`,
  `relocations` longest-first ordering, `real`, `isMachO` on magic bytes / `!<arch>` / plain text).
- `VendorTests` (walk/entries `.DS_Store` filtering, `staticComplete`, the `flock` vendor lock) and
  `DependencySourcesTests` (archive fetch/verify, `stageGit`, `note`) are platform-free and run on
  Linux unchanged.

## Deferred

- Universal merge for ELF (Linux) / PE (Windows) native roots, including whatever replaces
  `install_name_tool`/`codesign` (rpath/`patchelf` handling, signing).
- A cross-platform `scripts/vendor` flow producing Linux/Windows artifacts.
- `Records` toolchain capture for the cross toolchain.
