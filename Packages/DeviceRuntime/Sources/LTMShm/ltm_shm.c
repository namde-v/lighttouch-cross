#ifndef _WIN32
#define _GNU_SOURCE
#else
#define _CRT_SECURE_NO_WARNINGS // silence UCRT deprecation warnings (strncpy, ...)
#endif
#include "ltm_shm.h"

#ifdef _WIN32
// ================= Windows transport =================
// Named file mappings + loopback TCP socket. See ltm_shm.h.

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

uint64_t ltm_monotonic_ns(void); // defined below; used for the recv deadline

// The API uses int for sockets/fds; on 64-bit Windows SOCKET and HANDLE are
// 64-bit. Callers (the future Windows Swift wave) pass values that fit.
static SOCKET to_socket(int fd) { return (SOCKET)(uintptr_t)fd; }
static HANDLE to_handle(int fd) { return (HANDLE)(uintptr_t)fd; }
static int from_handle(HANDLE h) { return (int)(uintptr_t)h; }

// Map a Winsock error to an errno for the API's -errno convention.
static int wsa_to_errno(int wsa) {
    switch (wsa) {
    case WSAEWOULDBLOCK: return EAGAIN;
    case WSAETIMEDOUT: return ETIMEDOUT;
    case WSAECONNRESET:
    case WSAECONNABORTED:
    case WSAESHUTDOWN: return ECONNRESET;
    case WSAEACCES: return EACCES;
    case WSAEINVAL: return EINVAL;
    case WSAENOTSOCK: return EBADF;
    default: return EIO;
    }
}

// "LTMShm_<token>_<index>" — the token is NUL-terminated, max 63 chars.
// Exported (see ltm_shm.h) so Swift creation uses this same implementation.
void ltm_mapping_name(const char *token, int index, char *out, size_t outlen) {
    snprintf(out, outlen, "LTMShm_%s_%d", token, index);
}

int ltm_send_hello(int sock, const char *token, uint32_t protocol_version,
                   uint64_t generation, const int *fds, const uint64_t *byte_counts, int nsegments) {
    if (nsegments != 1 && nsegments != LTM_SHM_MAX_SEGMENTS)
        return -EINVAL;
    if (!byte_counts)
        return -EINVAL;
    (void)fds; // Windows: named mappings re-opened by name; nothing to pass.

    ltm_shm_hello_hdr hdr;
    memset(&hdr, 0, sizeof hdr);
    strncpy(hdr.token, token, sizeof(hdr.token) - 1);
    hdr.protocol_version = protocol_version;
    hdr.nsegments = (uint32_t)nsegments;
    hdr.generation = generation;
    for (int i = 0; i < nsegments; i++)
        hdr.byte_counts[i] = byte_counts[i];

    SOCKET s = to_socket(sock);
    const char *p = (const char *)&hdr;
    size_t left = sizeof hdr;
    while (left > 0) {
        int n = send(s, p, (int)left, 0);
        if (n == SOCKET_ERROR)
            return -wsa_to_errno(WSAGetLastError());
        p += n;
        left -= (size_t)n;
    }
    return 0;
}

int ltm_recv_hello(int sock, int timeout_ms, const char *expected_token,
                   uint32_t expected_protocol, pid_t expected_pid,
                   ltm_shm_hello *out) {
    (void)expected_pid; // No SCM_CREDENTIALS on Windows; the token authenticates.
    memset(out, 0, sizeof *out);
    for (int i = 0; i < LTM_SHM_MAX_SEGMENTS; i++)
        out->fds[i] = -1;

    SOCKET s = to_socket(sock);

    ltm_shm_hello_hdr hdr;
    char *p = (char *)&hdr;
    size_t left = sizeof hdr;
    // The caller's timeout is a total deadline for the whole header: select()
    // is re-armed around every recv so a helper that stalls mid-header cannot
    // hang us past it.
    uint64_t deadline_ns = 0;
    if (timeout_ms >= 0)
        deadline_ns = ltm_monotonic_ns() + (uint64_t)timeout_ms * 1000000ull;
    while (left > 0) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(s, &rfds);
        struct timeval tv, *tvp = NULL;
        if (timeout_ms >= 0) {
            uint64_t now = ltm_monotonic_ns();
            if (now >= deadline_ns)
                return -ETIMEDOUT;
            uint64_t remain_ms = (deadline_ns - now) / 1000000ull;
            tv.tv_sec = (long)(remain_ms / 1000);
            tv.tv_usec = (long)(remain_ms % 1000) * 1000L;
            tvp = &tv;
        }
        int pr = select(0, &rfds, NULL, NULL, tvp);
        if (pr == SOCKET_ERROR)
            return -wsa_to_errno(WSAGetLastError());
        if (pr == 0)
            return -ETIMEDOUT;
        int n = recv(s, p, (int)left, 0);
        if (n == SOCKET_ERROR)
            return -wsa_to_errno(WSAGetLastError());
        if (n == 0)
            return -ECONNRESET; // EOF before any hello: the helper died first
        p += n;
        left -= (size_t)n;
    }
    hdr.token[sizeof(hdr.token) - 1] = '\0';

    if (hdr.nsegments != 1 && hdr.nsegments != LTM_SHM_MAX_SEGMENTS)
        return -EBADMSG;
    if ((hdr.generation == 0) != (hdr.nsegments == 1))
        return -EBADMSG;
    if (strncmp(hdr.token, expected_token, sizeof(hdr.token)) != 0)
        return -EACCES;
    if (hdr.protocol_version != expected_protocol)
        return -EPROTOTYPE;

    // Re-open each named mapping. The helper created them before sending.
    int nfds = 0;
    for (uint32_t i = 0; i < hdr.nsegments; i++) {
        char name[128];
        ltm_mapping_name(hdr.token, (int)i, name, sizeof name);
        HANDLE h = OpenFileMappingA(FILE_MAP_ALL_ACCESS, FALSE, name);
        if (h == NULL) {
            for (int j = 0; j < nfds; j++)
                CloseHandle(to_handle(out->fds[j]));
            return -ENOENT;
        }
        out->fds[nfds++] = from_handle(h);
    }

    out->generation = hdr.generation;
    out->nsegments = nfds;
    memcpy(out->byte_counts, hdr.byte_counts, sizeof hdr.byte_counts);
    return 0;
}

// Quote one argv element for CreateProcess' command line.
static char *quote_arg(const char *a) {
    int need = 0;
    for (const char *p = a; *p; p++) {
        if (*p == ' ' || *p == '\t' || *p == '"' || *p == '\n')
            need = 1;
    }
    if (!need) {
        char *r = (char *)malloc(strlen(a) + 1);
        if (r)
            strcpy(r, a);
        return r;
    }
    size_t n = strlen(a);
    char *r = (char *)malloc(n * 2 + 3);
    if (!r)
        return NULL;
    char *d = r;
    *d++ = '"';
    for (const char *p = a; *p; p++) {
        if (*p == '"') {
            *d++ = '\\';
            *d++ = '"';
        } else if (*p == '\\') {
            // Count trailing backslashes before a quote or end.
            const char *q = p;
            while (*q == '\\')
                q++;
            if (*q == '"' || *q == '\0') {
                while (p < q) {
                    *d++ = '\\';
                    *d++ = '\\';
                    p++;
                }
                p--; // the for loop's p++ moves past the run
            } else {
                *d++ = '\\';
            }
        } else {
            *d++ = *p;
        }
    }
    *d++ = '"';
    *d = '\0';
    return r;
}

pid_t ltm_spawn(const char *path, char *const argv[], char *const envp[], int out_fd, int link_fd) {
    if (!path || !argv || !argv[0])
        return -EINVAL;

    // Command line from argv.
    size_t cmdlen = 1;
    int argc = 0;
    for (; argv[argc]; argc++)
        cmdlen += strlen(argv[argc]) * 2 + 4;
    char *cmd = (char *)malloc(cmdlen);
    if (!cmd)
        return -ENOMEM;
    cmd[0] = '\0';
    for (int i = 0; i < argc; i++) {
        char *q = quote_arg(argv[i]);
        if (!q) {
            free(cmd);
            return -ENOMEM;
        }
        if (i > 0)
            strcat(cmd, " ");
        strcat(cmd, q);
        free(q);
    }

    // Environment block: envp[] plus LTM_LINK_SOCKET=<handle value>.
    // The helper reads LTM_LINK_SOCKET to find the link socket.
    size_t envlen = 1; // final double NUL
    int envc = 0;
    if (envp) {
        for (; envp[envc]; envc++)
            envlen += strlen(envp[envc]) + 1;
    }
    char linkvar[64];
    int linkvar_len = 0;
    HANDLE link_handle = INVALID_HANDLE_VALUE;
    if (link_fd >= 0) {
        link_handle = to_handle(link_fd);
        linkvar_len = snprintf(linkvar, sizeof linkvar, "LTM_LINK_SOCKET=%llu",
                               (unsigned long long)(uintptr_t)link_handle);
        envlen += (size_t)linkvar_len + 1;
    }
    char *envblock = (char *)malloc(envlen);
    if (!envblock) {
        free(cmd);
        return -ENOMEM;
    }
    char *e = envblock;
    if (envp) {
        for (int i = 0; i < envc; i++) {
            size_t n = strlen(envp[i]) + 1;
            memcpy(e, envp[i], n);
            e += n;
        }
    }
    if (link_fd >= 0) {
        memcpy(e, linkvar, (size_t)linkvar_len + 1);
        e += linkvar_len + 1;
    }
    *e = '\0';

    // Inherit exactly the handles the child needs: the stdio handles and the
    // link socket. With PROC_THREAD_ATTRIBUTE_HANDLE_LIST present, ONLY the
    // listed handles are inherited — the NUL handle backing stdio must be in
    // the list too, or the child's std handles are invalid.
    HANDLE nul = CreateFileA("NUL", GENERIC_READ | GENERIC_WRITE,
                             FILE_SHARE_READ | FILE_SHARE_WRITE,
                             NULL, OPEN_EXISTING, 0, NULL);
    if (nul == INVALID_HANDLE_VALUE) {
        free(envblock);
        free(cmd);
        return -EIO;
    }
    HANDLE out_handle = out_fd >= 0 ? to_handle(out_fd) : nul;
    HANDLE inherit[3];
    int n_inherit = 0;
    inherit[n_inherit++] = nul;
    if (out_handle != nul)
        inherit[n_inherit++] = out_handle;
    if (link_fd >= 0 && link_handle != nul && link_handle != out_handle)
        inherit[n_inherit++] = link_handle;
    for (int i = 0; i < n_inherit; i++)
        SetHandleInformation(inherit[i], HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);

    STARTUPINFOEXA siex;
    ZeroMemory(&siex, sizeof siex);
    siex.StartupInfo.cb = sizeof siex;
    SIZE_T attrlen = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attrlen);
    siex.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attrlen);
    pid_t ret = -ENOMEM;
    int attr_ok = 0;
    if (!siex.lpAttributeList)
        goto out;
    if (!InitializeProcThreadAttributeList(siex.lpAttributeList, 1, 0, &attrlen))
        goto out;
    attr_ok = 1;
    if (n_inherit > 0) {
        if (!UpdateProcThreadAttribute(siex.lpAttributeList, 0,
                                       PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                       inherit, (SIZE_T)n_inherit * sizeof(HANDLE),
                                       NULL, NULL))
            goto out;
    }
    siex.StartupInfo.dwFlags |= STARTF_USESTDHANDLES;
    // stdin: NUL. stdout/stderr: out_fd or NUL.
    siex.StartupInfo.hStdInput = nul;
    siex.StartupInfo.hStdOutput = out_handle;
    siex.StartupInfo.hStdError = out_handle;

    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof pi);
    BOOL ok = CreateProcessA(path, cmd, NULL, NULL, TRUE,
                             EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW,
                             envblock, NULL, &siex.StartupInfo, &pi);
    if (!ok) {
        DWORD le = GetLastError();
        ret = (le == ERROR_FILE_NOT_FOUND || le == ERROR_PATH_NOT_FOUND) ? -ENOENT :
              (le == ERROR_ACCESS_DENIED) ? -EACCES : -EIO;
        goto out;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    ret = (pid_t)pi.dwProcessId;

out:
    CloseHandle(nul); // the parent's copy; the child holds its own
    if (attr_ok)
        DeleteProcThreadAttributeList(siex.lpAttributeList);
    free(siex.lpAttributeList);
    free(envblock);
    free(cmd);
    return ret;
}

uint64_t ltm_monotonic_ns(void) {
    LARGE_INTEGER freq, ctr;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&ctr);
    return (uint64_t)((ctr.QuadPart * 1000000000ull) / (uint64_t)freq.QuadPart);
}

#else // ================= POSIX =================

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

#endif // _WIN32
