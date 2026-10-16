/*
 * lt_bridge.h — the C contract between the portable Swift core (libLTAppCore)
 * and the Qt 6 UI. Normative companion to ui/ABI.md; this header IS the ABI.
 *
 * Versioned as a whole: see lt_abi_version(). Additive-only evolution:
 * new functions, new kLTEventKind values (>= kLTEventReservedStart), new enum
 * constants and new JSON fields may be added without breaking; nothing is
 * removed or renumbered within a major ABI version.
 *
 * Conventions (ui/ABI.md §1):
 *  - Only C types cross. Bool is int32_t (0/1), never _Bool in structs.
 *  - Strings are UTF-8 NUL-terminated. Callee allocates, caller frees with
 *    lt_free_string(). Strings passed IN are borrowed (Swift copies).
 *  - Every command/query returns LTResult (0 ok/accepted, <0 error);
 *    lt_last_error() explains the most recent failure on the calling thread.
 *  - Timestamps cross as double seconds since the Unix epoch (UTC).
 *  - Device/session references are lt_device_t (uint64_t); 0 is invalid.
 *  - Complex state crosses as a single JSON document (const char*).
 */
#ifndef LT_BRIDGE_H
#define LT_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/* 1. Result codes (ui/ABI.md §1.4)                                    */
/* ------------------------------------------------------------------ */
typedef int32_t LTResult;
#define kLTOk            0  /* accepted / succeeded */
#define kLTAccepted      0  /* alias: command enqueued; outcome arrives as LTEvent */
#define kLTBadArgument  -1  /* null pointer, malformed UTF-8/JSON/UUID, out-of-range */
#define kLTNoSuchDevice -2  /* unknown lt_device_t or UUID */
#define kLTNotReady     -3  /* core not initialized, or session not in a usable state */
#define kLTBusy         -4  /* an exclusive operation is already running */
#define kLTFailed       -5  /* anything else; detail in lt_last_error() */

/* Opaque per-device handle minted by the core at startup (ui/ABI.md §1.2).
 * Stable for the process lifetime; 0 is never a valid handle. */
typedef uint64_t lt_device_t;

/* ------------------------------------------------------------------ */
/* 2. Event kinds (ui/ABI.md §2.3)                                     */
/* ------------------------------------------------------------------ */
typedef int32_t LTEventKind;

#define kLTEventDeviceListChanged         1
#define kLTEventDeviceRowChanged          2
#define kLTEventSidebarChanged            3
#define kLTEventDeviceStatusChanged       4
#define kLTEventBootStage                 5
#define kLTEventNoticeChanged             6
#define kLTEventStorageBusyChanged        7
#define kLTEventDisplayLinkReady          8
#define kLTEventDisplayLinkClosed         9
#define kLTEventFrameAvailable           10
#define kLTEventRotationChanged           11
#define kLTEventZoomChanged               12
#define kLTEventFingerDotsChanged         13
#define kLTEventTweaksChanged             14
#define kLTEventHiddenAppsListed          15
#define kLTEventCarrierChanged            16
#define kLTEventAppsChanged               17
#define kLTEventInstallProgress           18
#define kLTEventInstallDone               19
#define kLTEventFilesListed               20
#define kLTEventFilesProgress             21
#define kLTEventFilesDone                 22
#define kLTEventFilesConnectionChanged    23
#define kLTEventLogLine                   24
#define kLTEventLogRotated                25
#define kLTEventCaptureAvailabilityChanged 26
#define kLTEventCaptureDone               27
#define kLTEventRecordingTick             28
#define kLTEventRecordingPhaseChanged     29
#define kLTEventRecordingSaveNeeded       30
#define kLTEventCatalogChanged            31
#define kLTEventJobProgress               32
#define kLTEventJobDone                   33
#define kLTEventTaskbarProgress           34
#define kLTEventToast                     35
#define kLTEventDropAction                36
#define kLTEventNetworkAccessChanged      37
#define kLTEventQuitReady                 38
#define kLTEventShutdown                  39

/* First value available to future extension without renumbering. */
#define kLTEventReservedStart 0x1000

/* ------------------------------------------------------------------ */
/* 3. Enumerations used across the boundary                            */
/* ------------------------------------------------------------------ */

/* VM lifecycle (LightTouchCore.VMState). */
#define kLTVMStateNotStarted 0
#define kLTVMStateBooting    1
#define kLTVMStateRunning    2
#define kLTVMStatePaused     3
#define kLTVMStatePoweredOff 4
#define kLTVMStateDead       5

/* Boot phases (LightTouchCore.BootStage). */
#define kLTBootStagePoweringOn 0
#define kLTBootStageLoading    1
#define kLTBootStageKernel     2
#define kLTBootStageSystem     3
#define kLTBootStageUsb        4

/* Frame-ring pixel format. The ring always carries tightly packed BGRA. */
#define kLTPixelFormatBGRA32 0

/* Touch phases for lt_input_touch (one call per touch id). */
#define kLTTouchBegan     0
#define kLTTouchMoved     1
#define kLTTouchEnded     2
#define kLTTouchCancelled 3

/* Hardware buttons (DeviceInput.Button raw values, qemu-ios-ui.h). */
#define kLTButtonHome       0
#define kLTButtonPower      1
#define kLTButtonVolumeUp   2
#define kLTButtonVolumeDown 3

/* Motion poses (DeviceInput.MotionPose raw values). */
#define kLTMotionPoseUpright 0
#define kLTMotionPoseFlat    1

/* Files connection states (FilesConnection.State). */
#define kLTFilesStateDisconnected 0
#define kLTFilesStateConnected    1
#define kLTFilesStateTransferring 2

/* Local-network permission states. */
#define kLTNetworkAccessUnknown 0
#define kLTNetworkAccessAllowed 1
#define kLTNetworkAccessDenied  2

/* Device menu items for lt_menu_validate (DeviceMenuState.Item). */
#define kLTMenuItemLock           0
#define kLTMenuItemRotate         1
#define kLTMenuItemCompassHeading 2
#define kLTMenuItemCarrier        3
#define kLTMenuItemInput          4
#define kLTMenuItemPause          5
#define kLTMenuItemRestart        6

/* Capture kinds for kLTEventCaptureDone. */
#define kLTCaptureScreenshot 0
#define kLTCaptureRecording  1

/* Recording phases (ScreenRecordingSession.Phase). */
#define kLTRecordingPhaseIdle      0
#define kLTRecordingPhaseStarting  1
#define kLTRecordingPhaseRecording 2
#define kLTRecordingPhaseSaving    3

/* Key modifiers bitmask for lt_input_key (KeyModifiers). */
#define kLTModifierShift   1
#define kLTModifierControl 2
#define kLTModifierOption  4
#define kLTModifierCommand 8

/* Device-row states for lt_device_list (DeviceRowState, flattened). */
#define kLTDeviceRowStateNotDownloaded 0
#define kLTDeviceRowStateDownloaded    1
#define kLTDeviceRowStateBundled       2
#define kLTDeviceRowStateDownloading   3
#define kLTDeviceRowStatePreparing     4
#define kLTDeviceRowStateReady         5
#define kLTDeviceRowStateRunning       6
#define kLTDeviceRowStateStopping      7
#define kLTDeviceRowStateDeleting      8
#define kLTDeviceRowStateErasing       9
#define kLTDeviceRowStateError         10
#define kLTDeviceRowStateUnavailable   11

/* Drop classifications for lt_drop_classify (DroppedFiles). */
#define kLTDropIPSW        0
#define kLTDropIPA         1
#define kLTDropMedia       2
#define kLTDropUnsupported 3

/* ------------------------------------------------------------------ */
/* 4. The LTEvent tagged union (ui/ABI.md §2)                          */
/*                                                                     */
/* The pointed-to LTEvent is valid only for the duration of the        */
/* callback. The trampoline must deep-copy it (including strings) and */
/* release the original's strings with lt_free_event_strings() before  */
/* returning. String fields are malloc'd by Swift; NULL means absent.  */
/* ------------------------------------------------------------------ */

typedef struct LTEventDeviceRowChanged    { lt_device_t device; } LTEventDeviceRowChanged;
typedef struct LTEventDeviceStatusChanged { int32_t machine; int32_t running; int32_t sleeping; } LTEventDeviceStatusChanged;
typedef struct LTEventBootStage           { int32_t stage; const char* detail; double fraction; } LTEventBootStage;
typedef struct LTEventNoticeChanged       { const char* message; const char* operation; int32_t offersErase; } LTEventNoticeChanged;
typedef struct LTEventDisplayLinkReady    { int32_t fd; int32_t width; int32_t height; int32_t stride; int32_t format; uint64_t ringGeneration; } LTEventDisplayLinkReady;
typedef struct LTEventFrameAvailable      { uint64_t frameSeq; int32_t width; int32_t height; } LTEventFrameAvailable;
typedef struct LTEventRotationChanged     { int32_t degrees; int32_t width; int32_t height; } LTEventRotationChanged;
typedef struct LTEventZoomChanged         { double points; const char* mode; } LTEventZoomChanged;
typedef struct LTEventFingerDotsChanged   { int32_t shown; } LTEventFingerDotsChanged;
typedef struct LTEventHiddenAppsListed    { const char* appsJson; } LTEventHiddenAppsListed;
typedef struct LTEventInstallProgress     { const char* bundleId; double fraction; const char* phase; } LTEventInstallProgress;
typedef struct LTEventInstallDone         { const char* bundleId; int32_t ok; const char* message; } LTEventInstallDone;
typedef struct LTEventFilesListed         { uint64_t requestId; const char* entriesJson; } LTEventFilesListed;
typedef struct LTEventFilesProgress       { uint64_t transferId; double fraction; const char* currentFile; int64_t bytesDone; int64_t bytesTotal; } LTEventFilesProgress;
typedef struct LTEventFilesDone           { uint64_t transferId; int32_t ok; int32_t cancelled; const char* message; } LTEventFilesDone;
typedef struct LTEventFilesConnectionChanged { int32_t state; } LTEventFilesConnectionChanged;
typedef struct LTEventLogLine             { const char* source; const char* text; uint64_t offset; } LTEventLogLine;
typedef struct LTEventLogRotated          { const char* source; } LTEventLogRotated;
typedef struct LTEventCaptureDone         { int32_t kind; const char* path; int32_t ok; const char* message; } LTEventCaptureDone;
typedef struct LTEventRecordingTick       { uint64_t elapsedSeconds; } LTEventRecordingTick;
typedef struct LTEventRecordingPhaseChanged { int32_t phase; } LTEventRecordingPhaseChanged;
typedef struct LTEventRecordingSaveNeeded { const char* suggestedName; } LTEventRecordingSaveNeeded;
typedef struct LTEventJobProgress         { const char* entryId; double fraction; const char* detail; double etaSeconds; int32_t step; int32_t steps; } LTEventJobProgress;
typedef struct LTEventJobDone             { const char* entryId; int32_t ok; int32_t cancelled; const char* message; } LTEventJobDone;
typedef struct LTEventTaskbarProgress     { double fraction; } LTEventTaskbarProgress;
typedef struct LTEventToast               { const char* title; const char* body; const char* category; } LTEventToast;
typedef struct LTEventDropAction          { uint64_t requestId; const char* action; const char* detailJson; } LTEventDropAction;
typedef struct LTEventNetworkAccessChanged { int32_t state; } LTEventNetworkAccessChanged;

typedef struct LTEvent {
    LTEventKind kind;
    lt_device_t device;   /* 0 when the event is not device-scoped */
    uint64_t    seq;      /* per-kind monotonic sequence; 0 when unused */
    union {
        LTEventDeviceRowChanged       deviceRowChanged;
        LTEventDeviceStatusChanged    deviceStatusChanged;
        LTEventBootStage              bootStage;
        LTEventNoticeChanged          noticeChanged;
        LTEventDisplayLinkReady       displayLinkReady;
        LTEventFrameAvailable         frameAvailable;
        LTEventRotationChanged        rotationChanged;
        LTEventZoomChanged            zoomChanged;
        LTEventFingerDotsChanged      fingerDotsChanged;
        LTEventHiddenAppsListed       hiddenAppsListed;
        LTEventInstallProgress        installProgress;
        LTEventInstallDone            installDone;
        LTEventFilesListed            filesListed;
        LTEventFilesProgress          filesProgress;
        LTEventFilesDone              filesDone;
        LTEventFilesConnectionChanged filesConnectionChanged;
        LTEventLogLine                logLine;
        LTEventLogRotated             logRotated;
        LTEventCaptureDone            captureDone;
        LTEventRecordingTick          recordingTick;
        LTEventRecordingPhaseChanged  recordingPhaseChanged;
        LTEventRecordingSaveNeeded    recordingSaveNeeded;
        LTEventJobProgress            jobProgress;
        LTEventJobDone                jobDone;
        LTEventTaskbarProgress        taskbarProgress;
        LTEventToast                  toast;
        LTEventDropAction             dropAction;
        LTEventNetworkAccessChanged   networkAccessChanged;
    } u;
} LTEvent;

/* The Swift→C++ event callback (ui/ABI.md §2.1, §2.4). Must be a leaf:
 * copy the event, queue it, return. Must not call back into lt_ functions. */
typedef void (*lt_event_fn)(const LTEvent* event, void* ctx);

/* ------------------------------------------------------------------ */
/* 5. Exported functions (ui/ABI.md §3)                                */
/*                                                                     */
/* Classes: command = validates, enqueues onto @MainActor, returns     */
/* kLTAccepted within microseconds (outcome arrives as an LTEvent);    */
/* query = synchronous lock-protected snapshot, never waits on         */
/* @MainActor; pure = lock-free, callable from any thread including    */
/* the Qt render thread.                                               */
/*                                                                     */
/* String ownership (ui/ABI.md §1.3): every `const char*` returned via */
/* an out-param or return slot is malloc'd by Swift and owned by the   */
/* caller — free with lt_free_string(), never free() directly. Strings */
/* passed IN are borrowed: Swift copies what it needs.                 */
/* ------------------------------------------------------------------ */

/* ---- 3.1 Lifecycle ---- */
LTResult lt_init(const char* configJson);            /* command (runs once) */
LTResult lt_shutdown(void);                         /* command */
LTResult lt_set_event_callback(lt_event_fn fn, void* ctx); /* command */
int32_t  lt_abi_version(void);                      /* pure */
LTResult lt_version(const char** out);              /* query */
void     lt_free_string(const char* s);             /* pure, NULL-safe */
void     lt_free_event_strings(const LTEvent* e);   /* pure */
LTResult lt_quit_request(void);                     /* command */
LTResult lt_about_credits(const char** out);        /* query */

/* ---- 3.2 Device library & rows ---- */
LTResult lt_device_list(const char** out);                        /* query */
LTResult lt_device_find(const char* uuid, lt_device_t* out);     /* query */
LTResult lt_device_uuid(lt_device_t device, const char** out);   /* query */
LTResult lt_device_row(lt_device_t device, const char** out);    /* query */
LTResult lt_device_create(const char* entryId, const char* name, lt_device_t* out); /* command */
LTResult lt_device_delete(lt_device_t device);                   /* command */
LTResult lt_device_rename(lt_device_t device, const char* name); /* command */
LTResult lt_device_duplicate(lt_device_t device, lt_device_t* out); /* command */
LTResult lt_device_erase(lt_device_t device);                    /* command */
LTResult lt_storage_busy(const char** out);                     /* query */
LTResult lt_sidebar_list(const char** out);                      /* query */
LTResult lt_sidebar_add(const char* idsJson);                    /* command */
LTResult lt_sidebar_remove(const char* entryId);                 /* command */
LTResult lt_sidebar_rename(const char* entryId, const char* name);/* command */

/* ---- 3.3 Session lifecycle & status ---- */
LTResult lt_device_boot(lt_device_t device, const char* optionsJson); /* command */
LTResult lt_device_halt(lt_device_t device);                          /* command */
LTResult lt_device_pause(lt_device_t device, int32_t paused);         /* command */
LTResult lt_device_reset(lt_device_t device);                         /* command */
LTResult lt_device_lock(lt_device_t device, int32_t locked);          /* command */
LTResult lt_device_status(lt_device_t device, const char** out);      /* query */
LTResult lt_menu_validate(lt_device_t device, int32_t item, int32_t arg, const char** out); /* query */
LTResult lt_capture_availability(lt_device_t device, const char** out); /* query */
LTResult lt_notice_get(lt_device_t device, const char** out);        /* query */
LTResult lt_notice_resolve(lt_device_t device, const char* operation);/* command */
LTResult lt_notice_dismiss(lt_device_t device);                      /* command */
LTResult lt_network_status(const char** out);                        /* query */
LTResult lt_network_set_allowed(int32_t allowed);                    /* command */

/* ---- 3.4 Display & input ---- */
LTResult lt_input_touch(lt_device_t d, int32_t phase, double x, double y, int32_t touchId); /* command */
LTResult lt_input_key(lt_device_t d, uint16_t code, int32_t down, int32_t modifiers);       /* command */
LTResult lt_input_text(lt_device_t d, const char* text, int32_t shiftHeld);                 /* command */
LTResult lt_input_button(lt_device_t d, int32_t button);                                    /* command */
LTResult lt_input_shake(lt_device_t d);                                                     /* command */
LTResult lt_input_tilt(lt_device_t d, double angle, double pitch);                          /* command */
LTResult lt_input_motion_pose(lt_device_t d, int32_t pose);                                 /* command */
LTResult lt_input_rotate(lt_device_t d, int32_t degrees);                                   /* command */
LTResult lt_input_compass(lt_device_t d, int32_t heading);                                  /* command */
LTResult lt_input_keyboard_pointer_key(lt_device_t d, uint16_t code, int32_t down, int32_t modifiers); /* command */
/* Additive (gap 8): evdev keycode -> Mac USB HID keycode for lt_input_key. */
uint16_t lt_key_mac_from_evdev(int32_t evdevCode); /* pure */
LTResult lt_display_set_zoom(lt_device_t d, const char* mode);      /* command */
LTResult lt_display_get_zoom(lt_device_t d, const char** out);      /* query */
LTResult lt_zoom_stops_json(double fit, double physical, double backing, const char** out); /* pure; physical < 0 = none */
double   lt_zoom_step(double fit, double physical, double backing, double p, int32_t direction); /* pure; -1 past end */
int32_t  lt_zoom_draws_nearest(double p, double backing);           /* pure */
LTResult lt_resize_drag(const char* board, double startW, double startH,
                        double edgeX, double edgeY, double deltaX, double deltaY,
                        double pointsPerPixel, int32_t symmetric, int32_t quarterTurned,
                        const char** out);                          /* pure */
LTResult lt_display_set_panel_size(lt_device_t d, int32_t width, int32_t height); /* command */
LTResult lt_display_set_finger_dots(lt_device_t d, int32_t shown);  /* command */
LTResult lt_display_get_finger_dots(lt_device_t d, int32_t* out);   /* query */

/* ---- 3.5 Inspector panels ---- */
LTResult lt_tweaks_get(lt_device_t d, const char** out);                    /* query */
LTResult lt_tweaks_set(lt_device_t d, const char* tweakId, int32_t on);     /* command */
LTResult lt_tweaks_set_color(lt_device_t d, int32_t color);                 /* command */
LTResult lt_tweaks_set_clock(lt_device_t d, double epoch);                  /* command */
LTResult lt_tweaks_list_hidden_apps(lt_device_t d);                         /* command */
LTResult lt_tweaks_open_app(lt_device_t d, const char* bundleId);           /* command */
LTResult lt_carrier_set_visible(lt_device_t d, int32_t visible);            /* command */
LTResult lt_carrier_get(lt_device_t d, const char** out);                   /* query */
LTResult lt_carrier_set_field(lt_device_t d, const char* field, const char* value); /* command */
LTResult lt_carrier_apply_network(lt_device_t d);                           /* command */
LTResult lt_carrier_set_registered(lt_device_t d, int32_t registered);      /* command */
LTResult lt_carrier_set_sim(lt_device_t d, int32_t present);                /* command */
LTResult lt_carrier_set_bars(lt_device_t d, int32_t bars);                  /* command */
LTResult lt_carrier_ring(lt_device_t d);                                    /* command */
LTResult lt_carrier_answer(lt_device_t d);                                  /* command */
LTResult lt_carrier_hangup(lt_device_t d);                                  /* command */
LTResult lt_carrier_send_sms(lt_device_t d);                                /* command */
LTResult lt_carrier_apply_location(lt_device_t d);                          /* command */
LTResult lt_carrier_set_location(lt_device_t d, double lat, double lon);    /* command */
LTResult lt_carrier_toggle_walk(lt_device_t d);                             /* command */
LTResult lt_carrier_notice(lt_device_t d, const char* text);                /* command */
LTResult lt_storage_get(lt_device_t d, const char** out);                   /* query */
LTResult lt_storage_set(lt_device_t d, const char* json);                   /* command */
LTResult lt_proxy_get(lt_device_t d, const char** out);                     /* query */
LTResult lt_proxy_set(lt_device_t d, const char* json);                     /* command */
LTResult lt_debug_port_get(lt_device_t d, const char** out);                /* query */
LTResult lt_debug_port_set(lt_device_t d, const char* json);                /* command */

/* ---- 3.6 Apps inspector ---- */
LTResult lt_apps_list(lt_device_t d, const char** out);                     /* query */
LTResult lt_apps_refresh(lt_device_t d);                                    /* command */
LTResult lt_apps_install(lt_device_t d, const char* ipaPath);               /* command */
LTResult lt_apps_remove(lt_device_t d, const char* bundleId);               /* command */
LTResult lt_apps_cancel_install(lt_device_t d, const char* bundleId);       /* command */
LTResult lt_apps_restart_springboard(lt_device_t d);                        /* command */
LTResult lt_apps_import_media(lt_device_t d, const char* pathsJson);       /* command */
LTResult lt_apps_store_search(lt_device_t d, const char* query, const char** out); /* query */

/* ---- 3.7 Files browser ---- */
LTResult lt_files_follow(lt_device_t d, int32_t follow);          /* command */
LTResult lt_files_state(const char** out);                        /* query */
LTResult lt_files_list(lt_device_t d, const char* path, uint64_t* requestIdOut); /* command */
LTResult lt_files_transfer(lt_device_t d, const char* opJson, uint64_t* transferIdOut); /* command */
LTResult lt_files_cancel(uint64_t transferId);                    /* command */

/* ---- 3.8 Capture ---- */
LTResult lt_capture_screenshot(lt_device_t d);                    /* command */
LTResult lt_capture_record_start(lt_device_t d);                 /* command */
LTResult lt_capture_record_stop(lt_device_t d, int32_t discard); /* command */
LTResult lt_capture_record_save(lt_device_t d, const char* path);/* command */
LTResult lt_capture_record_discard(lt_device_t d);               /* command */
LTResult lt_capture_prefs_get(const char** out);                 /* query */
LTResult lt_capture_prefs_set(const char* json);                 /* command */

/* ---- 3.9 Log & console ---- */
LTResult lt_log_sources(const char** out);                       /* query */
LTResult lt_log_read(const char* source, uint64_t from, const char** out); /* query */
LTResult lt_log_follow(const char* source, int32_t follow);      /* command */
LTResult lt_log_clear(const char* source);                       /* command */
int32_t  lt_log_filter(const char* text, const char* filter, const char** out); /* pure */

/* ---- 3.10 Firmware catalog & jobs ---- */
LTResult lt_catalog_list(const char* filterJson, const char** out); /* query */
LTResult lt_catalog_details(const char* entryId, const char** out); /* query */
LTResult lt_jobs_list(const char** out);                            /* query */
LTResult lt_job_start(const char* entryId, const char* optionsJson);/* command */
LTResult lt_job_import_ipsw(const char* pathsJson);                 /* command */
LTResult lt_job_cancel(const char* entryId);                        /* command */
LTResult lt_job_cancel_all(void);                                   /* command */
LTResult lt_job_dismiss_failure(const char* entryId);               /* command */
LTResult lt_jobs_can_download(int32_t* out);                        /* query */
LTResult lt_drop_classify(const char* path, int32_t* out);          /* pure */
LTResult lt_drop_ipsws(const char* pathsJson, const char** out);    /* query */
LTResult lt_drop_route(const char* pathsJson, const char* target, uint64_t* requestIdOut); /* command */

/* ---- 3.11 Settings & misc ---- */
LTResult lt_settings_get_string(const char* key, const char** out); /* query */
LTResult lt_settings_set_string(const char* key, const char* value);/* command */
LTResult lt_help_topics(const char** out);                          /* query */
LTResult lt_diagnostics_export(const char** out);                   /* command */
uint64_t lt_debug_dropped_events(void);                              /* pure */

/*
 * ADDITION (not in ui/ABI.md §3; additive-only, see ADDITIONS.md):
 * lt_pump_main_queue() drains Swift's @MainActor executor on the calling
 * thread. The Qt UI thread is the process main thread; @MainActor work
 * enqueued by commands only runs when the main dispatch queue is drained.
 * Qt integrates this by calling lt_pump_main_queue() from a zero-interval
 * QTimer (or after each batch of lt_ calls). Safe to call from any thread;
 * only drains when called on the main thread. Pure (never blocks beyond
 * `budgetMs`).
 */
void lt_pump_main_queue(double budgetMs);                            /* pure */

#ifdef __cplusplus
}
#endif

#endif /* LT_BRIDGE_H */
