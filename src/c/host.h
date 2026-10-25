/* Host file/process compatibility for the generated C bootstrap. */
#ifndef Y_HOST_H
#define Y_HOST_H

#ifdef _WIN32

#include "ylong.h"
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
#include <stdio.h>
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

ylong syscall(ylong n, ...);
#define readlink y_host_readlink
ylong y_host_readlink(const char *path, char *buf, size_t n);
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
ylong wait_pid(ylong pid);
#endif /* Y_HOST_H */
