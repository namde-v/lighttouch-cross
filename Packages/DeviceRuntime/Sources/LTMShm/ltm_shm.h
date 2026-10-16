// C glue for the app <-> LightTouchDevice link (Linux redesign).
//
// The macOS version of this file (LTMLinkC/ltm_link.h upstream) did three
// things: atomics on the shared status block, the Mach rendezvous that moved
// IOSurface ports, and posix_spawn with the link socket as fd 3. Mach and
// IOSurface do not exist on Linux, so this file keeps the atomics and the
// spawn helper and replaces the rendezvous: the helper's first bytes on the
// private link socket are a small header, with the POSIX-shm file descriptors
// attached as SCM_RIGHTS ancillary data (DeviceRendezvous.swift).
//
// Windows: the whole transport is a named file mapping + a loopback socket
// (TRANSPORT_REDESIGN.md); this file deliberately refuses to compile there.

#ifndef LTM_SHM_H
#define LTM_SHM_H

#include <stdint.h>
#include <sys/types.h>

#ifdef _WIN32
#error "LTMShm: the Windows transport (named file mappings) is not implemented yet; see TRANSPORT_REDESIGN.md"
#endif

// Atomics on the shared status block (Swift cannot put an atomic at an
// arbitrary address). Same ordering contract as the macOS version:
// acquire/release for slots, seq-cst for the frameSerial/held handshake
// (writer: store serial, load held; reader: store held, load serial;
// acquire/release alone would let both sides miss).
static inline uint64_t ltm_load(const volatile uint64_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void ltm_store(volatile uint64_t *p, uint64_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
static inline uint64_t ltm_load_seq(const volatile uint64_t *p) { return __atomic_load_n(p, __ATOMIC_SEQ_CST); }
static inline void ltm_store_seq(volatile uint64_t *p, uint64_t v) { __atomic_store_n(p, v, __ATOMIC_SEQ_CST); }
static inline uint64_t ltm_add(volatile uint64_t *p, uint64_t v) { return __atomic_add_fetch(p, v, __ATOMIC_RELEASE); }

// One hello per link, helper -> app, over the private link socket (fd 3 in
// the helper): a fixed-size header describing the segments, with the shm fds
// attached as SCM_RIGHTS. nsegments is 1 (the status block alone) or 4
// (status block + the 3-surface frame ring); generation 0 means status only.
// The header must be the first bytes the helper writes on the socket.
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
    int fds[LTM_SHM_MAX_SEGMENTS];             // received fds; the caller owns (closes) them
    uint64_t byte_counts[LTM_SHM_MAX_SEGMENTS]; // shm size per segment, in fd order
} ltm_shm_hello;

// Helper: send the header + fds in one sendmsg. 0 on success, -errno on failure.
int ltm_send_hello(int sock, const char *token, uint32_t protocol_version,
                   uint64_t generation, const int *fds, const uint64_t *byte_counts, int nsegments);

// App: receive one hello; timeout_ms < 0 waits forever. 0 on success, else -errno:
//   -ETIMEDOUT  nothing arrived in time
//   -ECONNRESET EOF before any hello (the helper died first)
//   -EACCES     the token did not match
//   -EPROTOTYPE protocol_version mismatch
//   -ESRCH      the hello's SCM_CREDENTIALS pid is not expected_pid
//   -EBADMSG    malformed header or control data
// A failed call owns nothing (any received fds are closed inside).
int ltm_recv_hello(int sock, int timeout_ms, const char *expected_token,
                   uint32_t expected_protocol, pid_t expected_pid,
                   ltm_shm_hello *out);

// Spawn with stdin /dev/null, stdout+stderr on out_fd, the link socket on fd 3
// and nothing else inherited (default signal dispositions). The macOS build
// used POSIX_SPAWN_CLOEXEC_DEFAULT for the "nothing else"; glibc has no such
// flag, so this closes every other fd via file actions (see the .c).
// Returns the pid, or -errno.
pid_t ltm_spawn(const char *path, char *const argv[], char *const envp[], int out_fd, int link_fd);

// CLOCK_MONOTONIC in nanoseconds: the publish tick (mach_absolute_time's
// replacement; not wall time, so NTP steps never confuse the stall detector).
uint64_t ltm_monotonic_ns(void);

#endif
