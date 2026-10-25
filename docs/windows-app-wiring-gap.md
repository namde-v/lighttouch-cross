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
   NOT be found there — a windows-ci run never contains the Qt artifact.
   **DECIDED (main agent, 2026-10-26 audit 04:33): see "Gap 2 decision"
   below. Do not re-litigate the (a)/(b) choice; implement the decision.**
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

## Gap 2 decision (main agent, 2026-10-26 audit 04:33 — overdue since ~02:45, decided now)

The package step **must NOT** fetch the Qt exe artifact from the
windows-ci run id anymore. That lookup is itself the gap: a windows-ci
run never contains the Qt artifact, so the step can never succeed as
written.

**Decided rule** for the package Qt step (to be implemented once the Qt
tests are green; implementation is deferred so it does not block the
ongoing Qt diagnosis):

1. **Primary:** download artifact `lighttouch-qt-ui-windows-x86_64` from
   the **windows-qt-ci run whose head SHA equals the commit being
   packaged, on the same ref** (branch). The "commit being packaged" is
   the head SHA of the windows-ci run the package step resolved (input
   run id, or latest successful windows-ci run on main).
2. **Fallback:** if no windows-qt-ci run matches that SHA, download from
   the **newest successful windows-qt-ci run on the same branch**, and
   emit a **warning** that the exe may not match the packaged commit.
3. If neither exists, keep the current behavior: warn and continue
   without the exe (package stays green, MSI stays shortcut-less).

**Not decided here:** Qt runtime DLL/plugin staging (gap 3) and the
cross-repo trigger (gap 5) are separate follow-ups. The installer needs
no change: it already picks up the exe from the ZIP automatically.

## This commit (first wiring)

- `windows-qt-ci.yml` now checks out `namde-v/lighttouch-ui` at `QtUI/`.
  The scaffold becomes a real Windows UI test build: install Qt → cmake
  configure → build → ctest. The first run on this branch is
  expected to teach us what fails under MSVC; a red first run is signal,
  not a regression (this workflow never ran before).
- The build also uploads `build/lighttouch.exe` (Ninja single-config
  output) as `lighttouch-qt-ui-windows-x86_64` with warn semantics —
  evidence the exe compiles on Windows. Per the gap 2 decision above,
  this artifact becomes consumable by packaging once the decision is
  implemented (it is not consumable by the current package step, which
  still looks at the windows-ci run id).
- No change to package/installer behavior: both already pick up the exe
  automatically once gap 2 is implemented (package stages it, installer adds
  the shortcut).

## Next steps (in order)

1. Read the first qt-ci run on this branch: does the UI compile under
   MSVC? What fails? (Done — see diagnoses below; offscreen hypothesis
   REFUTED on run 40234747319, VS-generator fix now pending its run.)
2. Implement the gap 2 decision (package Qt step fetches from the
   SHA-matched windows-qt-ci run, same ref, fallback newest successful
   run on the same branch + warning) — **deferred until Qt tests green**,
   per the main-agent decision; do not let it block Qt diagnosis.
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

## Third run diagnosis (2026-10-26, run 40234747319 on 0c48026)

- **Result: FAILED, same 5 tests, 12/17.** `tst_applaunch`, `tst_surface1`,
  `tst_surface11` (SEGFAULT), `tst_surface2`, `tst_surface12`. Windows
  CI + Linux CI on the branch: both SUCCESS. Build SUCCESS, exe
  artifact uploaded.
- **The offscreen hypothesis is REFUTED as stated — and the fix was a
  no-op.** The tests set `QT_QPA_PLATFORM=offscreen` THEMSELVES via
  `set_tests_properties(... ENVIRONMENT "QT_QPA_PLATFORM=offscreen")`
  in the UI repo's `tests/CMakeLists.txt`; ctest test properties
  override the process env, so removing offscreen from the workflow's
  Test step changed nothing about the test environment. The workflow
  env never mattered. (The UI repo's workflow is equally "offscreen"
  through the same mechanism — and was green.)
- **New evidence from ctest.log:** the 5 failing tests print NO QTest
  output at all (no `FAIL!` lines, no loader errors) — only the ctest
  summary lines. surface11's crash stack ends in
  `qt_qFindChild_helper` during `eightMenusExist` — a symptom of
  `findChild` on a null root, not a cause: the QML root object is
  missing, i.e. main.qml produced no root. But the split is NOT
  DisplayItem or DeviceScreen per se: surface3 registers DisplayItem
  AND loads DeviceScreen.qml and PASSES, while surface12 loads the same
  DeviceScreen and fails in 0.20s. deviceList refresh/count is also not
  the split (surface10 refreshes and passes; surface2 never refreshes
  and fails in 17.92s — multiple expired waits).
- **Runner image ruled out:** the UI repo's green run (2026-10-16) used
  the same `windows-2025-vs2026` image as this run. **Caveat on the
  control:** that green run is 10 days old and the UI repo's workflow
  has not run since (it triggers only on win/** pushes + PRs to main,
  and win/w-ui has not moved) — there is no CURRENT green evidence.
- **Next hypothesis (now implemented on this branch): the VS
  generator.** The workflow now converges on the UI repo's
  windows-ci.yml exactly for build/test: default Visual Studio
  generator (no `-G Ninja`), `--config Release`, `-C Release`,
  `host: windows, target: desktop` in install-qt, no msvc-dev-cmd
  (CMake finds MSVC itself), and the UI repo's "Diagnose failures"
  step (`ctest --rerun-failed -V`, first 250 lines) so the next failure
  shows its raw output instead of the empty summary. Exe upload path
  moves to `build/Release/lighttouch.exe` (VS multi-config layout).

## Second run diagnosis (2026-10-26, run 40229752935 on 031accd)

- **MSVC fix worked: Build SUCCESS, exe artifact uploaded and verified**
  (`lighttouch.exe`, MZ-PE, 456,192 bytes). Windows CI + Linux CI on
  the branch: both SUCCESS. Only the test step failed: **12/17 pass,
  5 fail** — `tst_applaunch`, `tst_surface1`, `tst_surface11`
  (SEGFAULT), `tst_surface2`, `tst_surface12`, all in the
  surface/applaunch area. No QTest `FAIL!` lines in the log.
- **Triage — the UI repo's own workflow is the control.** The
  lighttouch-ui repo's `windows-ci.yml` runs this same suite 17/17 green
  on windows-latest (merge `819d571`, 2026-10-16). Test sources are
  unchanged since (local clone is stale at the import, but `tests/`
  differs from origin main only in `CMakeLists.txt`, the backslash-path
  fix). Differences between that green setup and this qt-ci run:
  (a) they do NOT set `QT_QPA_PLATFORM=offscreen` — this run did;
  (b) they use the default Visual Studio generator, this run uses Ninja.
- **Hypothesis (prime suspect): offscreen-on-Windows.** Under the
  offscreen platform, `QQuickWindow::isExposed()` never becomes true
  (applaunch waits on it), scene-graph/texture paths run with no real
  window (surface11 segfault plausibly lives in `DisplayItem` texture
  creation), while on Linux offscreen the same tests pass. **Fix (this
  branch): drop `QT_QPA_PLATFORM=offscreen`, use the default windows
  platform plugin like the UI repo's workflow.** If failures persist,
  the next hypothesis is the VS generator.

## Fourth run diagnosis (2026-10-26, run 40237966745 on 7f93411, VS generator)

- **Result: FAILED, same 5 tests, same timings, 12/17.** VS-generator
  hypothesis REFUTED. `tst_applaunch` 0.61s, `tst_surface1` 0.92s,
  `tst_surface11` SEGFAULT 0.90s (crash in `qt_qFindChild_helper` during
  `eightMenusExist`, 0xc0000005), `tst_surface2` 17.35s (expired waits),
  `tst_surface12` 0.21s. Windows CI + Linux CI on the branch: SUCCESS.
- **The -V Diagnose step did NOT break the silence.** Even under
  `ctest --rerun-failed -V` the 4 fast failures print NO QTest output
  at all — only ctest's own lines. The silence is in the test processes
  themselves, not in ctest's reporting. A normally-failing QTest binary
  flushes its output on exit, so these processes die abnormally
  (loader failure, abort, or crash without handler output) — or never
  really run. surface11's crash-handler output proves the output
  channel itself works.
- **Control validated, code ruled out.** Diff of the green-run code
  (`9536541`, UI repo run 38896622632, 17/17) vs the code my runs check
  out (`819d571`, UI main HEAD) touches ONLY `packaging/*` +
  `appimage.yml`. `tests/`, `src/`, `qml/` are IDENTICAL. The green run
  and my runs test the same code; the variable is setup/environment.
- **Compiler ruled out.** Green run and this run both used MSVC
  19.51.36260.0 / cl 14.51.36231 / Visual Studio 18 2026. Runner image
  drifted (20261007.264.1 -> 20261021.278.1) but with the same compiler
  it is a weak lead, not the prime suspect.
- **Remaining workflow deltas vs the green workflow:** UI sources at
  `QtUI/` subdir vs repo root (LT_QML_DIR is absolute in both, so this
  should not matter), install-qt `cache: true` vs absent, timeout 30
  vs 60 min, extra port-repo checkout + exe upload step before Test.
- **Two failure classes, possibly different mechanisms:** 4 fast silent
  failures (+1 segfault) vs `tst_surface2`'s 17s expired waits (its mock
  link/boot waits never resolve, while `surface3`'s mock device-list
  wait succeeds in the same runs — timers fire, link events don't).
- **Next experiment (this branch):** run the 5 failing binaries
  DIRECTLY (not via ctest) with exit-code echo + `dumpbin
  /dependents`. Exit -1073741515 (0xC0000135) = DLL failed to load;
  0xC0000005 = access violation; small nonzero = normal QTest failure
  whose output was lost. The dependents list names any missing DLL
  instead of guessing.

## Fifth run diagnosis (2026-10-26, run 40238812735 on 421d03e, direct run)

- **Result: FAILED, same 5 tests, 12/17.** Direct-run exit codes:
  `tst_applaunch` 1, `tst_surface1` 1, `tst_surface11`
  -1073741819 (0xC0000005, crash in `qt_qFindChild_helper` during
  `eightMenusExist`), `tst_surface2` 4 (~17s), `tst_surface12` 1,
  control `tst_surface3` 0. **No loader failure anywhere** — every
  binary launches; `dumpbin /dependents` shows only Qt6 DLLs + system
  CRT for all six. The 0xC0000135 theory is DEAD.
- **The "die abnormally" theory from run 4 is REFUTED for 4 of 5:**
  applaunch/surface1/surface2/surface12 exit with NORMAL QTest
  failure codes (1/4 = failed-test-function counts), not crash codes.
  They run to completion and report failure — but print NOTHING.
- **The silence is stdout-specific, not a dead output channel.**
  surface11's crash-handler output (stderr path) comes through the
  same log, while even the PASSING control (surface3, exit 0) prints
  no QTest lines. QTest writes to stdout; the crash handler writes
  via the stderr path. Something in this CI environment swallows
  these binaries' stdout (tests use plain `add_executable`, console
  subsystem, so it is not a WIN32-subsystem artifact).
- **surface11 crash mechanism identified (hypothesis, fits all
  evidence):** the Fixture constructor's `QVERIFY2(menuBar !=
  nullptr)` fails (main.qml loads without a `menuBar` child, or
  fails to load), the QVERIFY failure message goes to the swallowed
  stdout, the constructor returns early leaving `menuBar` null, and
  `eightMenusExist`'s `findMenu` dereferences it ->
  `qt_qFindChild_helper` on null. `main.qml` DOES declare
  `objectName: "menuBar"` (line 89), so the load itself (or an
  import it needs) must be failing — but no QML warning appears
  either, consistent with stdout loss (qWarning goes to stderr
  normally... which weakens this; the load failure, if any, is
  still unproven).
- **surface2's 17s = 3x link waits, not a hang:** exit 4 with ~17s
  matches `displayLinkAndFrames` + `displayItemRenders` +
  `inputSeams` each burning a 5s `waitLink()` ("DisplayLinkReady
  never arrived"), plus one more failed function. The mock's link
  events never arrive while surface3's device-list wait succeeds.
- **Next experiment (this branch):** redirect each binary's FULL
  output to a file (`*> diag-$t.txt`) and dump the file. This
  settles whether stdout is lost in the pipe (file will contain
  the FAIL lines) or genuinely never produced (file empty). If
  the FAIL lines appear, the actual failure reasons become visible
  for the first time and the fix follows from them, not from
  guessing.
