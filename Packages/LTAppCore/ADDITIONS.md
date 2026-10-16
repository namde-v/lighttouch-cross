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
