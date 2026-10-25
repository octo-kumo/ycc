// src/web/abi.js — the web ABI, version 1, in one place.
//
// Everything here is part of the web ABI (docs/TARGETS.md):
//   S3   the module: imports, exports, the 512-byte context layout;
//   S7   code addresses ("tokens");
//   S8   yield reasons and exit statuses;
//   Appendix B  Linux structures and errno/open-flag values;
//   Appendix C  the private syscall range and the host-call boundary.
//
// A change to any of these numbers is an ABI bump: it must be made here, in
// the compiler's writer, and in the yweb section together (Appendix C).

export const ABI_VERSION = 1;

// ---------------------------------------------------------------------------
// S3: the context, 512 bytes, little-endian.
//
//   0..127   r0..r15
//   128..255 x0..x15 (the bits of the f64)
//   256      fs
//   264      pc
//   272      fop (i32)
//   280      fsz (i32)
//   288      fa
//   296      fb
//   304      fr
//   312      fx
//   320      fy
//   328      fcf (i32)
//   336..511 reserved, zero
// ---------------------------------------------------------------------------

export const CTX_SIZE = 512;

const ctxFields = {
  R0: 0, R1: 8, R2: 16, R3: 24,
  R4: 32, R5: 40, R6: 48, R7: 56,
  R8: 64, R9: 72, R10: 80, R11: 88,
  R12: 96, R13: 104, R14: 112, R15: 120,
  X0: 128, X1: 136, X2: 144, X3: 152,
  X4: 160, X5: 168, X6: 176, X7: 184,
  X8: 192, X9: 200, X10: 208, X11: 216,
  X12: 224, X13: 232, X14: 240, X15: 248,
  FS: 256,
  PC: 264,
  FOP: 272,
  FSZ: 280,
  FA: 288,
  FB: 296,
  FR: 304,
  FX: 312,
  FY: 320,
  FCF: 328,
  RESERVED: 336,
};
export const CTX = Object.freeze(ctxFields);

export const CTX_R = Object.freeze(Array.from({ length: 16 }, (_, i) => ctxFields['R' + i]));
export const CTX_X = Object.freeze(Array.from({ length: 16 }, (_, i) => ctxFields['X' + i]));

// x86-64 register aliases used by the initial stack builder and the runtime.
export const REG = Object.freeze({ RAX: 0, RCX: 1, RDX: 2, RBX: 3, RSP: 4, RBP: 5, RSI: 6, RDI: 7 });

// ---------------------------------------------------------------------------
// S8: why() values.
// ---------------------------------------------------------------------------

export const WHY = Object.freeze({
  NONE: 0,
  BLOCK: 1,
  PREEMPT: 2,
  EXIT: 3,
  THREAD_EXIT: 4,
  YIELD: 5,
});

// Linux signal numbers the compiler can name (S4/S8), and their shell status.
export const SIG = Object.freeze({
  SIGINT: 2,
  SIGILL: 4,
  SIGTRAP: 5,
  SIGFPE: 8,
  SIGKILL: 9,
  SIGSEGV: 11,
  SIGTERM: 15,
});

export const STATUS = Object.freeze({
  SIGILL: 132,
  SIGTRAP: 133,
  SIGFPE: 136,
  SIGSEGV: 139,
  HOST_ERROR: 134,
});

export function statusForSignal(sig) {
  return 128 + (Number(sig) & 0xff);
}

// ---------------------------------------------------------------------------
// S7: tokens.  token = 2^40 + (chunk << 20) + case
// The value fits a JS Number exactly (2^41 < 2^53) and travels as a BigInt
// through wasm's i64.
// ---------------------------------------------------------------------------

export const TOKEN_BASE = 2 ** 40;
export const TOKEN_CHUNK_SHIFT = 20;
export const TOKEN_CHUNK_MAX = 2 ** 20 - 1;
export const TOKEN_CASE_MAX = 2 ** 20 - 1;

export function encodeToken(chunk, kase) {
  if (!Number.isInteger(chunk) || chunk < 0 || chunk > TOKEN_CHUNK_MAX) {
    throw new RangeError(`chunk out of range for a token: ${chunk}`);
  }
  if (!Number.isInteger(kase) || kase < 0 || kase > TOKEN_CASE_MAX) {
    throw new RangeError(`case out of range for a token: ${kase}`);
  }
  return TOKEN_BASE + chunk * 2 ** TOKEN_CHUNK_SHIFT + kase;
}

// Returns {chunk, case} or null when the value is not a code token.
export function decodeToken(token) {
  let n;
  if (typeof token === 'bigint') {
    if (token < 0n) return null;
    n = token;
  } else {
    if (!Number.isSafeInteger(token) || token < 0) return null;
    n = BigInt(token);
  }
  if (n >> 40n !== 1n) return null;
  return {
    chunk: Number((n >> 20n) & 0xfffffn),
    case: Number(n & 0xfffffn),
  };
}

// ---------------------------------------------------------------------------
// Appendix B: errno values used by the host.
// ---------------------------------------------------------------------------

export const E = Object.freeze({
  EPERM: 1,
  ENOENT: 2,
  EINTR: 4,
  EIO: 5,
  ENXIO: 6,
  EBADF: 9,
  ECHILD: 10,
  EAGAIN: 11,
  ENOMEM: 12,
  EACCES: 13,
  EFAULT: 14,
  EEXIST: 17,
  ENODEV: 19,
  ENOTDIR: 20,
  EISDIR: 21,
  EINVAL: 22,
  EMFILE: 24,
  ENOTTY: 25,
  ENOSPC: 28,
  ESPIPE: 29,
  EROFS: 30,
  EPIPE: 32,
  ERANGE: 34,
  ENOSYS: 38,
  ENOTEMPTY: 39,
  ELOOP: 40,
  ENOTSOCK: 88,
  EAFNOSUPPORT: 97,
  ETIMEDOUT: 110,
});

// ---------------------------------------------------------------------------
// Appendix C: private syscall numbers ("Y", 0x5900, clear of Linux's range).
// ---------------------------------------------------------------------------

export const Y_WEB_BASE = 22784;
export const Y_SYS = Object.freeze({
  HOST_SYM: 22785,
  HOST_CALL: 22786,
  AUDIO_DEVS: 22787,
  AUDIO_OPEN: 22788,
  AUDIO_WRITE: 22789,
  AUDIO_CLOSE: 22790,
});

// ---------------------------------------------------------------------------
// x86-64 Linux syscall numbers (D4: the host answers Linux's numbering).
// The full S9 list is present so a reader can see what is still deferred;
// implemented ones are handled in yhost.js.
// ---------------------------------------------------------------------------

export const SYS = Object.freeze({
  read: 0,
  write: 1,
  open: 2,
  close: 3,
  stat: 4,
  fstat: 5,
  lstat: 6,
  poll: 7,
  select: 23,
  lseek: 8,
  mmap: 9,
  mprotect: 10,
  munmap: 11,
  brk: 12,
  rt_sigaction: 13,
  rt_sigprocmask: 14,
  ioctl: 16,
  pread64: 17,
  pwrite64: 18,
  readv: 19,
  writev: 20,
  access: 21,
  pipe: 22,
  sched_yield: 24,
  mremap: 25,
  msync: 26,
  madvise: 28,
  dup: 32,
  dup2: 33,
  nanosleep: 35,
  getpid: 39,
  socket: 41,
  connect: 42,
  accept: 43,
  sendto: 44,
  recvfrom: 45,
  sendmsg: 46,
  recvmsg: 47,
  shutdown: 48,
  bind: 49,
  listen: 50,
  getsockname: 51,
  getpeername: 52,
  socketpair: 53,
  setsockopt: 54,
  getsockopt: 55,
  clone: 56,
  fork: 57,
  vfork: 58,
  execve: 59,
  exit: 60,
  wait4: 61,
  kill: 62,
  uname: 63,
  fcntl: 72,
  flock: 73,
  fsync: 74,
  fdatasync: 75,
  truncate: 76,
  ftruncate: 77,
  getcwd: 79,
  chdir: 80,
  fchdir: 81,
  rename: 82,
  mkdir: 83,
  rmdir: 84,
  unlink: 87,
  symlink: 88,
  readlink: 89,
  chmod: 90,
  fchmod: 91,
  chown: 92,
  fchown: 93,
  lchown: 94,
  umask: 95,
  gettimeofday: 96,
  getrlimit: 97,
  getrusage: 98,
  sysinfo: 99,
  times: 100,
  ptrace: 101,
  getuid: 102,
  getgid: 104,
  geteuid: 107,
  getegid: 108,
  getppid: 110,
  getpgrp: 111,
  setsid: 112,
  sigaltstack: 131,
  mlock: 149,
  prctl: 157,
  arch_prctl: 158,
  setrlimit: 160,
  gettid: 186,
  time: 201,
  futex: 202,
  getdents64: 217,
  getdents: 78,
  set_tid_address: 218,
  clock_gettime: 228,
  clock_getres: 229,
  clock_nanosleep: 230,
  exit_group: 231,
  epoll_wait: 232,
  epoll_ctl: 233,
  tgkill: 234,
  tkill: 200,
  epoll_create: 213,
  timerfd_create: 283,
  eventfd: 284,
  timerfd_settime: 286,
  timerfd_gettime: 287,
  eventfd2: 290,
  epoll_create1: 291,
  inotify_init: 253,
  openat: 257,
  mkdirat: 258,
  fchownat: 260,
  newfstatat: 262,
  unlinkat: 263,
  renameat: 264,
  symlinkat: 266,
  readlinkat: 267,
  fchmodat: 268,
  faccessat: 269,
  pselect6: 270,
  ppoll: 271,
  set_robust_list: 273,
  get_robust_list: 274,
  epoll_pwait: 281,
  dup3: 292,
  pipe2: 293,
  inotify_init1: 294,
  accept4: 288,
  prlimit64: 302,
  renameat2: 316,
  getrandom: 318,
  memfd_create: 319,
  execveat: 322,
  statx: 332,
  clone3: 435,
});

// ---------------------------------------------------------------------------
// Appendix B: open flags and the auxiliary vector.
// ---------------------------------------------------------------------------

export const O = Object.freeze({
  RDONLY: 0,
  WRONLY: 1,
  RDWR: 2,
  CREAT: 0o100,
  EXCL: 0o200,
  TRUNC: 0o1000,
  APPEND: 0o2000,
  NONBLOCK: 0o4000,
  DIRECTORY: 0o200000,
  NOFOLLOW: 0o400000,
  CLOEXEC: 0o2000000,
});

export const AT = Object.freeze({
  FDCWD: -100,
  SYMLINK_NOFOLLOW: 0x100,
  REMOVEDIR: 0x200,
  EMPTY_PATH: 0x1000,
});

export const MAP = Object.freeze({
  SHARED: 0x01,
  PRIVATE: 0x02,
  FIXED: 0x10,
  ANONYMOUS: 0x20,
});

export const AT_PAGESZ = 6;
export const AT_RANDOM = 25;
export const AT_NULL = 0;
export const PAGE_SIZE = 4096;

// ---------------------------------------------------------------------------
// Appendix B: struct stat, 144 bytes on x86-64.
// ---------------------------------------------------------------------------

export const STAT = Object.freeze({
  DEV: 0,
  INO: 8,
  NLINK: 16,
  MODE: 24,
  UID: 28,
  GID: 32,
  RDEV: 40,
  SIZE: 48,
  BLKSIZE: 56,
  BLOCKS: 64,
  ATIME: 72,
  ATIME_NSEC: 80,
  MTIME: 88,
  MTIME_NSEC: 96,
  CTIME: 104,
  CTIME_NSEC: 112,
  RESERVED: 120,
  SIZE_BYTES: 144,
});

export const UTS_FIELD = 65;
export const UTS_SIZE = UTS_FIELD * 6;

// File type bits and the modes the synthetic vfs uses.
export const S_IFMT = 0o170000;
export const S_IFREG = 0o100000;
export const S_IFDIR = 0o040000;
export const S_IFCHR = 0o020000;
export const S_IFLNK = 0o120000;
export const S_IFIFO = 0o010000;

export const MAX_FDS = 1024;

// ---------------------------------------------------------------------------
// Context accessors.  A context is a Uint8Array/DataView of 512 bytes or an
// address in wasm memory (the caller passes the matching view).
// ---------------------------------------------------------------------------

function asView(ctx) {
  if (ctx instanceof DataView) return ctx;
  if (ArrayBuffer.isView(ctx)) return new DataView(ctx.buffer, ctx.byteOffset, ctx.byteLength);
  if (ctx instanceof ArrayBuffer) return new DataView(ctx);
  throw new TypeError('context must be an ArrayBuffer, a typed array or a DataView');
}

export function ctxGetU64(ctx, off) {
  return asView(ctx).getBigUint64(off, true);
}

export function ctxSetU64(ctx, off, value) {
  const v = typeof value === 'bigint' ? value : BigInt(value);
  asView(ctx).setBigUint64(off, BigInt.asUintN(64, v), true);
}

export function ctxGetU32(ctx, off) {
  return asView(ctx).getUint32(off, true);
}

export function ctxSetU32(ctx, off, value) {
  asView(ctx).setUint32(off, value >>> 0, true);
}

export function ctxGetRax(ctx) {
  return ctxGetU64(ctx, CTX.R0);
}

export function ctxSetRax(ctx, value) {
  ctxSetU64(ctx, CTX.R0, value);
}

export function ctxGetPc(ctx) {
  return ctxGetU64(ctx, CTX.PC);
}

export function ctxSetPc(ctx, value) {
  ctxSetU64(ctx, CTX.PC, value);
}

export function ctxGetFs(ctx) {
  return ctxGetU64(ctx, CTX.FS);
}

export function ctxSetFs(ctx, value) {
  ctxSetU64(ctx, CTX.FS, value);
}

export function ctxNew() {
  return new Uint8Array(CTX_SIZE);
}

// ---------------------------------------------------------------------------
// S9: the rest of the numbers the kernel needs (dirent, poll, clone, futex,
// eventfd/timerfd, rename flags, seek, clocks).  Appendix B fixes the layouts.
// ---------------------------------------------------------------------------

export const DT = Object.freeze({
  UNKNOWN: 0,
  FIFO: 1,
  CHR: 2,
  DIR: 4,
  BLK: 6,
  REG: 8,
  LNK: 10,
  SOCK: 12,
});

export const POLL = Object.freeze({
  IN: 0x001,
  PRI: 0x002,
  OUT: 0x004,
  ERR: 0x008,
  HUP: 0x010,
  NVAL: 0x020,
  RDNORM: 0x040,
  RDBAND: 0x080,
  WRNORM: 0x100,
  WRBAND: 0x200,
});

export const CLONE = Object.freeze({
  VM: 0x00000100,
  FS: 0x00000200,
  FILES: 0x00000400,
  SIGHAND: 0x00000800,
  PIDFD: 0x00001000,
  PTRACE: 0x00002000,
  VFORK: 0x00004000,
  PARENT: 0x00008000,
  THREAD: 0x00010000,
  NEWNS: 0x00020000,
  SYSVSEM: 0x00040000,
  SETTLS: 0x00080000,
  PARENT_SETTID: 0x00100000,
  CHILD_CLEARTID: 0x00200000,
  DETACHED: 0x00400000,
  UNTRACED: 0x00800000,
  CHILD_SETTID: 0x01000000,
  NEWCGROUP: 0x02000000,
  NEWUTS: 0x04000000,
  NEWIPC: 0x08000000,
  NEWUSER: 0x10000000,
  NEWPID: 0x20000000,
  NEWNET: 0x40000000,
  IO: 0x80000000,
});

// The flag set a Y spawn passes: a thread that shares the address space, the
// file table, the fs (cwd) and the signal handlers, with its tid written to
// the tcb and cleared on exit.
export const CLONE_THREAD_FLAGS =
  CLONE.VM | CLONE.FS | CLONE.FILES | CLONE.SIGHAND | CLONE.THREAD |
  CLONE.SYSVSEM | CLONE.SETTLS | CLONE.PARENT_SETTID | CLONE.CHILD_SETTID |
  CLONE.CHILD_CLEARTID;

export const FUTEX = Object.freeze({
  WAIT: 0,
  WAKE: 1,
  FD: 2,
  REQUEUE: 3,
  CMP_REQUEUE: 4,
  WAKE_OP: 5,
  LOCK_PI: 6,
  UNLOCK_PI: 7,
  TRYLOCK_PI: 8,
  WAIT_BITSET: 9,
  WAKE_BITSET: 10,
  WAIT_REQUEUE_PI: 11,
  CMP_REQUEUE_PI: 12,
  PRIVATE_FLAG: 128,
  CLOCK_REALTIME: 256,
  CMD_MASK: 0x7f,
});

export const EFD = Object.freeze({
  SEMAPHORE: 1,
  NONBLOCK: 0o4000,
  CLOEXEC: 0o2000000,
});

export const TFD = Object.freeze({
  NONBLOCK: 0o4000,
  CLOEXEC: 0o2000000,
  TIMER_ABSTIME: 0x1,
});

export const RENAME = Object.freeze({
  NOREPLACE: 0x1,
  EXCHANGE: 0x2,
  WHITEOUT: 0x4,
});

export const MFD = Object.freeze({
  CLOEXEC: 0x1,
  ALLOW_SEALING: 0x2,
  HUGETLB: 0x4,
});

export const SEEK = Object.freeze({ SET: 0, CUR: 1, END: 2, DATA: 3, HOLE: 4 });

export const CLOCK = Object.freeze({
  REALTIME: 0,
  MONOTONIC: 1,
  PROCESS_CPUTIME: 2,
  THREAD_CPUTIME: 3,
  MONOTONIC_RAW: 4,
  REALTIME_COARSE: 5,
  MONOTONIC_COARSE: 6,
  BOOTTIME: 7,
});

export const F = Object.freeze({
  DUPFD: 0,
  GETFD: 1,
  SETFD: 2,
  GETFL: 3,
  SETFL: 4,
  GETLK: 5,
  SETLK: 6,
  SETLKW: 7,
  DUPFD_CLOEXEC: 1030,
});

export const FD_CLOEXEC = 1;

// statx: the minimal field offsets and the basic-stats mask.
export const STATX = Object.freeze({
  MASK: 0,
  BLKSIZE: 4,
  ATTRIBUTES: 8,
  NLINK: 16,
  UID: 20,
  GID: 24,
  MODE: 28,
  INO: 32,
  SIZE: 40,
  BLOCKS: 48,
  ATTRIBUTES_MASK: 56,
  ATIME: 64,
  BTIME: 80,
  CTIME: 96,
  MTIME: 112,
  RDEV_MAJOR: 128,
  RDEV_MINOR: 132,
  DEV_MAJOR: 136,
  DEV_MINOR: 140,
  SIZE_BYTES: 256,
});

export const STATX_BASIC_STATS = 0x7ff;
