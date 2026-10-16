# LTAppCore Additions

This document records every addition made to `port/Packages/` for the
LTAppCore bridge (ui/ABI.md §6 gaps). The upstream directory
(`~/workspace/lighttouch-cross/upstream/`) was never modified.

## New package: LTAppCore

**Location:** `port/Packages/LTAppCore/`

A SwiftPM package producing a `.dynamic` library (`libLTAppCore.so`) that
exposes the `ui/ABI.md` C-ABI surface via `@_cdecl` exports. Depends on the
existing port packages (LightTouchCore, DeviceRuntime, HostRuntime,
FirmwareKit/FirmwareSchema, DeviceServices/HostServiceWire/HostServiceClient)
via path dependencies.

**Structure:**
- `Sources/LTBridgeC/include/lt_bridge.h` — the C contract header (ABI.md §1.1):
  LTEvent tagged union, constants, and declarations of every `lt_` export.
  Shipped for the Qt side to include.
- `Sources/LTAppCore/Core/` — the portable app-core orchestrator (gap 1):
  `AppCore` (handle registry, per-device sessions, snapshot caches, event pump),
  `DeviceSession` (per-device session fronting the real view-models),
  `EventPump`, `HandleRegistry`, `SnapshotStore`, `QtFrameMirror`/`ShmCapture`
  (shm-ring reader), `PrefsStore` (file-backed UserDefaults).
- `Sources/LTAppCore/Exports/` — the `@_cdecl` exports, one file per ABI.md
  section (§3.1–§3.11).
- `Sources/LTAppCore/Resources/Help.txt` — copied from upstream (read-only
  reference; upstream not modified) for `lt_help_topics`.
- `Tests/LTAppCoreTests/` — Swift Testing unit tests.

## Additions to existing port packages

### 1. `LightTouchCore`: `Device/BootSessionScope.swift` — made nonisolated

**What:** Removed `@MainActor @Observable`; added `NSLock`-guarded mutable
state (`id`, `generation`, `retired`, task dictionary). The class is now
`@unchecked Sendable`.

**Why:** The session state machines (`BootCycle`, `ShutdownSequence`, etc.)
call the host's `BootSessionScope` from background threads (e.g.
`BootCycle.reset()` calls `host.bootScope.retire()` off-actor). With
`DeviceSession` nonisolated (see below), the scope must be callable off
`@MainActor`.

**Upstream mirror:** `LightTouchMac`'s `BootSessionScope` (Mac-only
`EmulatorController` context; the port's bridge needs it thread-safe).

### 2. `LightTouchCore`: `UI/FilesConnection.swift` — made nonisolated

**What:** Removed `@Observable` (which implied `@MainActor`); added
`NSLock`-guarded `state`. Fixed a reentrancy hazard in `follow(device:...)`
(it read the `binding` getter, which takes the lock, from inside a
`lock.withLock` block — now reads `_state` directly).

**Why:** The bridge's file exports (`lt_files_*`) read `FilesConnection.shared`
from any thread (Qt UI thread, worker threads).

**Upstream mirror:** `LightTouchMac`'s `FilesConnection` (Mac UI-owned).

### 2b. `LightTouchCore`: `AboutCredits`, `WorkerRetirement` — made nonisolated

**What:** Added explicit `nonisolated` to the `AboutCredits` enum and its
`Project` struct (`App/AboutCredits.swift`), and to `WorkerRetirement`
(`Session/SessionLink.swift`; also `@unchecked Sendable`). No behavior change.

**Why:** The package declares `.defaultIsolation(MainActor.self)`, so without
the annotation these were `@MainActor`-isolated and unusable from the bridge's
nonisolated contexts (`lt_about_credits` reads `AboutCredits.projects` from
any thread; `DeviceSession` owns a `WorkerRetirement`).

**Upstream mirror:** `LightTouchMac`'s credits/about panel and session worker
tracking (Mac UI-owned; the bridge needs them off-actor).

### 2c. `LightTouchCore`: `CapturePreferences`, `HelpTopic`, `KeyboardPointer` — made nonisolated

**What:**
- `CapturePreferences` (`Features/CapturePreferences.swift`): `public nonisolated struct ... : @unchecked Sendable`. The struct is a thin `UserDefaults` wrapper (thread-safe); the bridge's synchronous `lt_capture_prefs_get` query reads it off-actor. The bridge constructs it with the file-backed `LTFileDefaults`, not `.shared`/`.standard`.
- `HelpTopic` (`UI/HelpTopic.swift`): `public nonisolated struct`. Pure value type; `lt_help_topics` parses Help.txt off-actor.
- `KeyboardPointer` + nested `Phase`/`Touch`/`FocusMove` (`Input/KeyboardPointer.swift`): `public nonisolated`. Pure pointer-math value types; `lt_input_keyboard_pointer_key` drives them on the input fast path.

**Why:** The package declares `.defaultIsolation(MainActor.self)`; without the
annotations these were `@MainActor`-isolated and unusable from the bridge's
nonisolated `@_cdecl` exports. No behavior change.

### 3. `LTAppCore`: `DeviceSession` — nonisolated session class (gap 1)

**What:** `DeviceSession` is a nonisolated `final class` (was `@MainActor` in
an earlier iteration) with `NSLock`-guarded mutable state. It satisfies 10
nonisolated host protocols (`MachineHost`, `BootCycleHost`, `ShutdownHost`,
`EraseHost`, `InputHost`, `RotationHost`, `ReadinessHost`, `BootWatchHost`,
`AppsHost`) whose requirements the state machines call synchronously from
background threads. Only `CarrierBackend` is `@MainActor`. `@MainActor` is
used only for carrier-panel-touching methods and poll/capture entry points
(driven from the `@MainActor` pump).

**Why:** ABI.md §4 threading contract: commands enqueue+return (never block
the Qt UI thread); the state machines run off-actor and need synchronous
host access.

### 4. `LTAppCore`: New public API on port types (gap 1)

- `DeviceRotation.rotate(toDegrees:)` (public) — for `lt_display_rotate`.
- `DeviceStorageWork.claim/unclaim` — for `lt_storage_set` busy tracking.
- `CarrierPanelModel.apply(settings:)` — for `lt_carrier_set`.
- `DeviceOptions.setDebugPort(_:)` — for `lt_debug_port_set`.
- `AppInstaller.cancel(deviceID:bundleID:)` — for `lt_apps_cancel`.
- `DeviceSession+Capture`: `saveRecording(to:)`, `discardRecording()`,
  `hasFrame`, `canRecord`, `isRecording` — for §3.8 exports.
- `LTFileTransfers.get(_:)` — registry lookup for the transfer runner.

### 5. `LTAppCore`: `PrefsStore.swift` — file-backed UserDefaults (gap 5)

**What:** `LTFileDefaults`, a `UserDefaults` subclass backed by a JSON file,
used for Swift-owned prefs on Linux/Windows (where `UserDefaults.standard`
has no persistent backend).

**Why:** ABI.md §6 gap 5; `lt_settings_*`, capture prefs, and other Swift-owned
state need persistence.

### 6. `LTAppCore`: `ShmCapture.swift` — shm-ring reader + PNG encoder (gaps 4, 11)

**What:** `QtFrameMirror` (maps the same POSIX shm ring the Qt `DisplayItem`
maps), `ShmCapture.supplier(for:)` (frame supplier for
`ScreenRecordingSession`), `LTMPNG` (minimal portable PNG encoder — screenshots
were AppKit/CGImage upstream).

**Why:** ABI.md §3.8 / UI_APPROACH.md §4 rule 5: frames bypass the bridge;
capture/screenshots are produced Swift-side from the shm ring.

### 7. `LTAppCore`: `LogExports.swift` — log following (gap 7)

**What:** `LogFollowers` (subscription set with polling tasks) and
`LogSources` (source name → URL mapping).

**Why:** The Mac app's UI owned log following; the portable core needs it for
`lt_log_follow` / `kLTEventLogLine`.

### 2d. `LightTouchCore`: background-thread entry points for the state machines

**What:** The boot/shutdown/erase state machines (`BootCycle`,
`ShutdownLadder`, `DeviceErase`) are nonisolated classes that call their host
witnesses from background `Task`s. The host (our `DeviceSession`) is
nonisolated, but the underlying components are `@MainActor`. Added minimal
thread-safe entry points:
- `NetworkAccessPreference` → `nonisolated enum`; `DeviceOptions.bootArgs`
  (+ `verboseBootDefaultsKey`/`kernelConsoleDefaultsKey`) → nonisolated;
  `BootSettings` → `nonisolated struct` (pure value reads for `currentBootSettings`).
- `DeviceNotices.report`/`resolve`/`helperStarted`, `ReadinessWatch.start`,
  `DeviceRotation.reset`/`startInterfaceWatch`/`startGuestWatch`: called
  synchronously with no thread hop. (An earlier `Thread.isMainThread` guard
  that hopped via `Task { @MainActor in }` off-main was reverted: it broke
  synchronous test expectations, and on Linux the hop silently never executes
  without a pumped main queue. `AppChangeWatch.swift` is parent-owned; the
  parent keeps it synchronous for the same reason — do not add hops there.)
- `ReadinessWatch.current` → nonisolated via a `bootScopeRef`
  (`BootSessionScope` captured at init; thread-safe). An earlier lock-guarded
  mirror was reverted because it didn't clear on retire and broke
  `ReadinessWatchTests`.
- `VMState` → nonisolated (pure enum).

**Why:** ABI.md §4 requires commands to return in microseconds and the event
pump to run off the UI thread. The state machines drive boot/shutdown/erase
from background tasks; without these, every host witness would need an
`await` hop, breaking their synchronous protocol contracts.

**Upstream mirror:** None — upstream's `EmulatorController` is `@MainActor`
and the state machines run on the main actor there. The port's bridge needs
them callable from background threads.

### 2e. `LTAppCore`: `SessionDeviceHelper`, `WeakSessionBox`, `LTBox`, `ltCFree`

**What:**
- `SessionDeviceHelper` (in `DeviceSession+Hosts.swift`): nonisolated
  `DeviceHelper` facade. `isDead` reads the lock-guarded session state;
  `terminate`/`kill`/`waitForExit` hop to `@MainActor`. Returned by the
  `BootCycleHost.helper` witness (nil when no process, preserving BootCycle's
  "no helper → restart" logic).
- `WeakSessionBox`: lets `@MainActor init`-created closures reference the
  session before definite initialization completes (filled at end of init).
- `LTBox.get()`/`set()`: non-optional accessors for the region-isolation
  bridging pattern (synchronous C exports reading `@MainActor` state via
  semaphore).
- `ltCFree`: explicit C `free()` helper (fixes a shadowing bug where
  `ltFreeEventStrings`' nested `free` recursively called itself).
- `Sources/LTBridgeC/dummy.c`: empty translation unit so SwiftPM's linker
  finds a `.o` for the header-only `LTBridgeC` target.
- `Sources/LTAppCore/LTAppCore.swift`: `@_exported import LTBridgeC` so the
  ABI C types (`LTEvent`, etc.) are visible to clients without a separate
  import.
- `AppsHost.usbmuxSession`: reads `usbmuxSessionCached?.clientSocket` directly.
  A temporary `_bgUsbMuxSocket` string cache (22.04 build fix) was removed
  again after the parent made `USBMux.Session` a `nonisolated` Sendable struct
  (commit 7b962ad) — the cache is redundant with that fix.
- `FileOpDTO: Sendable`: explicit conformance to avoid Swift 6.4.1 compiler
  crash ("failed to produce diagnostic") when captured in `Task { @MainActor
  in }` (22.04 build fix).

**Why:** The `DeviceSession` must satisfy 10 nonisolated host protocols while
fronting `@MainActor` components. The session uses lock-guarded background
caches (refreshed by `poll()` on `@MainActor`) for witness reads, and
fire-and-forget `@MainActor` hops for witness commands.

**Linux @MainActor hop warning:** The witness commands use `Task { @MainActor
in }` hops. These ONLY execute if the Qt UI regularly calls
`lt_pump_main_queue()` (which runs the main RunLoop). On Linux without a
pumped main queue, they silently never run. This is by design for the Qt UI
integration, but must not be relied upon in contexts without the pump (see
AppChangeWatch, which the parent owns and keeps synchronous for this reason).

### 2f. `LTAppCore`: @MainActor-hop audit (background-thread paths) — 2026-10-16

**Status: FLAGGED FOR PARENT DISCUSSION — not fixed unilaterally.** Empirically
proven: `Task { @MainActor in }` from a background thread NEVER executes on
Linux without a pumped main queue (CLI/test processes have none; the Qt app's
main thread runs Qt's event loop, not Swift's MainActor drain). Full inventory
of LTAppCore's background-path hops and their failure modes on Linux:

**A. Fire-and-forget (silently dropped without pump):**
- `BootCycleHost.startBootWatch()` → `bootWatch.start()` never runs.
- `ShutdownHost.willStop()` / `EraseHost.discardInstalls()` →
  `AppInstaller.discard(for:)` never runs (stale installs linger).
- `EraseHost.stopGuestWatches()` → `rotation.stopWatching()` never runs.
- `ReadinessHost.pressHome()` → `input.tap(.home)` never runs.
- `SessionDeviceHelper.terminate()` / `.kill()` → helper process never
  signaled (BootCycle's restart path stalls).
- `DeviceSession.keyboardControl` → `bootScope.control` never runs.
- `lt_display_set_tilt`, `lt_files_*` (2 sites), `lt_catalog_*`/`lt_jobs_*`
  (8 sites), `lt_device_delete` (whole command body), capture teardown sites
  — command effects dropped.
- `DeviceSession` lifecycle notifications (`sessionStateChanged`,
  `sessionBootEnded`, `postDisplayLinkClosed`, spawn/death handling) —
  snapshots/events stop updating.

**B. `await` on the hop (HANGS the caller without pump — worse than a drop):**
- `BootCycleHost.halt()` returns `Task<Bool, Never>` that hops to `@MainActor`
  to run `ladder.halt()`; BootCycle awaits it from its background state
  machine → boot/shutdown sequencing hangs.
- `SessionDeviceHelper.waitForExit` does `await MainActor.run` to read
  `session?.process` (the read itself needs no hop — `process` is already a
  lock-guarded nonisolated property) and then awaits the `@MainActor`
  `DeviceProcess.waitForExit` → hangs.

**C. Verified SAFE (no change needed):**
- `MainActor.assumeIsolated` in `AppCore.startObservers`:
  `NotificationCenter.addObserver(..., queue: .main)` dispatches onto the main
  thread, so the block always runs on the main thread — no trap.
- `MainActor.assumeIsolated` in `storageWork.onChange` and
  `recording.onChange`/`onCompleted`: `DeviceStorageWork` and
  `ScreenRecordingSession` are `@MainActor` classes; the closures are only
  invoked from `@MainActor` methods (the recording producer `Task` inherits
  actor context via `@_inheritActorContext`). No trap — but note the producer
  task itself also needs the pump to run on Linux (LightTouchCore's design,
  same systemic issue).

**Why not fixed here:** every hop target (`ShutdownLadder`, `BootWatch`,
`DeviceRotation`, `DeviceInput`, `AppInstaller`, `DeviceProcess`,
`ScreenRecordingSession`, `CarrierModem`) is a `@MainActor` LightTouchCore
component. Making the commands synchronous requires either (a) a real
thread-safety redesign of those components (parent's area — they are mid-fix
on AppChangeWatch/USBMux and own that call), or (b) an ABI contract change
(e.g. "exports must be called on the main thread" + `assumeIsolated`, or a
dedicated LTAppCore serial queue whose blocks still can't touch `@MainActor`
state). Neither is a unilateral call; this inventory is the basis for that
discussion. Until then, `lt_pump_main_queue()` remains the documented
mechanism, and `swift test` covers the pump-independent paths
(queries, pure functions, event pump, string ownership) — command *effects*
are not asserted in tests for exactly this reason.

## ABI.md §6 gap coverage

| Gap | Status |
|-----|--------|
| 1. Portable app-core orchestrator | ✅ `AppCore`, `DeviceSession`, `EventPump` |
| 2. `lt_pump_main_queue` | ✅ Additive export (runs the `@MainActor` pump) |
| 3. String ownership | ✅ `ltAllocString` / `ltFreeString` with debug counters |
| 4. Shm-ring capture | ✅ `ShmCapture`, `QtFrameMirror`, `LTMPNG` |
| 5. UserDefaults equivalent | ✅ `LTFileDefaults` |
| 6. `DeviceNotices.shownOperation` | ✅ Added |
| 7. Log following | ✅ `LogFollowers` |
| 8. `lt_key_mac_from_evdev` | ✅ Additive export (evdev → Mac keycode map) |
| 9. `LTM_STATE_DIR` env override | ✅ In `AppCore.startup` |
| 10. Event coalescing | ✅ `EventPump` |
| 11. Recording save handshake | ✅ `kLTEventRecordingSaveNeeded` → `lt_capture_record_save`/`discard` |
| 12. Drop classification | ✅ `lt_drop_classify` (pure) |

## Platform notes

- No Linux-only APIs in Windows-shared paths. POSIX shm (`shm_open`) is in
  `ShmCapture.swift`; the Windows build will need a named-file-mapping
  equivalent (marked with `#if os()` splits where applicable).
- `LTMPNG` is pure Swift, portable to Windows.
- The `@_cdecl` exports are C-ABI; the `.dynamic` library links from Qt via
  the `lt_bridge.h` header.
