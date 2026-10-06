/* host.c — the Windows half of host.h (C-only, like yv.c). Empty elsewhere. */
#include "ylong.h"
#include "host.h"

#ifdef _WIN32

/* stdout in binary mode, once, before main. `-S` is an assembly listing whose
 * bytes must match the Linux build's, and a text-mode stdout turns every '\n'
 * into CRLF: the whole listing differed by one byte per line. stdin too, so a
 * redirected source is not translated; stderr so a diagnostic is '\n'. */
__attribute__((constructor)) static void y_host_binary_stdio(void) {
    (void)_setmode(_fileno(stdin), _O_BINARY);
    (void)_setmode(_fileno(stdout), _O_BINARY);
    (void)_setmode(_fileno(stderr), _O_BINARY);
}

/* The one syscall() the call sites spell. Variadic and switching on the LINUX
 * number, so `syscall(SYS_openat, ...)` reads identically on both hosts.
 *
 * Reading a pointer argument as `long` is what this ABIs' varargs allow (each
 * argument occupies one eight-byte slot on x86-64), and it is why the call
 * sites do not need a second spelling. */
ylong syscall(ylong n, ...) {
    va_list ap;
    ylong r = -1;
    va_start(ap, n);
    switch (n) {
    case SYS_getcwd: {
        char *buf = va_arg(ap, char *);
        ylong size = va_arg(ap, ylong);
        if (_getcwd(buf, (int)size) != NULL) { r = (ylong)(intptr_t)buf; }
        break;
    }
    case SYS_openat: {
        ylong dfd = va_arg(ap, ylong);
        const char *path = va_arg(ap, const char *);
        ylong flags = va_arg(ap, ylong);
        ylong mode = va_arg(ap, ylong);
        (void)dfd;
        (void)mode;
        if ((flags & O_DIRECTORY) != 0) {
            DWORD a = GetFileAttributesA(path);
            r = (a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY) != 0)
                    ? Y_HOST_DIRFD : -1;
        } else {
            int fd = _open(path, _O_RDONLY | _O_BINARY);
            r = (fd < 0) ? -1 : (ylong)fd;
        }
        break;
    }
    case SYS_read: {
        ylong fd = va_arg(ap, ylong);
        void *buf = va_arg(ap, void *);
        ylong count = va_arg(ap, ylong);
        r = (ylong)_read((int)fd, buf, (unsigned)count);
        break;
    }
    case SYS_close: {
        ylong fd = va_arg(ap, ylong);
        r = (fd == Y_HOST_DIRFD) ? 0 : (ylong)_close((int)fd);
        break;
    }
    case SYS_mkdir: {
        const char *path = va_arg(ap, const char *);
        (void)va_arg(ap, ylong); /* the mode, which Windows spells with one bit */
        r = (ylong)_mkdir(path);
        break;
    }
    case SYS_readlink: {
        const char *path = va_arg(ap, const char *);
        char *buf = va_arg(ap, char *);
        ylong size = va_arg(ap, ylong);
        r = y_host_readlink(path, buf, (size_t)size);
        break;
    }
    case SYS_exit: {
        ylong code = va_arg(ap, ylong);
        _exit((int)code);
        break;
    }
    default:
        /* fork, clone, execve, pipe, dup, fcntl, mmap, mprotect, munmap,
         * memfd_create, ftruncate, write: the meta pass and `ycc build`'s git
         * fetch need these, and they have no one-line Windows answer. ENOSYS
         * is the honest failure; the callers report it. */
        errno = ENOSYS;
        r = -1;
        break;
    }
    va_end(ap);
    return r;
}

/* /proc/self/exe's answer. The loader's own file name is absolute and
 * resolved, which is exactly what the callers want from it. */
ylong y_host_readlink(const char *path, char *buf, size_t n) {
    if (strcmp(path, "/proc/self/exe") != 0) {
        errno = ENOENT;
        return -1;
    }
    DWORD got = GetModuleFileNameA(NULL, buf, (DWORD)n);
    if (got == 0 || (size_t)got >= n) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return (ylong)got;
}

/* clock_us() and ycc's timing want a monotonic clock. QueryPerformanceCounter
 * is the Windows one; the frequency is fixed for the process and is converted
 * to nanoseconds here so yv.c's arithmetic is the same on both hosts. */
int y_host_clock_gettime(int clk, struct timespec *ts) {
    LARGE_INTEGER c;
    (void)clk;
    if (!QueryPerformanceCounter(&c)) {
        errno = EINVAL;
        return -1;
    }
    ts->tv_sec = (ylong)(c.QuadPart / 10000000LL);
    ts->tv_nsec = (ylong)((c.QuadPart % 10000000LL) * 100LL);
    return 0;
}

int y_host_nanosleep(const struct timespec *req, struct timespec *rem) {
    ylong ms;
    (void)rem;
    if (req == NULL) {
        errno = EINVAL;
        return -1;
    }
    ms = req->tv_sec * 1000 + req->tv_nsec / 1000000;
    if (ms < 0) { ms = 0; }
    Sleep((DWORD)ms);
    return 0;
}

#endif /* _WIN32 */
