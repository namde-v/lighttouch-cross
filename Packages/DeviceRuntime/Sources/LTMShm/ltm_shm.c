#define _GNU_SOURCE
#include "ltm_shm.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

int ltm_send_hello(int sock, const char *token, uint32_t protocol_version,
                   uint64_t generation, const int *fds, const uint64_t *byte_counts, int nsegments) {
    if (nsegments != 1 && nsegments != LTM_SHM_MAX_SEGMENTS)
        return -EINVAL;
    if (!fds || !byte_counts)
        return -EINVAL;

    ltm_shm_hello_hdr hdr;
    memset(&hdr, 0, sizeof hdr);
    strncpy(hdr.token, token, sizeof(hdr.token) - 1);
    hdr.protocol_version = protocol_version;
    hdr.nsegments = (uint32_t)nsegments;
    hdr.generation = generation;
    for (int i = 0; i < nsegments; i++)
        hdr.byte_counts[i] = byte_counts[i];

    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    struct iovec iov = { .iov_base = &hdr, .iov_len = sizeof hdr };
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;

    // One sendmsg carries the header and the fds together, so the app's one
    // recvmsg gets exactly this hello (ancillary data is not split across
    // reads on a unix socket).
    char cmsgbuf[CMSG_SPACE(LTM_SHM_MAX_SEGMENTS * sizeof(int))];
    memset(cmsgbuf, 0, sizeof cmsgbuf);
    msg.msg_control = cmsgbuf;
    msg.msg_controllen = CMSG_SPACE((size_t)nsegments * sizeof(int));
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN((size_t)nsegments * sizeof(int));
    memcpy(CMSG_DATA(cmsg), fds, (size_t)nsegments * sizeof(int));

    ssize_t n = sendmsg(sock, &msg, MSG_NOSIGNAL);
    if (n < 0)
        return -errno;
    if ((size_t)n != sizeof hdr)
        return -EIO; // a stream socket took only part of the header: the peer is broken
    return 0;
}

// Close any file descriptors that arrived as SCM_RIGHTS in a message we are
// about to reject, so a malformed hello cannot leak fds into the app.
static void close_received_fds(struct msghdr *msg) {
    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(msg); cmsg; cmsg = CMSG_NXTHDR(msg, cmsg)) {
        if (cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS)
            continue;
        size_t n = 0;
        if (cmsg->cmsg_len >= CMSG_LEN(0))
            n = (cmsg->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        int *fds = (int *)CMSG_DATA(cmsg);
        for (size_t i = 0; i < n && i < LTM_SHM_MAX_SEGMENTS; i++)
            if (fds[i] >= 0)
                close(fds[i]);
    }
}

int ltm_recv_hello(int sock, int timeout_ms, const char *expected_token,
                   uint32_t expected_protocol, pid_t expected_pid,
                   ltm_shm_hello *out) {
    memset(out, 0, sizeof *out);
    for (int i = 0; i < LTM_SHM_MAX_SEGMENTS; i++)
        out->fds[i] = -1;

    // Ask the kernel to attach the sender's credentials to the hello, so the
    // pid can be checked below. (SO_PEERCRED is the wrong tool here: on a
    // socketpair it reports the socket's creator — this process — not the
    // child that later inherited the fd.)
    int passcred = 0;
    {
        int one = 1;
        if (setsockopt(sock, SOL_SOCKET, SO_PASSCRED, &one, sizeof one) == 0)
            passcred = 1;
    }

    struct pollfd pfd = { .fd = sock, .events = POLLIN, .revents = 0 };
    int pr = poll(&pfd, 1, timeout_ms);
    if (pr < 0)
        return -errno;
    if (pr == 0)
        return -ETIMEDOUT;

    ltm_shm_hello_hdr hdr;
    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    struct iovec iov = { .iov_base = &hdr, .iov_len = sizeof hdr };
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    // Room for the SCM_RIGHTS fd list plus the SCM_CREDENTIALS the kernel
    // attaches when SO_PASSCRED is set (a short buffer truncates -> MSG_CTRUNC).
    char cmsgbuf[CMSG_SPACE(LTM_SHM_MAX_SEGMENTS * sizeof(int)) + CMSG_SPACE(sizeof(struct ucred))];
    memset(cmsgbuf, 0, sizeof cmsgbuf);
    msg.msg_control = cmsgbuf;
    msg.msg_controllen = sizeof cmsgbuf;

    ssize_t n = recvmsg(sock, &msg, 0);
    if (n < 0)
        return -errno;
    if (n == 0)
        return -ECONNRESET; // EOF before any hello: the helper died first
    if ((size_t)n != sizeof hdr || (msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC))) {
        close_received_fds(&msg);
        return -EBADMSG;
    }
    hdr.token[sizeof(hdr.token) - 1] = '\0';

    int fds[LTM_SHM_MAX_SEGMENTS];
    int nfds = 0;
    pid_t sender_pid = -1;
    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
        if (cmsg->cmsg_level != SOL_SOCKET)
            continue;
        if (cmsg->cmsg_type == SCM_RIGHTS) {
            size_t got = 0;
            if (cmsg->cmsg_len >= CMSG_LEN(0))
                got = (cmsg->cmsg_len - CMSG_LEN(0)) / sizeof(int);
            int *gotfds = (int *)CMSG_DATA(cmsg);
            for (size_t i = 0; i < got && nfds < LTM_SHM_MAX_SEGMENTS; i++)
                fds[nfds++] = gotfds[i];
        } else if (cmsg->cmsg_type == SCM_CREDENTIALS && cmsg->cmsg_len >= CMSG_LEN(sizeof(struct ucred))) {
            sender_pid = ((struct ucred *)CMSG_DATA(cmsg))->pid;
        }
    }

    int rc = -EBADMSG;
    if (hdr.nsegments != 1 && hdr.nsegments != LTM_SHM_MAX_SEGMENTS)
        goto fail;
    if (nfds != (int)hdr.nsegments)
        goto fail;
    if ((hdr.generation == 0) != (hdr.nsegments == 1))
        goto fail;
    if (strncmp(hdr.token, expected_token, sizeof(hdr.token)) != 0) {
        rc = -EACCES;
        goto fail;
    }
    if (hdr.protocol_version != expected_protocol) {
        rc = -EPROTOTYPE;
        goto fail;
    }
    if (passcred) {
        // The kernel promised the sender's credentials: a hello from any
        // other pid is a bug or an attack, not our helper.
        if (sender_pid < 0) {
            rc = -EBADMSG;
            goto fail;
        }
        if (sender_pid != expected_pid) {
            rc = -ESRCH;
            goto fail;
        }
    }
    // Without SO_PASSCRED the socket is still the private one made for this
    // spawn, so the token check above is the authentication.

    out->generation = hdr.generation;
    out->nsegments = nfds;
    memcpy(out->fds, fds, sizeof fds);
    memcpy(out->byte_counts, hdr.byte_counts, sizeof hdr.byte_counts);
    return 0;

fail:
    for (int i = 0; i < nfds; i++)
        if (fds[i] >= 0)
            close(fds[i]);
    return rc;
}

pid_t ltm_spawn(const char *path, char *const argv[], char *const envp[], int out_fd, int link_fd) {
    posix_spawn_file_actions_t fa;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&fa);
    posix_spawnattr_init(&attr);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    if (out_fd >= 0) {
        posix_spawn_file_actions_adddup2(&fa, out_fd, 1);
        posix_spawn_file_actions_adddup2(&fa, out_fd, 2);
    } else {
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    }
    if (link_fd >= 0)
        posix_spawn_file_actions_adddup2(&fa, link_fd, 3);
    // glibc has no POSIX_SPAWN_CLOEXEC_DEFAULT (the macOS build used it so
    // nothing but 0,1,2,3 was inherited). Emulate it: with the dup2s queued
    // above, closing every other fd in the child is equivalent. 0,1,2,3 are
    // never closed, so an out_fd or link_fd that already is 1, 2 or 3 survives.
    {
        DIR *dir = opendir("/proc/self/fd");
        if (dir) {
            int self = dirfd(dir);
            struct dirent *de;
            while ((de = readdir(dir)) != NULL) {
                char *end = NULL;
                long fd = strtol(de->d_name, &end, 10);
                if (!end || *end != '\0' || fd < 0 || fd > INT_MAX || (int)fd == self) continue;
                if (fd <= 3) continue;
                posix_spawn_file_actions_addclose(&fa, (int)fd);
            }
            closedir(dir);
        }
    }
    sigset_t all, none;
    sigfillset(&all);
    sigemptyset(&none);
    posix_spawnattr_setsigdefault(&attr, &all);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    pid_t pid = -1;
    int rc = posix_spawn(&pid, path, &fa, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    return rc ? -rc : pid;
}

uint64_t ltm_monotonic_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}
