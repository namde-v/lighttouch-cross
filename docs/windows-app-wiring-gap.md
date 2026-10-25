# Windows app wiring — gap audit (2026-10-26, branch `win/w-app-wire`)

Why this file exists: the Windows ZIP and MSI build green but contain no
runnable app. This is the honest inventory of what is missing, and the
design the wiring work follows. Main code head at audit time: `9d437b5`.

## Current state (verified at `9d437b5`)

- `windows-package.yml` assembles a flat `LightTouch/` layout: Swift package
  DLLs/EXEs from windows-ci artifacts + qemu + MinGW DLLs (best effort) +
  Swift runtime DLLs. **No `LightTouch.exe`.** The Qt step is
  `continue-on-error` + warning, so packaging stays green without the exe.
- `windows-installer.yml` builds the MSI from the ZIP via heat harvest; the
  Start Menu shortcut is conditional on the exe being present (`HAS_EXE`).
  Today the MSI installs DLLs + qemu + Swift runtime with no shortcut. The
  workflow header documents this gap honestly; the MSI is real and
  installable, it is NOT yet a runnable app installer.
- `windows-qt-ci.yml` was a scaffold only: it skipped every run because it
  waited for `QtUI/CMakeLists.txt` inside the port repo, which never existed.
- The real Qt UI lives in a **separate repo**: `namde-v/lighttouch-ui`
  (local `ui/`). CMake target `lighttouch` (`qt_add_executable`), builds and
  runs on Linux against the real `libLTAppCore.so` or the mock; the core
  library is loaded at runtime (`LTM_APPCORE_LIB`).

## Gaps

1. **No Windows build of the UI exists** — neither tests nor exe.
2. **Artifact contract mismatch (the key design decision).** The package
   Qt step downloads artifact `lighttouch-qt-ui-windows-x86_64` from the
   **windows-ci run id**. An exe built by any other workflow (qt-ci) will
   NOT be found there. Follow-up must pick one: (a) move the UI exe build
   into `windows-ci.yml` as a job, so the artifact lands on the windows-ci
   run; or (b) change the package Qt step to fetch from the latest
   successful qt-build run. Do not do both half-way.
3. **Qt runtime is not staged.** Even with `LightTouch.exe`, the ZIP stages
   no `Qt6*.dll` and no plugins (`platforms/qwindows.dll`). The flat
   layout vs Qt's plugin subdirectory needs a `qt.conf` or library-path
   decision before the app can launch from the ZIP.
4. **UI CMake is Linux-pathed.** Swift toolchain paths are hardcoded to
   Linux swiftly dirs; on Windows runners the Swift parts skip gracefully
   (the CMakeLists prints "skipped"), but which DLL is the Windows
   `libLTAppCore` equivalent (import lib vs runtime load) is unverified.
   The package step already stages the windows-ci DLLs next to the exe,
   which is the right shape — it just hasn't been exercised.
5. **Trigger gap.** Port-repo `QtUI/**` paths never match (the UI is a
   separate repo), so qt-ci runs only on workflow-file edits and manual
   dispatch until a cross-repo trigger (`repository_dispatch` or a schedule)
   is added.

## This commit (first wiring)

- `windows-qt-ci.yml` now checks out `namde-v/lighttouch-ui` at `QtUI/`.
  The scaffold becomes a real Windows UI test build: install Qt → cmake
  configure → build → ctest offscreen. The first run on this branch is
  expected to teach us what fails under MSVC; a red first run is signal,
  not a regression (this workflow never ran before).
- The build also uploads `build/lighttouch.exe` (Ninja single-config
  output) as `lighttouch-qt-ui-windows-x86_64` with warn semantics —
  evidence the exe compiles on Windows. Per gap 2, this artifact is NOT
  yet consumable by the package step.
- No change to package/installer behavior: both already pick up the exe
  automatically once gap 2 is resolved (package stages it, installer adds
  the shortcut).

## Next steps (in order)

1. Read the first qt-ci run on this branch: does the UI compile under
   MSVC? What fails?
2. Decide gap 2 (job inside windows-ci vs cross-workflow fetch) and
   implement it.
3. Stage Qt runtime DLLs + plugins (`qt.conf`) in the package step.
4. Verify the MSI installs a runnable app (exe + shortcut + DLLs).
5. Add a cross-repo trigger so lighttouch-ui pushes run qt-ci.

## First run diagnosis (2026-10-26, run 40226999464 on 388144c)

- **Result: FAILED at the link step, after all sources compiled.** The
  failure is a toolchain mismatch, not a UI source problem: configure
  picked MinGW `GNU 15.2.0` (`C:/mingw64/bin/c++.exe`) while Qt was
  installed as `win64_msvc2022_64` (MSVC build). MinGW `ld.exe` then
  reported every Qt symbol as an undefined `__imp__` reference.
- **Fix (this branch):** add an `ilammy/msvc-dev-cmd` step before
  Configure so CMake picks `cl.exe` — the arch choice already intended
  MSVC, the environment setup was the missing piece. The next run will
  show whether the UI sources also compile clean under MSVC.
- **Unrelated, same push:** windows-ci run 40226999489 on this branch
  failed only on HostRuntime with the known SwiftPM planning stall
  signature (`TEST RESULT: STALLED — no test output for 10 min (last
  size 22 bytes)`), caught by the watchdog at ~10 min. This branch
  touches no Swift code (docs + qt-ci workflow only); the stall is the
  known intermittent, not a regression. Linux CI on this branch: success.
