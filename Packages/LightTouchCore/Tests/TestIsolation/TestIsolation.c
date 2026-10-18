// Every LightTouchCore test process gets a private home and app state before anything reads them: Bundled,
// logEvent, the IPA library and the caches resolve through LTM_STATE_DIR and the user's home, so a test that forgets
// to isolate itself still never touches the real library (~/Library/Application Support, Logs, Caches).
//
#ifdef _WIN32
// Windows: no <ftw.h>, no mkdtemp/setenv/PATH_MAX. Clang (which SwiftPM uses
// even on Windows) supports __attribute__((constructor)).
#define _CRT_SECURE_NO_WARNINGS // silence UCRT deprecation warnings (getenv, snprintf, ...)
#include <windows.h>
#include <direct.h>
#include <io.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "TestIsolation.h"

#ifndef PATH_MAX
#define PATH_MAX MAX_PATH
#endif

static char root[PATH_MAX];
static char home[PATH_MAX];

// setenv() emulation via _putenv (which copies the string).
static int win_setenv(const char *name, const char *value, int overwrite) {
    if (!overwrite && getenv(name))
        return 0;
    size_t n = strlen(name) + strlen(value) + 2;
    char *buf = (char *)malloc(n);
    if (!buf)
        return -1;
    snprintf(buf, n, "%s=%s", name, value);
    int r = _putenv(buf);
    free(buf);
    return r;
}

// mkdtemp() emulation: _mktemp_s is not declared by this toolchain's UCRT
// headers (it is gated behind __STDC_WANT_SECURE_LIB__, which SwiftPM does
// not define), so fill the trailing XXXXXX ourselves with a QPC/pid-seeded
// rand() and retry _mkdir on collision.
static char *win_mkdtemp(char *tmpl) {
    size_t len = strlen(tmpl);
    if (len < 6 || memcmp(tmpl + len - 6, "XXXXXX", 6) != 0)
        return NULL;
    static int seeded = 0;
    if (!seeded) {
        LARGE_INTEGER ctr;
        QueryPerformanceCounter(&ctr);
        srand((unsigned)(ctr.QuadPart ^
                         ((unsigned long long)(uintptr_t)&seeded << 32) ^
                         (unsigned long long)GetCurrentProcessId()));
        seeded = 1;
    }
    static const char alnum[] =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    for (int tries = 0; tries < 64; tries++) {
        for (int i = 0; i < 6; i++)
            tmpl[len - 6 + i] = alnum[(unsigned)rand() % (sizeof(alnum) - 1)];
        if (_mkdir(tmpl) == 0)
            return tmpl;
    }
    return NULL;
}

static void remove_recursive(const char *path) {
    char pattern[PATH_MAX];
    snprintf(pattern, sizeof pattern, "%s\\*", path);
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (strcmp(fd.cFileName, ".") == 0 || strcmp(fd.cFileName, "..") == 0)
                continue;
            char child[PATH_MAX];
            snprintf(child, sizeof child, "%s\\%s", path, fd.cFileName);
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                remove_recursive(child);
            } else {
                SetFileAttributesA(child, FILE_ATTRIBUTE_NORMAL);
                DeleteFileA(child);
            }
        } while (FindNextFileA(h, &fd));
        FindClose(h);
    }
    RemoveDirectoryA(path);
}

static void cleanup(void) {
    if (root[0])
        remove_recursive(root);
}

__attribute__((constructor)) static void isolate(void) {
    // DIAGNOSTIC (win/w-ltc-startup2): the test binary hangs with zero output.
    // Unbuffered markers bisect loader vs constructor vs post-constructor hang.
    // write(2) is a direct syscall: unbuffered even if the CRT isn't fully up.
    write(2, "[TestIsolation] constructor enter\n", 34);
    // Unbuffer stdout/stderr so the log shows exactly how far the runner got
    // (when stdout is a pipe the CRT block-buffers it and the hang location
    // never reaches the log).
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    // An exit test's child process (#expect(processExitsWith:)) inherits this environment and dies without atexit:
    // it uses its parent's root, which the parent removes.
    if (getenv("LTM_TEST_ROOT")) {
        const char *h = getenv("HOME");
        if (!h)
            h = getenv("USERPROFILE");
        if (h)
            snprintf(home, sizeof home, "%s", h);
        fprintf(stderr, "[TestIsolation] constructor exit (child)\n");
        return;
    }
    char tmp[PATH_MAX];
    DWORD len = GetTempPathA((DWORD)sizeof tmp, tmp);
    if (len == 0 || len >= sizeof tmp) {
        snprintf(tmp, sizeof tmp, "C:\\Temp\\");
    }
    snprintf(root, sizeof root, "%sltm-tests-XXXXXX", tmp);
    if (!win_mkdtemp(root)) {
        fprintf(stderr, "ltm tests: mkdtemp failed\n");
        abort();
    }
    char state[PATH_MAX], library[PATH_MAX];
    snprintf(home, sizeof home, "%s\\home", root);
    snprintf(library, sizeof library, "%s\\Library", home);
    snprintf(state, sizeof state, "%s\\state", root);
    if (_mkdir(home) != 0 || _mkdir(library) != 0) {
        fprintf(stderr, "ltm tests: mkdir failed\n");
        abort();
    }
    win_setenv("HOME", home, 1);
    win_setenv("LTM_STATE_DIR", state, 1);
    win_setenv("LTM_TEST_ROOT", root, 1);
    atexit(cleanup);
    fprintf(stderr, "[TestIsolation] constructor exit (root=%s)\n", root);
}

const char *ltm_test_home(void) { return home; }

#else // POSIX

// Linux: nftw() needs _XOPEN_SOURCE >= 700 declared before <ftw.h>.
#define _XOPEN_SOURCE 700
#include <ftw.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include "TestIsolation.h"

static char root[PATH_MAX];
static char home[PATH_MAX];

static int remove_entry(const char *path, const struct stat *sb, int flag, struct FTW *ftw) {
    (void)sb;
    (void)flag;
    (void)ftw;
    return remove(path);
}

static void cleanup(void) {
    if (root[0])
        nftw(root, remove_entry, 16, FTW_DEPTH | FTW_PHYS);
}

__attribute__((constructor)) static void isolate(void) {
    // An exit test's child process (#expect(processExitsWith:)) inherits this environment and dies without atexit:
    // it uses its parent's root, which the parent removes.
    if (getenv("LTM_TEST_ROOT")) {
        snprintf(home, sizeof home, "%s", getenv("HOME"));
        return;
    }
    const char *tmp = getenv("TMPDIR");
    snprintf(root, sizeof root, "%s/ltm-tests-XXXXXX", tmp && *tmp ? tmp : "/tmp");
    if (!mkdtemp(root)) {
        perror("ltm tests: mkdtemp");
        abort();
    }
    char state[PATH_MAX], library[PATH_MAX];
    snprintf(home, sizeof home, "%s/home", root);
    snprintf(library, sizeof library, "%s/Library", home);
    snprintf(state, sizeof state, "%s/state", root);
    if (mkdir(home, 0700) || mkdir(library, 0700)) {
        perror("ltm tests: mkdir");
        abort();
    }
    setenv("CFFIXED_USER_HOME", home, 1);
    setenv("HOME", home, 1);
    setenv("LTM_STATE_DIR", state, 1);
    setenv("LTM_TEST_ROOT", root, 1);
    atexit(cleanup);
}

const char *ltm_test_home(void) { return home; }

#endif // _WIN32
