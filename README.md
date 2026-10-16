# LightTouch — Cross-Platform Port (Linux + Windows)

A cross-platform port of [LightTouchMac](https://github.com/samhenrigold/LightTouchMac),
the app that runs classic Apple devices (original iPhone through iPhone 4, iPod touch,
first iPad) on their original firmware inside an emulator.

## Status

Work in progress. The portable Swift core (`Packages/`) builds and passes its tests
on Linux; Windows CI builds and tests every change on `windows-latest`. The macOS
AppKit/SwiftUI interface is being rewritten in Qt 6 (see `docs/UI_APPROACH.md` in the
project notes).

## Layout

- `Packages/` — the portable core: 7 Swift packages (device runtime, firmware handling,
  host services, …). Apple-only frameworks have been replaced with cross-platform
  equivalents; each package keeps a `SHIM_NOTES.md` recording every deviation.
- `LightTouchMac/` — upstream macOS app target (reference only; not built here).
- `tests/` — upstream test suites (reference only).
- `.github/workflows/` — CI: `linux-ci.yml` and `windows-ci.yml` build + test every
  package on each push/PR.

## Building (Linux)

```sh
# per package, e.g.
cd Packages/HostRuntime
swift build
swift test
```

Requires Swift 6.4.1, plus `libsqlite3-dev`, `zlib1g-dev`, `pkg-config` for the
packages that bind system libraries.

## License

GNU General Public License, version 2 or later — same as upstream LightTouchMac.
See `LICENSE` (upstream) for the full text.
