// src/web/vfs.js — the VFS for the web target.
//
// One fd table is shared by every green thread of the process.  A descriptor
// names an open file description (OFD); dup shares the OFD, so the position,
// the status flags and a pipe's buffered bytes are shared exactly as Linux
// shares them.  What lives here:
//
//   * the real file system under '/' through this.fs.*Sync, cwd/chdir,
//   * synthetic /proc (self/environ, cmdline, status, comm, statm, maps, exe,
//     cwd, fd/N) and /dev (null, zero, urandom, random, tty, fd/*),
//   * regular files, directories (getdents64), memfd, pipes, eventfd, timerfd,
//   * stat/lstat/fstat/statx, access, readlink, and the mutating path calls,
//   * poll readiness and the data the blocking layer in yhost.js needs.
//
// A blocking read or write is not performed here: read() answers
// {block: {...}} and yhost.js parks the thread on that object until a later
// operation (a write, a close, a timer) wakes it and the read is retried.
// Nothing is faked: a call that cannot be answered returns -errno.

import {
  AT, DT, E, F, MAX_FDS, O, PAGE_SIZE, POLL, SEEK,
  S_IFCHR, S_IFDIR, S_IFIFO, S_IFLNK, S_IFMT, S_IFREG,
} from './abi.js';
import { U8, randomBytes } from './bytes.js';
import { MemFs } from './memfs.js';

const UTF8 = new TextEncoder();

export function encode(s) {
  return UTF8.encode(String(s));
}

export function decode(bytes) {
  return new TextDecoder().decode(bytes);
}

export function basename(path) {
  const p = normalizePath('/', path);
  const i = p.lastIndexOf('/');
  return i === 0 ? p.slice(1) : p.slice(i + 1);
}

// Linux path resolution: an absolute path always has one leading '/', '.'
// components vanish and '..' cannot climb above the root.
export function normalizePath(cwd, path) {
  const p = String(path == null || path === '' ? '.' : path);
  if (p.includes('\0')) throw new Error('path contains NUL');
  const start = p.startsWith('/') ? p : `${normalizePath('/', cwd)}/${p}`;
  const out = [];
  for (const part of start.split('/')) {
    if (part === '' || part === '.') continue;
    if (part === '..') {
      out.pop();
      continue;
    }
    out.push(part);
  }
  return '/' + out.join('/');
}

// Node fs errors carry the negated errno; anything else is EIO.
export function nodeErrno(err) {
  if (err && typeof err.errno === 'number' && err.errno !== 0) {
    return err.errno < 0 ? err.errno : -err.errno;
  }
  const byCode = {
    EPERM: E.EPERM, ENOENT: E.ENOENT, EINTR: E.EINTR, EIO: E.EIO,
    ENXIO: E.ENXIO, EBADF: E.EBADF, EAGAIN: E.EAGAIN, ENOMEM: E.ENOMEM,
    EACCES: E.EACCES, EFAULT: E.EFAULT, EEXIST: E.EEXIST, ENODEV: E.ENODEV,
    ENOTDIR: E.ENOTDIR, EISDIR: E.EISDIR, EINVAL: E.EINVAL, EMFILE: E.EMFILE,
    ENOTTY: E.ENOTTY, ESPIPE: E.ESPIPE, EPIPE: E.EPIPE, ERANGE: E.ERANGE,
    ENOSYS: E.ENOSYS, ENOTEMPTY: E.ENOTEMPTY, ELOOP: E.ELOOP,
    ETIMEDOUT: E.ETIMEDOUT,
  };
  return byCode[err && err.code] !== undefined ? -byCode[err.code] : -E.EIO;
}

function pause1ms() {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
}

function statObj(fields) {
  return {
    dev: 0, ino: 1, nlink: 1, mode: S_IFREG | 0o644, uid: 1000, gid: 1000,
    rdev: 0, size: 0, blksize: PAGE_SIZE, blocks: 0,
    atimeMs: 0, mtimeMs: 0, ctimeMs: 0, ...fields,
  };
}

function fromNodeStats(st) {
  return statObj({
    dev: Number(st.dev), ino: Number(st.ino), nlink: Number(st.nlink),
    mode: st.mode, uid: st.uid, gid: st.gid, rdev: Number(st.rdev),
    size: Number(st.size), blksize: Number(st.blksize) || PAGE_SIZE,
    blocks: Number(st.blocks) || 0,
    atimeMs: st.atimeMs, mtimeMs: st.mtimeMs, ctimeMs: st.ctimeMs,
  });
}

function hashIno(name, salt = 0) {
  let h = 2166136261 ^ salt;
  for (let i = 0; i < name.length; i++) {
    h ^= name.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0) + 1;
}

// ---------------------------------------------------------------------------
// Open file descriptions and the objects behind them.
// ---------------------------------------------------------------------------

let nextIno = 1;

class OpenFile {
  constructor(kind, fields = {}) {
    this.kind = kind;
    Object.assign(this, fields);
    this.pos = 0;
    this.flags = 0;
    this.ino = nextIno++;
  }
}

export class Pipe {
  constructor() {
    this.capacity = 65536;
    this.chunks = [];
    this.len = 0;
    this.readers = 0;
    this.writers = 0;
    this.ino = nextIno++;
  }

  write(data) {
    const room = this.capacity - this.len;
    const n = Math.min(data.length, room);
    if (n <= 0) return 0;
    this.chunks.push(U8.from(data.subarray(0, n)));
    this.len += n;
    return n;
  }

  read(n) {
    const out = U8.alloc(Math.min(n, this.len));
    let got = 0;
    while (got < out.length && this.chunks.length) {
      const head = this.chunks[0];
      const take = Math.min(head.length, out.length - got);
      head.copy(out, got, 0, take);
      got += take;
      if (take === head.length) this.chunks.shift();
      else this.chunks[0] = head.subarray(take);
    }
    this.len -= got;
    return out;
  }

  readable() {
    return this.len > 0 || this.writers === 0;
  }

  writable() {
    return this.readers === 0 || this.len < this.capacity;
  }
}

class EventFd {
  constructor(initval, semaphore) {
    this.count = BigInt.asUintN(64, BigInt(initval));
    this.semaphore = !!semaphore;
    this.ino = nextIno++;
  }
}

class TimerFd {
  constructor(clockid) {
    this.clockid = clockid;
    this.next = Infinity;      // absolute monotonic milliseconds
    this.interval = 0;         // milliseconds, 0 = one-shot
    this.expirations = 0;
    this.ino = nextIno++;
  }

  due(now) {
    if (this.next === Infinity) return 0;
    if (now < this.next) return this.expirations;
    if (this.interval > 0) {
      return this.expirations + 1 + Math.floor((now - this.next) / this.interval);
    }
    return this.expirations + 1;
  }

  consume(now) {
    const n = this.due(now);
    if (n <= 0) return 0;
    if (this.interval > 0) {
      const first = this.next + Math.floor(Math.max(0, now - this.next) / this.interval) * this.interval;
      this.next = first + this.interval;
      this.expirations = 0;
    } else {
      this.next = Infinity;
      this.expirations = 0;
    }
    return n;
  }
}

function inoOf(path) {
  return hashIno(path);
}

// ---------------------------------------------------------------------------
// The VFS.
// ---------------------------------------------------------------------------

export class Vfs {
  constructor(opts = {}) {
    this.fs = opts.fs || new MemFs(opts.memfs || {});
    this.store = opts.store || null;
    if (this.store && this.fs instanceof MemFs && !this.fs.store) this.fs.store = this.store;
    this.pid = opts.pid || 0;
    this.random = opts.random || randomBytes;
    this.cwd = opts.cwd ? normalizePath('/', opts.cwd) : '/';
    this.argv = Array.isArray(opts.argv) ? [...opts.argv] : [];
    this.env = Array.isArray(opts.env) ? [...opts.env] : [];
    this.name = opts.name || (this.argv[0] ? basename(this.argv[0]) : 'a.out');
    this.exePath = opts.exePath || this.argv[0] || '/app/' + this.name;
    this.stdout = opts.stdout || ((b) => { let o = 0; while (o < b.length) o += this.fs.writeSync(1, b, o, b.length - o); });
    this.stderr = opts.stderr || ((b) => { let o = 0; while (o < b.length) o += this.fs.writeSync(2, b, o, b.length - o); });
    this.stdin = opts.stdin || null;
    this.memoryPages = opts.memoryPages || (() => 0);
    this.mapsFn = opts.maps || null;
    this.threadsFn = opts.threads || null;
    this.nowFn = opts.now || (() => performance.now());
    this.umask = 0o022;
    this.nextFd = 3;
    this.fds = new Map();
    this.modes = new Map();      // chmod shadow: path -> permission bits
    this.owners = new Map();     // chown shadow: path -> {uid, gid}
    const stdinOfd = new OpenFile('stdin', { path: '/dev/stdin' });
    const stdoutOfd = new OpenFile('stdout', { path: '/dev/stdout' });
    const stderrOfd = new OpenFile('stderr', { path: '/dev/stderr' });
    this.fds.set(0, { ofd: stdinOfd, cloexec: false });
    this.fds.set(1, { ofd: stdoutOfd, cloexec: false });
    this.fds.set(2, { ofd: stderrOfd, cloexec: false });
  }

  now() {
    return this.nowFn();
  }

  getcwd() {
    return this.cwd;
  }

  resolve(path) {
    return normalizePath(this.cwd, typeof path === 'string' ? path : '');
  }

  // -- descriptors ----------------------------------------------------------

  get(fd) {
    return this.fds.get(fd) || null;
  }

  lowestFree(min = 3) {
    let fd = Math.max(3, min | 0);
    while (this.fds.has(fd)) fd++;
    return fd;
  }

  install(ofd, fd, cloexec = false) {
    if (fd === undefined || fd === null) {
      if (this.fds.size >= MAX_FDS) return -E.EMFILE;
      fd = this.lowestFree(3);
    }
    this.fds.set(fd, { ofd, cloexec: !!cloexec });
    ofd.refs = (ofd.refs || 0) + 1;
    return fd;
  }

  close(fd) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    this.fds.delete(fd);
    const ofd = e.ofd;
    ofd.refs = Math.max(0, (ofd.refs || 1) - 1);
    if (ofd.kind === 'pipe') {
      if (ofd.end === 'r') ofd.pipe.readers--;
      else ofd.pipe.writers--;
    }
    if (ofd.refs === 0) {
      if ((ofd.kind === 'file' || ofd.kind === 'dir') && ofd.fd !== undefined) {
        try {
          this.fs.closeSync(ofd.fd);
        } catch (err) {
          return nodeErrno(err);
        }
      }
    }
    return 0;
  }

  dup(fd, min = 3, cloexec = false) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    const at = this.lowestFree(min);
    if (at >= MAX_FDS) return -E.EMFILE;
    this.fds.set(at, { ofd: e.ofd, cloexec: !!cloexec });
    e.ofd.refs = (e.ofd.refs || 0) + 1;
    this._refOfd(e.ofd);
    return at;
  }

  // A dup is another reference to the same description; a pipe counts its
  // ends by descriptor, so every dup/close moves the count.
  _refOfd(ofd) {
    if (ofd.kind === 'pipe') {
      if (ofd.end === 'r') ofd.pipe.readers++;
      else ofd.pipe.writers++;
    }
  }

  dup2(oldfd, newfd, cloexec = false) {
    const e = this.fds.get(oldfd);
    if (!e) return -E.EBADF;
    if (oldfd === newfd) return newfd;
    if (newfd < 0 || newfd >= MAX_FDS) return -E.EBADF;
    this.close(newfd);
    this.fds.set(newfd, { ofd: e.ofd, cloexec: !!cloexec });
    e.ofd.refs = (e.ofd.refs || 0) + 1;
    this._refOfd(e.ofd);
    return newfd;
  }

  // -- synthetic /proc and /dev --------------------------------------------

  _procKey(abs) {
    const m = /^\/proc\/(self|1|0)\/(.+)$/.exec(abs);
    if (!m) return null;
    if (m[1] === '0' && m[2] !== 'comm') return null;
    return m[2];
  }

  _procContent(key) {
    switch (key) {
      case 'environ':
        return this.env.map((s) => s + '\0').join('');
      case 'cmdline':
        return this.argv.map((s) => s + '\0').join('');
      case 'status':
        return this.procStatus();
      case 'comm':
        return (this.name || 'yhost') + '\n';
      case 'statm': {
        // size, resident, shared, text, lib, data, dt. The resident figure is
        // the linear memory in pages, which is what memstat.rss_kb reads.
        const pages = this.memoryPages();
        return `${pages} ${pages} 0 0 0 0 0\n`;
      }
      case 'maps':
        return this.procMaps();
      default:
        return null;
    }
  }

  procStatus() {
    const pages = this.memoryPages();
    const kb = pages * 4;
    const name = (this.name || 'a.out').slice(0, 15);
    return (
      `Name:\t${name}\n` +
      'Umask:\t0022\n' +
      'State:\tR (running)\n' +
      'Tgid:\t1\n' +
      'Ngid:\t0\n' +
      'Pid:\t1\n' +
      'PPid:\t0\n' +
      'TracerPid:\t0\n' +
      'Uid:\t1000\t1000\t1000\t1000\n' +
      'Gid:\t1000\t1000\t1000\t1000\n' +
      'FDSize:\t1024\n' +
      'Groups:\t1000\n' +
      `VmPeak:\t${kb} kB\n` +
      `VmSize:\t${kb} kB\n` +
      'VmLck:\t0 kB\n' +
      'VmPin:\t0 kB\n' +
      `VmHWM:\t${kb} kB\n` +
      `VmRSS:\t${kb} kB\n` +
      `RssAnon:\t${kb} kB\n` +
      'RssFile:\t0 kB\n' +
      'RssShmem:\t0 kB\n' +
      `VmData:\t${kb} kB\n` +
      'VmStk:\t128 kB\n' +
      `VmExe:\t${Math.max(1, Math.floor(this.memoryPages() / 8))} kB\n` +
      'VmLib:\t0 kB\n' +
      'VmPTE:\t0 kB\n' +
      `Threads:\t${this.threadsFn ? this.threadsFn() : 1}\n`
    );
  }

  procMaps() {
    let ranges = [];
    if (this.mapsFn) {
      try {
        ranges = this.mapsFn() || [];
      } catch (e) {
        ranges = [];
      }
    }
    if (ranges.length === 0) {
      ranges = [
        { start: 0, end: 65536, perms: 'rw-p', name: '[stack]' },
        { start: 65536, end: 131072, perms: 'r--p', name: this.exePath },
        { start: 131072, end: 262144, perms: 'rw-p', name: '[heap]' },
      ];
    }
    ranges.sort((a, b) => a.start - b.start);
    let out = '';
    for (const r of ranges) {
      const start = (r.start >>> 0).toString(16).padStart(8, '0');
      const end = (r.end >>> 0).toString(16).padStart(8, '0');
      out += `${start}-${end} ${r.perms || 'rw-p'} 00000000 00:00 0 ${r.name || ''}\n`;
    }
    return out;
  }

  // Description of a descriptor for /proc/self/fd/N.
  fdLink(fd) {
    const e = this.fds.get(fd);
    if (!e) return null;
    const ofd = e.ofd;
    switch (ofd.kind) {
      case 'file':
      case 'dir':
        return ofd.path;
      case 'mem':
        return ofd.path || '/memfd';
      case 'memfd':
        return 'memfd:' + (ofd.name || 'memfd');
      case 'pipe':
        return 'pipe:[' + ofd.pipe.ino + ']';
      case 'eventfd':
        return 'anon_inode:[eventfd]';
      case 'timerfd':
        return 'anon_inode:[timerfd]';
      case 'dev':
        return ofd.path;
      case 'stdin':
      case 'stdout':
      case 'stderr':
        return ofd.path;
      default:
        return 'anon_inode:[' + ofd.kind + ']';
    }
  }

  _synth(abs) {
    if (abs === '/proc') return { kind: 'dir', mode: S_IFDIR | 0o555, which: 'proc' };
    if (abs === '/proc/self' || abs === '/proc/1' || abs === '/proc/0') {
      return { kind: 'dir', mode: S_IFDIR | 0o555, which: 'procpid', pid: abs === '/proc/0' ? 0 : 1 };
    }
    if (abs === '/proc/self/fd' || abs === '/proc/1/fd' || abs === '/dev/fd') {
      return { kind: 'dir', mode: S_IFDIR | 0o555, which: 'procfd' };
    }
    const fdm = /^\/proc\/(?:self|1)\/fd\/([0-9]+)$/.exec(abs);
    if (fdm) {
      const fd = Number(fdm[1]);
      if (!this.fds.has(fd)) return null;
      return { kind: 'fdlink', mode: S_IFLNK | 0o777, fd, target: this.fdLink(fd) };
    }
    if (abs === '/proc/0/comm') {
      return { kind: 'mem', mode: S_IFREG | 0o444, data: U8.from('yhost\n') };
    }
    const key = this._procKey(abs);
    if (key !== null) {
      if (key === 'exe') {
        return { kind: 'link', mode: S_IFLNK | 0o777, target: this.exePath };
      }
      if (key === 'cwd') {
        return { kind: 'link', mode: S_IFLNK | 0o777, target: this.cwd };
      }
      const data = this._procContent(key);
      if (data === null) return null;
      return { kind: 'mem', mode: S_IFREG | 0o444, data: U8.from(data) };
    }
    if (abs === '/dev') return { kind: 'dir', mode: S_IFDIR | 0o555, which: 'dev' };
    if (abs === '/dev/null') return { kind: 'dev', dev: 'null', mode: S_IFCHR | 0o666 };
    if (abs === '/dev/zero') return { kind: 'dev', dev: 'zero', mode: S_IFCHR | 0o666 };
    if (abs === '/dev/full') return { kind: 'dev', dev: 'full', mode: S_IFCHR | 0o666 };
    if (abs === '/dev/urandom' || abs === '/dev/random') {
      return { kind: 'dev', dev: 'urandom', mode: S_IFCHR | 0o666 };
    }
    if (abs === '/dev/tty') return { kind: 'dev', dev: 'tty', mode: S_IFCHR | 0o666 };
    if (abs === '/dev/stdin' || abs === '/dev/stdout' || abs === '/dev/stderr') {
      const fd = abs === '/dev/stdin' ? 0 : abs === '/dev/stdout' ? 1 : 2;
      return { kind: 'fdlink', mode: S_IFLNK | 0o777, fd, target: this.fdLink(fd) };
    }
    return null;
  }

  _isSyntheticMount(abs) {
    return abs === '/proc' || abs.startsWith('/proc/') || abs === '/dev' || abs.startsWith('/dev/');
  }

  // Names in a synthetic directory.
  _synthEntries(abs) {
    if (abs === '/proc') return ['self', '1', '0'];
    if (abs === '/proc/0') return ['comm'];
    if (/^\/proc\/(?:self|1)$/.test(abs)) {
      return ['environ', 'cmdline', 'status', 'comm', 'statm', 'maps', 'exe', 'cwd', 'fd'];
    }
    if (abs === '/proc/self/fd' || abs === '/proc/1/fd' || abs === '/dev/fd') {
      return [...this.fds.keys()].sort((a, b) => a - b).map(String);
    }
    if (abs === '/dev') return ['null', 'zero', 'full', 'urandom', 'random', 'tty', 'fd', 'stdin', 'stdout', 'stderr'];
    return [];
  }

  // -- open -----------------------------------------------------------------

  open(path, flags, mode = 0o666) {
    const abs = this.resolve(path);
    const acc = flags & 3;
    const wantCreate = (flags & O.CREAT) !== 0;
    const wantTrunc = (flags & O.TRUNC) !== 0;
    const wantDir = (flags & O.DIRECTORY) !== 0;
    const noFollow = (flags & O.NOFOLLOW) !== 0;
    const synth = this._synth(abs);

    if (synth) {
      const cloexec = (flags & O.CLOEXEC) !== 0;
      if (synth.kind === 'dir') {
        if (acc !== O.RDONLY || wantCreate || wantTrunc) return -E.EISDIR;
        const ofd = new OpenFile('dir', { path: abs, synth: synth.which || null, entries: null, index: 0 });
        ofd.flags = flags & (O.NONBLOCK | O.APPEND);
        return this.install(ofd, undefined, cloexec);
      }
      if (wantDir) return -E.ENOTDIR;
      if (synth.kind === 'link') {
        if (noFollow) return -E.ELOOP;
        return this.open(synth.target, flags, mode);
      }
      if (synth.kind === 'fdlink') {
        if (synth.fd < 0 || !this.fds.has(synth.fd)) return -E.ENOENT;
        if (wantDir) return -E.ENOTDIR;
        const e = this.fds.get(synth.fd);
        return this.dup(synth.fd, 3, cloexec);
      }
      if (synth.kind === 'dev') {
        if (synth.dev === 'tty') return -E.ENXIO;
        // O_CREAT/O_TRUNC on an existing device are ignored, as on Linux;
        // /proc below is the one place that refuses them.
        if (synth.dev === 'full' && acc !== O.RDONLY) {
          const ofd = new OpenFile('dev', { dev: 'full', path: abs });
          ofd.flags = flags & O.NONBLOCK;
          return this.install(ofd, undefined, cloexec);
        }
        const ofd = new OpenFile('dev', { dev: synth.dev, path: abs });
        ofd.flags = flags & (O.NONBLOCK | O.APPEND);
        return this.install(ofd, undefined, cloexec);
      }
      // /proc files are read-only.
      if (acc !== O.RDONLY) return -E.EACCES;
      if (wantCreate || wantTrunc) return -E.EACCES;
      const ofd = new OpenFile('mem', { data: U8.from(synth.data), path: abs });
      ofd.flags = flags & O.NONBLOCK;
      return this.install(ofd, undefined, cloexec);
    }

    if (this._isSyntheticMount(abs) && wantCreate) return -E.EACCES;

    let nf = acc === O.RDONLY
      ? this.fs.constants.O_RDONLY
      : acc === O.WRONLY ? this.fs.constants.O_WRONLY : this.fs.constants.O_RDWR;
    if (wantCreate) nf |= this.fs.constants.O_CREAT;
    if (flags & O.EXCL) nf |= this.fs.constants.O_EXCL;
    if (wantTrunc) nf |= this.fs.constants.O_TRUNC;
    if (flags & O.APPEND) nf |= this.fs.constants.O_APPEND;
    if (flags & O.DIRECTORY) nf |= this.fs.constants.O_DIRECTORY;
    if (noFollow) nf |= this.fs.constants.O_NOFOLLOW;
    if ((flags & O.NONBLOCK) && this.fs.constants.O_NONBLOCK !== undefined) nf |= this.fs.constants.O_NONBLOCK;
    try {
      const fd = this.fs.openSync(abs, nf, mode & ~this.umask);
      const st = this.fs.fstatSync(fd);
      const isDir = (st.mode & S_IFMT) === S_IFDIR;
      const ofd = isDir
        ? new OpenFile('dir', { path: abs, synth: null, entries: null, index: 0 })
        : new OpenFile('file', { fd, path: abs });
      ofd.pos = 0;
      ofd.flags = flags & (O.NONBLOCK | O.APPEND);
      ofd.append = (flags & O.APPEND) !== 0;
      ofd.size = Number(st.size);
      if (isDir) ofd.fd = fd; // keep the descriptor until close
      return this.install(ofd, undefined, (flags & O.CLOEXEC) !== 0);
    } catch (err) {
      return nodeErrno(err);
    }
  }

  // -- directory listings ---------------------------------------------------

  _dirEntries(abs, synth) {
    const out = [{ name: '.', ino: inoOf(abs), type: DT.DIR, off: 0 },
      { name: '..', ino: inoOf(normalizePath('/', abs + '/..')), type: DT.DIR, off: 0 }];
    if (synth) {
      for (const name of this._synthEntries(abs)) {
        const child = normalizePath('/', abs + '/' + name);
        const s = this._synth(child);
        let type = DT.UNKNOWN;
        if (s) {
          if (s.kind === 'dir') type = DT.DIR;
          else if (s.kind === 'link' || s.kind === 'fdlink') type = DT.LNK;
          else if (s.kind === 'dev') type = DT.CHR;
          else type = DT.REG;
        }
        out.push({ name, ino: inoOf(child), type, off: 0 });
      }
      for (let i = 0; i < out.length; i++) out[i].off = i + 1;
      return out;
    }
    const dot = statObj({ ino: inoOf(abs), mode: S_IFDIR | 0o755, nlink: 2 });
    out[0].ino = dot.ino;
    try {
      const names = this.fs.readdirSync(abs, { withFileTypes: true });
      for (const d of names) {
        let type = DT.UNKNOWN;
        if (d.isDirectory()) type = DT.DIR;
        else if (d.isFile()) type = DT.REG;
        else if (d.isSymbolicLink()) type = DT.LNK;
        else if (d.isCharacterDevice()) type = DT.CHR;
        else if (d.isFIFO()) type = DT.FIFO;
        else if (d.isSocket()) type = DT.SOCK;
        else if (d.isBlockDevice()) type = DT.BLK;
        out.push({ name: d.name, ino: inoOf(abs + '/' + d.name), type, off: 0 });
      }
    } catch (err) {
      return nodeErrno(err);
    }
    for (let i = 0; i < out.length; i++) out[i].off = i + 1;
    return out;
  }

  getdents(fd, count) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    const ofd = e.ofd;
    if (ofd.kind !== 'dir') return -E.ENOTDIR;
    if (ofd.entries === null || ofd.entries === undefined) {
      const synth = this._synth(ofd.path);
      const entries = this._dirEntries(ofd.path, synth && synth.kind === 'dir' ? synth : null);
      if (typeof entries === 'number') return entries;
      ofd.entries = entries;
      if (ofd.index === undefined) ofd.index = 0;
    }
    const parts = [];
    let used = 0;
    while (ofd.index < ofd.entries.length) {
      const ent = ofd.entries[ofd.index];
      const nameBytes = encode(ent.name);
      const reclen = (19 + nameBytes.length + 1 + 7) & ~7;
      if (used + reclen > count) {
        if (parts.length === 0) return -E.EINVAL;
        break;
      }
      const rec = U8.alloc(reclen);
      rec.writeBigUInt64LE(BigInt(ent.ino), 0);
      rec.writeBigInt64LE(BigInt(ent.off), 8);
      rec.writeUInt16LE(reclen, 16);
      rec[18] = ent.type;
      nameBytes.forEach((b, i) => { rec[19 + i] = b; });
      parts.push(rec);
      used += reclen;
      ofd.index++;
    }
    return U8.concat(parts);
  }

  // -- reading and writing --------------------------------------------------

  read(fd, count) {
    const n = Math.max(0, count | 0);
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    const ofd = e.ofd;
    const nonblock = (ofd.flags & O.NONBLOCK) !== 0;
    if (n === 0) return { data: U8.alloc(0) };

    switch (ofd.kind) {
      case 'stdin': {
        if (this.stdin) {
          const r = this.stdin(n);
          if (typeof r === 'number') return r;
          if (r && r.block) return r;
          return { data: U8.from(r) };
        }
        const buf = U8.alloc(n);
        for (;;) {
          try {
            const got = this.fs.readSync(0, buf, 0, n, null);
            return { data: buf.subarray(0, got) };
          } catch (err) {
            const en = nodeErrno(err);
            if (en === -E.EAGAIN || en === -E.EINTR) {
              pause1ms();
              continue;
            }
            return en;
          }
        }
      }
      case 'stdout':
      case 'stderr':
        return -E.EBADF;
      case 'dir':
        return -E.EISDIR;
      case 'mem': {
        const got = Math.min(n, Math.max(0, ofd.data.length - ofd.pos));
        const out = U8.from(ofd.data.subarray(ofd.pos, ofd.pos + got));
        ofd.pos += got;
        return { data: out };
      }
      case 'memfd': {
        const got = Math.min(n, Math.max(0, ofd.data.length - ofd.pos));
        const out = U8.from(ofd.data.subarray(ofd.pos, ofd.pos + got));
        ofd.pos += got;
        return { data: out };
      }
      case 'dev':
        if (ofd.dev === 'null') return { data: U8.alloc(0) };
        if (ofd.dev === 'zero') return { data: U8.alloc(n) };
        if (ofd.dev === 'full') return { data: U8.alloc(0) };
        if (ofd.dev === 'urandom') {
          const out = U8.alloc(n);
          out.set(randomBytes(n));
          return { data: out };
        }
        return -E.ENXIO;
      case 'pipe': {
        const pipe = ofd.pipe;
        if (ofd.end !== 'r') return -E.EBADF;
        if (pipe.len > 0) return { data: pipe.read(n) };
        if (pipe.writers === 0) return { data: U8.alloc(0) };
        if (nonblock) return -E.EAGAIN;
        return { block: { kind: 'pipe-read', pipe } };
      }
      case 'eventfd': {
        const ev = ofd.eventfd;
        if (ev.count === 0n) {
          if (nonblock) return -E.EAGAIN;
          return { block: { kind: 'eventfd-read', eventfd: ev } };
        }
        let v;
        if (ev.semaphore) {
          v = 1n;
          ev.count -= 1n;
        } else {
          v = ev.count;
          ev.count = 0n;
        }
        const out = U8.alloc(8);
        out.writeBigUInt64LE(v, 0);
        return { data: out };
      }
      case 'timerfd': {
        const tf = ofd.timerfd;
        const got = tf.consume(this.now());
        if (got === 0) {
          if (nonblock) return -E.EAGAIN;
          return { block: { kind: 'timerfd-read', timerfd: tf } };
        }
        const out = U8.alloc(8);
        out.writeBigUInt64LE(BigInt(got), 0);
        return { data: out };
      }
      case 'file': {
        const buf = U8.alloc(n);
        for (;;) {
          try {
            const got = this.fs.readSync(ofd.fd, buf, 0, n, ofd.pos);
            ofd.pos += got;
            return { data: buf.subarray(0, got) };
          } catch (err) {
            const en = nodeErrno(err);
            if (en === -E.EINTR) continue;
            return en;
          }
        }
      }
      default:
        return -E.EBADF;
    }
  }

  readAt(fd, count, offset) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    const ofd = e.ofd;
    if (ofd.kind === 'file') {
      const buf = U8.alloc(Math.max(0, count | 0));
      try {
        const got = this.fs.readSync(ofd.fd, buf, 0, buf.length, offset);
        return { data: buf.subarray(0, got) };
      } catch (err) {
        return nodeErrno(err);
      }
    }
    if (ofd.kind === 'memfd' || ofd.kind === 'mem') {
      const off = Math.max(0, Number(offset));
      const got = Math.min(count | 0, Math.max(0, ofd.data.length - off));
      return { data: U8.from(ofd.data.subarray(off, off + got)) };
    }
    if (ofd.kind === 'dir' || ofd.kind === 'pipe' || ofd.kind === 'eventfd' ||
        ofd.kind === 'timerfd' || ofd.kind === 'dev') {
      return -E.ESPIPE;
    }
    return -E.EINVAL;
  }

  write(fd, data) {
    const bytes = U8.isBuffer(data) ? data : U8.from(data);
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    const ofd = e.ofd;
    const nonblock = (ofd.flags & O.NONBLOCK) !== 0;

    switch (ofd.kind) {
      case 'stdout':
      case 'stderr':
        try {
          (ofd.kind === 'stdout' ? this.stdout : this.stderr)(bytes);
          return bytes.length;
        } catch (err) {
          return nodeErrno(err);
        }
      case 'stdin':
        return -E.EBADF;
      case 'dir':
        return -E.EISDIR;
      case 'mem':
        return -E.EACCES;
      case 'memfd': {
        if (ofd.append) ofd.pos = ofd.data.length;
        const end = ofd.pos + bytes.length;
        if (end > 0x40000000) return -E.ENOMEM;
        if (end > ofd.data.length) {
          const grown = U8.alloc(Math.max(end, ofd.data.length * 2, 4096));
          ofd.data.copy(grown, 0, 0, ofd.data.length);
          ofd.data = grown;
        }
        bytes.copy(ofd.data, ofd.pos);
        ofd.pos = end;
        ofd.size = ofd.data.length;
        return bytes.length;
      }
      case 'dev':
        if (ofd.dev === 'null' || ofd.dev === 'zero' || ofd.dev === 'urandom') return bytes.length;
        if (ofd.dev === 'full') return -E.ENOSPC;
        return -E.ENXIO;
      case 'pipe': {
        const pipe = ofd.pipe;
        if (ofd.end !== 'w') return -E.EBADF;
        if (pipe.readers === 0) return -E.EPIPE;
        const n = pipe.write(bytes);
        if (n === bytes.length) return n;
        if (n > 0) {
          // A non-blocking pipe may take a prefix; a blocking one waits for
          // the rest, but the bytes already taken stay taken (the caller's
          // loop resumes from there through the wait object).
          if (!nonblock) {
            return { written: n, block: { kind: 'pipe-write', pipe, rest: U8.from(bytes.subarray(n)) } };
          }
          return n;
        }
        if (nonblock) return -E.EAGAIN;
        return { block: { kind: 'pipe-write', pipe, rest: U8.from(bytes) } };
      }
      case 'eventfd': {
        if (bytes.length !== 8) return -E.EINVAL;
        const v = bytes.readBigUInt64LE(0);
        if (v === 0n || v === 0xffffffffffffffffn) return -E.EINVAL;
        const ev = ofd.eventfd;
        if (ev.count + v > 0xfffffffffffffffen) {
          if (nonblock) return -E.EAGAIN;
          return { block: { kind: 'eventfd-write', eventfd: ev, value: v } };
        }
        ev.count += v;
        return 8;
      }
      case 'timerfd':
        return -E.EINVAL;
      case 'file': {
        const fd = ofd.fd;
        let off = 0;
        while (off < bytes.length) {
          const pos = ofd.append ? null : ofd.pos;
          try {
            const got = this.fs.writeSync(fd, bytes, off, bytes.length - off, pos);
            off += got;
            if (!ofd.append) ofd.pos += got;
          } catch (err) {
            const en = nodeErrno(err);
            if (en === -E.EINTR) continue;
            return en;
          }
        }
        if (ofd.append) {
          try {
            ofd.pos = Number(this.fs.fstatSync(fd).size);
          } catch (err) {
            /* the position is advisory for a file opened O_APPEND */
          }
        }
        return bytes.length;
      }
      default:
        return -E.EBADF;
    }
  }

  writeAt(fd, data, offset) {
    const bytes = U8.isBuffer(data) ? data : U8.from(data);
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    const ofd = e.ofd;
    if (ofd.kind === 'file') {
      let off = 0;
      while (off < bytes.length) {
        try {
          off += this.fs.writeSync(ofd.fd, bytes, off, bytes.length - off, Number(offset) + off);
        } catch (err) {
          return nodeErrno(err);
        }
      }
      return bytes.length;
    }
    if (ofd.kind === 'memfd') {
      const at = Number(offset);
      const end = at + bytes.length;
      if (end > 0x40000000) return -E.ENOMEM;
      if (end > ofd.data.length) {
        const grown = U8.alloc(Math.max(end, ofd.data.length * 2, 4096));
        ofd.data.copy(grown, 0, 0, ofd.data.length);
        ofd.data = grown;
      }
      bytes.copy(ofd.data, at);
      ofd.size = ofd.data.length;
      return bytes.length;
    }
    return -E.ESPIPE;
  }

  lseek(fd, offset, whence) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    const ofd = e.ofd;
    if (ofd.kind === 'dir') {
      if (whence === SEEK.SET && offset === 0) {
        ofd.index = 0;
        ofd.entries = null;
        return 0;
      }
      return -E.EINVAL;
    }
    if (ofd.kind !== 'file' && ofd.kind !== 'mem' && ofd.kind !== 'memfd') {
      return -E.ESPIPE;
    }
    let base;
    if (whence === SEEK.SET) base = 0;
    else if (whence === SEEK.CUR) base = ofd.pos || 0;
    else if (whence === SEEK.END) {
      if (ofd.kind === 'file') {
        try {
          base = Number(this.fs.fstatSync(ofd.fd).size);
        } catch (err) {
          return nodeErrno(err);
        }
      } else if (ofd.kind === 'mem') base = ofd.data.length;
      else base = ofd.data.length;
    } else return -E.EINVAL;
    const pos = base + Number(offset);
    if (pos < 0) return -E.EINVAL;
    ofd.pos = pos;
    return pos;
  }

  // -- stat -----------------------------------------------------------------

  _applyShadow(abs, st) {
    if (typeof st !== 'object' || st === null) return st;
    const mode = this.modes.get(abs);
    if (mode !== undefined) st.mode = (st.mode & S_IFMT) | mode;
    const own = this.owners.get(abs);
    if (own !== undefined) {
      st.uid = own.uid;
      st.gid = own.gid;
    }
    return st;
  }

  stat(path, follow = true) {
    const abs = this.resolve(path);
    const s = this._synth(abs);
    if (s) {
      if (s.kind === 'fdlink') {
        if (follow) {
          const st = this.fstat(s.fd);
          return typeof st === 'number' ? -E.ENOENT : this._applyShadow(abs, st);
        }
        return this._applyShadow(abs, statObj({ mode: s.mode, size: U8.byteLength(s.target), ino: inoOf(abs) }));
      }
      if (s.kind === 'link') {
        return this._applyShadow(abs, statObj({
          mode: s.mode, size: U8.byteLength(s.target), nlink: 1, ino: inoOf(abs),
        }));
      }
      if (s.kind === 'dir') {
        return this._applyShadow(abs, statObj({ mode: s.mode, nlink: 2, ino: inoOf(abs) }));
      }
      const size = s.kind === 'mem' ? s.data.length : 0;
      return this._applyShadow(abs, statObj({ mode: s.mode, size, ino: inoOf(abs) }));
    }
    try {
      const st = follow ? this.fs.statSync(abs) : this.fs.lstatSync(abs);
      return this._applyShadow(abs, fromNodeStats(st));
    } catch (err) {
      return nodeErrno(err);
    }
  }

  fstat(fd) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    const ofd = e.ofd;
    switch (ofd.kind) {
      case 'stdin':
      case 'stdout':
      case 'stderr':
        return statObj({ mode: S_IFCHR | 0o620, size: 0, nlink: 1 });
      case 'dir':
        if (ofd.fd !== undefined) {
          try {
            return fromNodeStats(this.fs.fstatSync(ofd.fd));
          } catch (err) {
            return nodeErrno(err);
          }
        }
        return statObj({ mode: S_IFDIR | 0o755, size: ofd.entries ? ofd.entries.length : 0, nlink: 2 });
      case 'mem':
        return statObj({ mode: S_IFREG | 0o444, size: ofd.data.length, nlink: 1 });
      case 'memfd':
        return statObj({ mode: S_IFREG | 0o600, size: ofd.data.length, nlink: 1 });
      case 'dev':
        return statObj({ mode: S_IFCHR | 0o666, size: 0 });
      case 'pipe':
        return statObj({ mode: S_IFIFO | 0o600, size: 0, nlink: 1, ino: ofd.pipe.ino });
      case 'eventfd':
        return statObj({ mode: S_IFREG | 0o600, size: 0, nlink: 1 });
      case 'timerfd':
        return statObj({ mode: S_IFREG | 0o600, size: 0, nlink: 1 });
      case 'file':
        try {
          return fromNodeStats(this.fs.fstatSync(ofd.fd));
        } catch (err) {
          return nodeErrno(err);
        }
      default:
        return -E.EBADF;
    }
  }

  // -- access ---------------------------------------------------------------

  access(path, mode) {
    const abs = this.resolve(path);
    const s = this._synth(abs);
    if (s) {
      if (s.kind === 'fdlink') return this.fds.has(s.fd) ? 0 : -E.ENOENT;
      return 0;
    }
    try {
      this.fs.accessSync(abs, mode === 0 ? this.fs.constants.F_OK : mode);
      return 0;
    } catch (err) {
      return nodeErrno(err);
    }
  }

  chdir(path) {
    const abs = this.resolve(path);
    const st = this.stat(abs);
    if (typeof st === 'number') return st;
    if ((st.mode & S_IFMT) !== S_IFDIR) return -E.ENOTDIR;
    this.cwd = abs;
    return 0;
  }

  fchdir(fd) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    if (e.ofd.kind !== 'dir') return -E.ENOTDIR;
    this.cwd = e.ofd.path;
    return 0;
  }

  readlink(path) {
    const abs = this.resolve(path);
    const s = this._synth(abs);
    if (s && (s.kind === 'link' || s.kind === 'fdlink')) return s.target;
    if (s) return -E.EINVAL;
    try {
      return this.fs.readlinkSync(abs);
    } catch (err) {
      return nodeErrno(err);
    }
  }

  // -- mutations ------------------------------------------------------------

  mkdir(path, mode = 0o777) {
    const abs = this.resolve(path);
    if (this._isSyntheticMount(abs)) return -E.EACCES;
    try {
      this.fs.mkdirSync(abs, mode & ~this.umask);
      return 0;
    } catch (err) {
      return nodeErrno(err);
    }
  }

  rmdir(path) {
    const abs = this.resolve(path);
    if (this._isSyntheticMount(abs)) return -E.EACCES;
    try {
      this.fs.rmdirSync(abs);
      return 0;
    } catch (err) {
      return nodeErrno(err);
    }
  }

  unlink(path) {
    const abs = this.resolve(path);
    if (this._isSyntheticMount(abs)) return -E.EACCES;
    try {
      this.fs.unlinkSync(abs);
      this.modes.delete(abs);
      this.owners.delete(abs);
      return 0;
    } catch (err) {
      return nodeErrno(err);
    }
  }

  rename(oldPath, newPath, flags = 0) {
    const from = this.resolve(oldPath);
    const to = this.resolve(newPath);
    if (this._isSyntheticMount(from) || this._isSyntheticMount(to)) return -E.EACCES;
    if (flags & 0x4) return -E.EINVAL; // RENAME_WHITEOUT
    try {
      if (flags & 0x2) {
        // RENAME_EXCHANGE
        const tmp = `${to}.yexch.${this.pid}.${nextIno++}`;
        this.fs.renameSync(from, tmp);
        this.fs.renameSync(to, from);
        this.fs.renameSync(tmp, to);
      } else {
        if (flags & 0x1) {
          let exists = true;
          try {
            this.fs.lstatSync(to);
          } catch (e) {
            if (e.code === 'ENOENT') exists = false;
            else return nodeErrno(e);
          }
          if (exists) return -E.EEXIST;
        }
        this.fs.renameSync(from, to);
      }
      const m = this.modes.get(from);
      if (m !== undefined) {
        this.modes.delete(from);
        this.modes.set(to, m);
      }
      return 0;
    } catch (err) {
      return nodeErrno(err);
    }
  }

  symlink(target, path) {
    const abs = this.resolve(path);
    if (this._isSyntheticMount(abs)) return -E.EACCES;
    try {
      this.fs.symlinkSync(target, abs);
      return 0;
    } catch (err) {
      return nodeErrno(err);
    }
  }

  chmod(path, mode, follow = true) {
    const abs = this.resolve(path);
    if (this._isSyntheticMount(abs)) {
      // A device node has no stored mode; Linux's chmod on /dev/null succeeds.
      if (abs.startsWith('/dev/')) { this.modes.set(abs, mode & 0o7777); return 0; }
      return -E.EACCES;
    }
    try {
      if (follow) this.fs.chmodSync(abs, mode & 0o7777);
      else if (typeof this.fs.lchmodSync === 'function') this.fs.lchmodSync(abs, mode & 0o7777);
      else {
        // Linux Node has no lchmod; keep the mode in the shadow.
        this.modes.set(abs, mode & 0o7777);
        return 0;
      }
    } catch (err) {
      // S9 keeps a stored mode; a read-only mount is still a success for it.
      const en = nodeErrno(err);
      if (en !== -E.EPERM && en !== -E.ENOENT && en !== -E.EINVAL) return en;
      if (en === -E.ENOENT) return en;
    }
    this.modes.set(abs, mode & 0o7777);
    return 0;
  }

  chown(path, uid, gid, follow = true) {
    const abs = this.resolve(path);
    if (this._isSyntheticMount(abs)) return -E.EACCES;
    // S9: fchownat succeeds; ownership is stored so a later stat agrees.
    if (!follow) {
      const st = this.stat(abs, false);
      if (typeof st === 'number') return st;
    }
    this.owners.set(abs, { uid, gid });
    return 0;
  }

  fchmod(fd, mode) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    const ofd = e.ofd;
    if (ofd.kind === 'file' || ofd.kind === 'dir') {
      try {
        this.fs.fchmodSync(ofd.fd, mode & 0o7777);
      } catch (err) {
        const en = nodeErrno(err);
        if (en !== -E.EPERM) return en;
      }
      this.modes.set(ofd.path, mode & 0o7777);
      return 0;
    }
    if (ofd.kind === 'memfd') {
      this.modes.set(ofd.path || '/memfd', mode & 0o7777);
      return 0;
    }
    return 0;
  }

  truncate(path, length) {
    const abs = this.resolve(path);
    if (this._isSyntheticMount(abs)) return -E.EACCES;
    if (length < 0) return -E.EINVAL;
    try {
      this.fs.truncateSync(abs, Number(length));
      return 0;
    } catch (err) {
      return nodeErrno(err);
    }
  }

  ftruncate(fd, length) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    const len = Number(length);
    if (len < 0) return -E.EINVAL;
    const ofd = e.ofd;
    if (ofd.kind === 'file') {
      try {
        this.fs.ftruncateSync(ofd.fd, len);
        return 0;
      } catch (err) {
        return nodeErrno(err);
      }
    }
    if (ofd.kind === 'memfd') {
      if (len > 0x40000000) return -E.ENOMEM;
      if (len > ofd.data.length) {
        const grown = U8.alloc(len);
        ofd.data.copy(grown, 0, 0, ofd.data.length);
        ofd.data = grown;
      } else {
        ofd.data = U8.from(ofd.data.subarray(0, len));
      }
      ofd.size = ofd.data.length;
      return 0;
    }
    return -E.EINVAL;
  }

  sync(fd) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    const ofd = e.ofd;
    if (ofd.kind === 'file' && ofd.fd !== undefined) {
      try {
        if (typeof this.fs.fsyncSync === 'function') this.fs.fsyncSync(ofd.fd);
      } catch (err) {
        const en = nodeErrno(err);
        if (en !== -E.EINVAL && en !== -E.EROFS) return en;
      }
    }
    if (this.store && typeof this.store.flushSoon === 'function') this.store.flushSoon();
    return 0;
  }

  fchown(fd, uid, gid) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    const ofd = e.ofd;
    if (ofd.kind === 'file' || ofd.kind === 'dir') {
      try {
        if (typeof this.fs.fchownSync === 'function') this.fs.fchownSync(ofd.fd, uid, gid);
      } catch (err) {
        const en = nodeErrno(err);
        if (en !== -E.EPERM) return en;
      }
    }
    if (ofd.path) this.owners.set(ofd.path, { uid, gid });
    return 0;
  }

  // -- pipes, memfd, eventfd, timerfd --------------------------------------

  pipe(flags = 0) {
    const pipe = new Pipe();
    const r = new OpenFile('pipe', { pipe, end: 'r' });
    const w = new OpenFile('pipe', { pipe, end: 'w' });
    r.flags = flags & O.NONBLOCK;
    w.flags = flags & O.NONBLOCK;
    pipe.readers = 1;
    pipe.writers = 1;
    const rfd = this.install(r, undefined, (flags & O.CLOEXEC) !== 0);
    if (typeof rfd !== 'number' || rfd < 0) return rfd;
    const wfd = this.install(w, undefined, (flags & O.CLOEXEC) !== 0);
    if (typeof wfd !== 'number' || wfd < 0) {
      this.close(rfd);
      return wfd;
    }
    return { readFd: rfd, writeFd: wfd };
  }

  memfd(name, flags = 0) {
    const ofd = new OpenFile('memfd', { data: U8.alloc(0), name: String(name || 'memfd'), path: '/memfd:' + name });
    ofd.flags = flags & O.NONBLOCK;
    return this.install(ofd, undefined, (flags & 1) !== 0);
  }

  eventfd(initval, flags = 0) {
    const sem = (flags & 1) !== 0;
    const ofd = new OpenFile('eventfd', { eventfd: new EventFd(initval, sem) });
    ofd.flags = flags & O.NONBLOCK;
    return this.install(ofd, undefined, (flags & O.CLOEXEC) !== 0);
  }

  timerfd(clockid, flags = 0) {
    const ofd = new OpenFile('timerfd', { timerfd: new TimerFd(clockid) });
    ofd.flags = flags & O.NONBLOCK;
    return this.install(ofd, undefined, (flags & O.CLOEXEC) !== 0);
  }

  timerfdSet(fd, { value, interval }, absolute) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    if (e.ofd.kind !== 'timerfd') return -E.EINVAL;
    const tf = e.ofd.timerfd;
    const now = this.now();
    const old = {
      intervalSec: Math.floor(tf.interval / 1000),
      intervalNsec: Math.floor((tf.interval % 1000) * 1e6),
      valueSec: tf.next === Infinity ? 0 : Math.floor(tf.next / 1000),
      valueNsec: tf.next === Infinity ? 0 : Math.floor((tf.next % 1000) * 1e6),
    };
    const v = value.sec * 1000 + value.nsec / 1e6;
    tf.next = v <= 0 ? now : (absolute ? v : now + v);
    tf.interval = interval.sec * 1000 + interval.nsec / 1e6;
    tf.expirations = 0;
    return old;
  }

  timerfdGet(fd) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    if (e.ofd.kind !== 'timerfd') return -E.EINVAL;
    const tf = e.ofd.timerfd;
    return {
      intervalSec: Math.floor(tf.interval / 1000),
      intervalNsec: Math.floor((tf.interval % 1000) * 1e6),
      valueSec: tf.next === Infinity ? 0 : Math.floor(tf.next / 1000),
      valueNsec: tf.next === Infinity ? 0 : Math.floor((tf.next % 1000) * 1e6),
    };
  }

  // -- poll -----------------------------------------------------------------

  pollFd(fd, events) {
    const e = this.fds.get(fd);
    if (!e) return POLL.NVAL;
    const ofd = e.ofd;
    let r = 0;
    const wantIn = (events & (POLL.IN | POLL.RDNORM)) !== 0;
    const wantOut = (events & (POLL.OUT | POLL.WRNORM)) !== 0;
    switch (ofd.kind) {
      case 'stdin':
        if (wantIn) r |= POLL.IN;
        break;
      case 'stdout':
      case 'stderr':
        if (wantOut) r |= POLL.OUT;
        break;
      case 'file':
      case 'mem':
      case 'memfd':
      case 'dir':
        if (wantIn) r |= POLL.IN;
        if (wantOut) r |= POLL.OUT;
        break;
      case 'dev':
        if (wantIn) r |= POLL.IN;
        if (wantOut) r |= POLL.OUT;
        break;
      case 'pipe': {
        const pipe = ofd.pipe;
        if (ofd.end === 'r') {
          if (pipe.len > 0) r |= POLL.IN;
          if (pipe.writers === 0) r |= POLL.HUP;
        } else {
          if (pipe.len < pipe.capacity && pipe.readers > 0) r |= POLL.OUT;
          if (pipe.readers === 0) r |= POLL.ERR;
        }
        break;
      }
      case 'eventfd': {
        if (ofd.eventfd.count > 0n) r |= POLL.IN;
        if (ofd.eventfd.count < 0xfffffffffffffffen) r |= POLL.OUT;
        break;
      }
      case 'timerfd':
        if (ofd.timerfd.due(this.now()) > 0) r |= POLL.IN;
        break;
      default:
        break;
    }
    return r & (events | POLL.ERR | POLL.HUP | POLL.NVAL);
  }

  // True when a poll wait on these descriptors can make progress.
  pollReady(fds) {
    for (const p of fds) {
      if (this.pollFd(p.fd, p.events) !== 0) return true;
    }
    return false;
  }

  fdFlags(fd) {
    const e = this.fds.get(fd);
    return e ? e.ofd.flags : -E.EBADF;
  }

  setFdFlags(fd, flags) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    e.ofd.flags = flags;
    if (e.ofd.kind === 'file' || e.ofd.kind === 'memfd') {
      e.ofd.append = (flags & O.APPEND) !== 0;
    }
    return 0;
  }

  getCloexec(fd) {
    const e = this.fds.get(fd);
    return e ? (e.cloexec ? 1 : 0) : -E.EBADF;
  }

  setCloexec(fd, on) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    e.cloexec = !!on;
    return 0;
  }

  // Number of bytes immediately readable, for FIONREAD.
  bytesReady(fd) {
    const e = this.fds.get(fd);
    if (!e) return -E.EBADF;
    const ofd = e.ofd;
    if (ofd.kind === 'pipe') return ofd.pipe.len;
    if (ofd.kind === 'mem' || ofd.kind === 'memfd') {
      return Math.max(0, ofd.data.length - ofd.pos);
    }
    if (ofd.kind === 'file') {
      try {
        return Math.max(0, Number(this.fs.fstatSync(ofd.fd).size) - ofd.pos);
      } catch (err) {
        return nodeErrno(err);
      }
    }
    if (ofd.kind === 'eventfd') return 8;
    if (ofd.kind === 'timerfd') return 8;
    return 0;
  }
}
