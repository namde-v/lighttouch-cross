# Linux Pipe + `Process.run()` Landmine

## The bug

Intermittent test-runner crashes on Linux with **SIGILL**, no test failing:

```
Fatal error: 'try!' ... "Bad file descriptor" at FileHandle.swift:740
```

Uncatchable. One stray `EBADF` kills the whole `swift test` process.

## Root cause

`swift-corelibs-foundation`'s `Process.run()` calls `closeFile()` — which is
literally `try! close()` — on `Pipe` stdio descriptors after spawning. If a
pipe fd is already closed (a spurious EBADF, seen intermittently on Linux CI),
`try!` fatals the process. Plain file handles are never closed by `run()`, so
only `Pipe` stdio is dangerous.

Fixed in commit history of `LibraryFixtures.swift` (branch `linux/l-fixture-fix`).

## The fix

Two rules applied in
`Packages/LightTouchCore/Tests/LightTouchCoreTests/Library/LibraryFixtures.swift`:

1. **Capture subprocess stdout to a temp file, not a `Pipe`.**
   `LibraryFixtures.run()` writes stdout to `FileManager.temporaryDirectory`,
   then reads it back after `waitUntilExit()`. File handles dodge the landmine
   entirely.
2. **Do filesystem work in-process instead of spawning.**
   `forceRemove()` does the `chmod -R u+w` equivalent via
   `FileManager.setAttributes` (see `makeWritable(_:)`), instead of spawning
   `/bin/chmod`. Same for `script()`, which uses `setAttributes` for `+x`.

## Rule for future code

**NEVER pass a `Pipe` as `Process` stdio on Linux.** Always capture to a temp
file. `Process.standardError = FileHandle.nullDevice` is safe (identity-mapped
to `/dev/null`, never touched). Prefer in-process `FileManager` operations over
spawning `/bin/chmod`, `chflags`, etc. in test helpers.
