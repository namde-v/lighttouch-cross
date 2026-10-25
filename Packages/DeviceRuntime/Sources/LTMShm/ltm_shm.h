// C glue for the app <-> LightTouchDevice link.
//
// Linux: POSIX shm segments + an SCM_RIGHTS hello over a socketpair
// (see TRANSPORT_REDESIGN.md).
//
// Windows: named file mappings + a loopback TCP socket (Winsock has no
// socketpair). The hello carries the mapping NAMES (derived from the one-time
// token), not handles — the app re-opens each segment by name with
// OpenFileMapping. The link socket HANDLE is passed to the helper via the
// LTM_LINK_SOCKET environment variable (see ltm_spawn); the helper's first
// bytes on it are the hello, same as Linux.

#ifndef LTM_SHM_H
#define LTM_SHM_H

#include <stdint.h>
#include <sys/types.h>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <windows.h>
// Windows has no pid_t; use int so the -1 "unknown pid" sentinel keeps working.
// (Windows PIDs are DWORDs, which always fit in an int.)
typedef int pid_t;
#endif

// Atomics on the shared status block (Swift cannot put an atomic at an
// arbitrary address). Same ordering contract as the macOS version:
// acquire/release for slots, seq-cst for the frameSerial/held handshake
// (writer: store serial, load held; reader: store held, load serial;
// acquire/release alone would let both sides miss).
// (Clang, which SwiftPM uses even on Windows, supports the __atomic_*
// builtins on all platforms.)
static inline uint64_t ltm_load(const volatile uint64_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void ltm_store(volatile uint64_t *p, uint64_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
static inline uint64_t ltm_load_seq(const volatile uint64_t *p) { return __atomic_load_n(p, __ATOMIC_SEQ_CST); }
static inline void ltm_store_seq(volatile uint64_t *p, uint64_t v) { __atomic_store_n(p, v, __ATOMIC_SEQ_CST); }
static inline uint64_t ltm_add(volatile uint64_t *p, uint64_t v) { return __atomic_add_fetch(p, v, __ATOMIC_RELEASE); }

// One hello per link, helper -> app.
// Linux: a fixed-size header describing the segments, with the shm fds
// attached as SCM_RIGHTS ancillary data. nsegments is 1 (the status block
// alone) or 4 (status block + the 3-surface frame ring); generation 0 means
// status only. The header must be the first bytes the helper writes.
// Windows: the same header sent over the loopback socket, but WITHOUT fd
// passing (Winsock cannot do SCM_RIGHTS). Instead each segment is a NAMED
// file mapping ("LTMShm_<token>_<index>"); the app re-opens them by name.
// The fds[] parameter to ltm_send_hello is ignored on Windows.
#define LTM_SHM_MAX_SEGMENTS 4  // status block + 3-surface frame ring

typedef struct {
    char token[64];            // the one-time token from argv, NUL-terminated
    uint32_t protocol_version; // DeviceLinkWire.protocolVersion
    uint32_t nsegments;        // 1 or 4
    uint64_t generation;       // ring generation; 0 = status block only
    uint64_t byte_counts[LTM_SHM_MAX_SEGMENTS];  // shm size per segment, in fd order
} ltm_shm_hello_hdr;

typedef struct {
    uint64_t generation;
    int nsegments;                             // 1 or 4
    int fds[LTM_SHM_MAX_SEGMENTS];             // received fds (POSIX); on Windows,
                                               // the named-mapping HANDLEs truncated
                                               // to int (see ltm_recv_hello)
    uint64_t byte_counts[LTM_SHM_MAX_SEGMENTS]; // shm size per segment, in order
} ltm_shm_hello;

// The hello mapping name for (token, index): "LTMShm_<token>_<index>".
// Exported so Swift creation (the helper side) derives exactly the name the
// C receive side re-opens — one implementation of the name scheme, no drift.
void ltm_mapping_name(const char *token, int index, char *out, size_t outlen);

// Helper: send the header (plus fds on POSIX). 0 on success, -errno on failure.
int ltm_send_hello(int sock, const char *token, uint32_t protocol_version,
                   uint64_t generation, const int *fds, const uint64_t *byte_counts, int nsegments);

// App: receive one hello; timeout_ms < 0 waits forever. 0 on success, else -errno:
//   -ETIMEDOUT  nothing arrived in time
//   -ECONNRESET EOF before any hello (the helper died first)
//   -EACCES     the token did not match
//   -EPROTOTYPE protocol_version mismatch
//   -ESRCH      (POSIX only) the hello's SCM_CREDENTIALS pid is not expected_pid
//   -EBADMSG    malformed header
//   -ENOENT     (Windows only) a named mapping could not be opened
// A failed call owns nothing (any received fds/handles are closed inside).
// On Windows the pid check is skipped: there is no SCM_CREDENTIALS equivalent
// for loopback sockets, so the one-time token is the authentication (the
// socket is still private to this spawn).
int ltm_recv_hello(int sock, int timeout_ms, const char *expected_token,
                   uint32_t expected_protocol, pid_t expected_pid,
                   ltm_shm_hello *out);

// Spawn with stdin NUL, stdout+stderr on out_fd, the link socket available to
// the child, and nothing else inherited (default signal dispositions).
// POSIX: the link socket is dup'd to fd 3; every other fd is closed.
// Windows: the link socket HANDLE is inherited and its value passed via the
// LTM_LINK_SOCKET environment variable; only out_fd/link handles are inherited
// (PROC_THREAD_ATTRIBUTE_HANDLE_LIST).
// Returns the pid, or -errno.
pid_t ltm_spawn(const char *path, char *const argv[], char *const envp[], int out_fd, int link_fd);

// CLOCK_MONOTONIC in nanoseconds (QueryPerformanceCounter on Windows):
// the publish tick; not wall time, so NTP steps never confuse the stall detector.
uint64_t ltm_monotonic_ns(void);

#endif
