/* host.h — the host-side portability shim for the C copy (C-only, like yv.h).
 *
 * src/c is an ordinary glibc program on Linux: it reads and writes files
 * through stdio and reaches the kernel directly only for the handful of host
 * facts the compiler needs — the working directory, its own path, and (for
 * `ycc build` and meta blocks) process creation. W1 (`cycc.exe`, ideas/
 * WINDOWS.md) needs those few calls on Windows without a second copy of the
 * compiler, so §5's rule holds: the C source stays one source, and this header
 * is the only place a host difference lives.
 *
 * On every host that is not Windows this header is exactly the system headers
 * the four files used to include, so the Linux build and every byte it emits
 * are unchanged.
 *
 * On Windows the `syscall()` numbers are still the LINUX ones the call sites
 * already spell (`SYS_getcwd` and friends, and meta.c's `MG_SYS_*`, which have
 * the same values), so not one call site changes: `syscall()` below switches on
 * the number. The calls with no Windows answer yet (fork, clone, execve, pipe,
 * memfd_create, mmap) return -1/ENOSYS, which is the honest failure for a
 * feature that is not ported — the meta pass and `ycc build`'s git fetch report
 * it rather than crash. What is implemented is what compiling one file needs.
 */
#ifndef Y_HOST_H
#define Y_HOST_H

#ifdef _WIN32

#include <windows.h>
#include <io.h>
#include <direct.h>
#include <process.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <time.h>
#include <errno.h>
#include <stdarg.h>
#include <stddef.h>
#include <string.h>

/* The Linux numbers, so the call sites do not change. */
#define SYS_read 0L
#define SYS_write 1L
#define SYS_close 3L
#define SYS_mmap 9L
#define SYS_mprotect 10L
#define SYS_munmap 11L
#define SYS_pipe 22L
#define SYS_dup 32L
#define SYS_dup2 33L
#define SYS_fork 57L
#define SYS_execve 59L
#define SYS_exit 60L
#define SYS_wait4 61L
#define SYS_fcntl 72L
#define SYS_ftruncate 77L
#define SYS_getcwd 79L
#define SYS_mkdir 83L
#define SYS_readlink 89L
#define SYS_openat 257L
#define SYS_dup3 292L
#define SYS_memfd_create 319L

#ifndef AT_FDCWD
#define AT_FDCWD (-100)
#endif
#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif
#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

/* The a-dir-fd `openat` hands back: a real file gets an `_open` descriptor,
 * and a directory gets this sentinel, because Windows cannot `_open` one and
 * the only thing the caller does with it is `close` it. */
#define Y_HOST_DIRFD 0x40000000L

long syscall(long n, ...);
#define readlink y_host_readlink
long y_host_readlink(const char *path, char *buf, size_t n);
#define clock_gettime y_host_clock_gettime
int y_host_clock_gettime(int clk, struct timespec *ts);
#define nanosleep y_host_nanosleep
int y_host_nanosleep(const struct timespec *req, struct timespec *rem);
#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 1
#endif

#else /* !_WIN32 */

#include <sys/syscall.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

#endif /* _WIN32 */
#endif /* Y_HOST_H */
