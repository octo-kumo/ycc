// kconst -- the constants os/kernel modules share .
//
// A LEAF module (it imports nothing), so it is spliced before every module that
// imports it.  Program modules share one namespace and are spliced in import
// order, and a module in an import cycle cannot read another's `const`: put a
// constant two modules need HERE and write `kconst.NAME`.  Add, never change.

// fd kinds (open file description kinds; fdt routes on them)
const FILE = 1;
const DIR = 2;
const TTY = 3;
const PIPE_R = 4;
const PIPE_W = 5;
const SOCK = 6;
const DSP = 7;
const NULL = 8;
const FB = 9;
const INPUT = 10;

// Wait-channel spaces that are not fd kinds (fdt_chan(space, obj) as well).
const CH_POLL = 16;      // obj 0: anyone in poll/select; fdt.notify wakes it
const CH_FUTEX = 17;     // obj = the futex word's PHYSICAL address
const CH_CHILD = 18;     // obj = the parent's slot: a child changed state
const CH_SLEEP = 19;     // obj = slot; nanosleep uses a deadline instead
const CH_AUDIO = 20;     // obj 0: room in the AC97 ring (D)
const CH_ACCEPT = 21;    // obj = listening socket (E)

// Character devices (vfs node device numbers; vfs calls fdt_open_dev for them).
const DEV_TTY = 1;
const DEV_NULL = 2;
const DEV_ZERO = 3;
const DEV_DSP = 4;
const DEV_FB = 5;
const DEV_INPUT = 6;

// Open flags (Linux values).
const O_ACCMODE = 3;
const O_CREAT = 64;
const O_EXCL = 128;
const O_TRUNC = 512;
const O_APPEND = 1024;
const O_NONBLOCK = 2048;
const O_DIRECTORY = 65536;
const O_CLOEXEC = 524288;
const FD_CLOEXEC = 1;

// poll events
const POLLIN = 1;
const POLLPRI = 2;
const POLLOUT = 4;
const POLLERR = 8;
const POLLHUP = 16;
const POLLNVAL = 32;

const ENOSYS = 0 - 38;
const EBADF = 0 - 9;
const EAGAIN = 0 - 11;
const EPERM = 0 - 1;
const ENOENT = 0 - 2;
const ESRCH = 0 - 3;
const EINTR = 0 - 4;
const EIO = 0 - 5;
const ECHILD = 0 - 10;
const ENOMEM = 0 - 12;
const EFAULT = 0 - 14;
const EEXIST = 0 - 17;
const ENODEV = 0 - 19;
const ENOTDIR = 0 - 20;
const EISDIR = 0 - 21;
const EINVAL = 0 - 22;
const EMFILE = 0 - 24;
const ENOTTY = 0 - 25;
const ENOSPC = 0 - 28;
const ESPIPE = 0 - 29;
const EPIPE = 0 - 32;
const ERANGE = 0 - 34;
const ENAMETOOLONG = 0 - 36;
const ENOTEMPTY = 0 - 39;
const ENOTSOCK = 0 - 88;
const EAFNOSUPPORT = 0 - 97;
const EADDRINUSE = 0 - 98;
const ECONNREFUSED = 0 - 111;
const ENOTCONN = 0 - 107;
const ETIMEDOUT = 0 - 110;
const EOPNOTSUPP = 0 - 95;
const AT_FDCWD = 0 - 100;
