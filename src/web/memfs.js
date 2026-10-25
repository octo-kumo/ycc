// src/web/memfs.js — the in-memory file system behind vfs.js in a browser.
//
// vfs.js is platform neutral: it asks its backend for the small synchronous
// subset of Node's fs API (openSync/readSync/statSync/...).  Node passes
// node:fs.  The browser passes this class, which keeps a tree in memory,
// populates /app from files.bin and queues changes
// under /home/web for store.js (IndexedDB).
//
// Paths here are absolute and already normalised by vfs.js.  Errors are the
// usual objects with a .code, so vfs.js's nodeErrno maps them.

import { O, PAGE_SIZE, S_IFDIR, S_IFLNK, S_IFREG, S_IFMT } from './abi.js';
import { U8 } from './bytes.js';

const F_OK = 0;
const R_OK = 4;
const W_OK = 2;
const X_OK = 1;

export const MEM_CONSTANTS = Object.freeze({
  O_RDONLY: O.RDONLY,
  O_WRONLY: O.WRONLY,
  O_RDWR: O.RDWR,
  O_CREAT: O.CREAT,
  O_EXCL: O.EXCL,
  O_TRUNC: O.TRUNC,
  O_APPEND: O.APPEND,
  O_DIRECTORY: O.DIRECTORY,
  O_NOFOLLOW: O.NOFOLLOW,
  O_NONBLOCK: O.NONBLOCK,
  F_OK, R_OK, W_OK, X_OK,
});

function fsError(code, message) {
  // nodeErrno() in vfs.js maps .code; leaving .errno unset makes it use that
  // table rather than mistaking a sentinel for a real errno.
  const e = new Error(message || code);
  e.code = code;
  return e;
}

function normalizeAbs(path) {
  const out = [];
  for (const part of String(path).split('/')) {
    if (part === '' || part === '.') continue;
    if (part === '..') out.pop();
    else out.push(part);
  }
  return '/' + out.join('/');
}

function hashIno(path) {
  let h = 2166136261;
  for (let i = 0; i < path.length; i++) {
    h ^= path.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0) + 1;
}

function parentOf(path) {
  const i = path.lastIndexOf('/');
  return i <= 0 ? '/' : path.slice(0, i);
}

function baseOf(path) {
  const i = path.lastIndexOf('/');
  return path.slice(i + 1);
}

function joinPath(dir, name) {
  return dir === '/' ? '/' + name : dir + '/' + name;
}

function isUnder(path, root) {
  return path === root || path.startsWith(root + '/');
}

// The files.bin format:
//   "YWFS1\n", count u32, then path_len u32, path, mode u32, size u64, bytes.
// Returns [{path, mode, data}], sorted by path.
export function readFilesBin(input) {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  const magic = 'YWFS1\n';
  if (bytes.length < magic.length + 4) throw new Error('files.bin: truncated header');
  for (let i = 0; i < magic.length; i++) {
    if (bytes[i] !== magic.charCodeAt(i)) throw new Error('files.bin: bad magic');
  }
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let p = magic.length;
  const count = dv.getUint32(p, true);
  p += 4;
  const out = [];
  for (let i = 0; i < count; i++) {
    if (p + 4 > bytes.length) throw new Error('files.bin: truncated entry');
    const plen = dv.getUint32(p, true);
    p += 4;
    if (p + plen + 4 + 8 > bytes.length) throw new Error('files.bin: truncated entry');
    const path = new TextDecoder().decode(bytes.subarray(p, p + plen));
    p += plen;
    const mode = dv.getUint32(p, true);
    p += 4;
    const sizeBig = dv.getBigUint64(p, true);
    p += 8;
    if (sizeBig > BigInt(0x7fffffff)) throw new Error('files.bin: entry is too large');
    const size = Number(sizeBig);
    if (p + size > bytes.length) throw new Error('files.bin: truncated data for ' + path);
    const data = U8.from(bytes.subarray(p, p + size));
    p += size;
    const parts = path.replace(/\\/g, '/').split('/').filter((part) => part !== '' && part !== '.');
    if (parts.length === 0 || parts.includes('..')) throw new Error('files.bin: bad path ' + path);
    const clean = parts.join('/');
    out.push({ path: clean, mode, data });
  }
  out.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return out;
}

export class MemFs {
  constructor(opts = {}) {
    this.constants = MEM_CONSTANTS;
    this.nodes = new Map();
    this.handles = new Map();
    this.nextHandle = 3;
    this.store = opts.store || null;
    this.persistRoot = opts.persistRoot || '/home/web';
    this.pid = 0;
    this._dir('/', 0o755);
    this._dir('/app', 0o755);
    this._dir('/home', 0o755);
    this._dir('/home/web', 0o755);
    this._dir('/tmp', 0o1777);
    this._dir('/bin', 0o755);
    this._dir('/proc', 0o555);
    this._dir('/dev', 0o555);
    if (opts.records && typeof opts.records.forEach === 'function') {
      opts.records.forEach((rec, path) => this.importRecord(path, rec));
    }
    if (opts.files) {
      for (const ent of readFilesBin(opts.files)) {
        this._installBundled('/app/' + ent.path, ent.mode, ent.data);
      }
    }
  }

  // -- the node table -------------------------------------------------------

  _dir(path, mode) {
    const at = this._ensureParents(path);
    let node = this.nodes.get(path);
    if (!node) {
      node = { kind: 'dir', mode: S_IFDIR | (mode & 0o7777), uid: 1000, gid: 1000,
        mtimeMs: Date.now(), atimeMs: Date.now(), ctimeMs: Date.now() };
      this.nodes.set(path, node);
    }
    return node;
  }

  _ensureParents(path) {
    const parts = path.split('/').filter(Boolean);
    let p = '';
    for (let i = 0; i < parts.length - 1; i++) {
      p += '/' + parts[i];
      if (p === '') p = '/';
      const n = this.nodes.get(p);
      if (!n) this.nodes.set(p, { kind: 'dir', mode: S_IFDIR | 0o755, uid: 1000, gid: 1000,
        mtimeMs: Date.now(), atimeMs: Date.now(), ctimeMs: Date.now() });
      else if (n.kind !== 'dir') throw fsError('ENOTDIR');
    }
  }

  _installBundled(path, mode, data) {
    this._ensureParents(path);
    const isDir = (mode & S_IFMT) === S_IFDIR;
    this.nodes.set(path, isDir
      ? { kind: 'dir', mode: S_IFDIR | (mode & 0o7777), uid: 1000, gid: 1000, mtimeMs: Date.now(), atimeMs: Date.now(), ctimeMs: Date.now() }
      : { kind: 'file', data: U8.from(data), size: data.length, mode: S_IFREG | ((mode & 0o7777) || 0o644), uid: 1000, gid: 1000,
          mtimeMs: Date.now(), atimeMs: Date.now(), ctimeMs: Date.now() });
  }

  importRecord(path, rec) {
    if (!rec) return;
    if (rec.kind === 'dir') this._dir(path, rec.mode || 0o755);
    else if (rec.kind === 'symlink') {
      this._ensureParents(path);
      this.nodes.set(path, { kind: 'symlink', target: String(rec.target || ''), mode: S_IFLNK | 0o777,
        uid: 1000, gid: 1000, mtimeMs: rec.mtimeMs || Date.now(), atimeMs: rec.mtimeMs || Date.now(), ctimeMs: rec.mtimeMs || Date.now() });
    } else {
      this._ensureParents(path);
      this.nodes.set(path, { kind: 'file', data: U8.from(rec.data || []), size: (rec.data || []).length, mode: S_IFREG | ((rec.mode || 0o644) & 0o7777),
        uid: rec.uid === undefined ? 1000 : rec.uid, gid: rec.gid === undefined ? 1000 : rec.gid,
        mtimeMs: rec.mtimeMs || Date.now(), atimeMs: rec.mtimeMs || Date.now(), ctimeMs: rec.mtimeMs || Date.now() });
    }
  }

  // The current persistent value of one path, for store.js.
  record(path) {
    const node = this.nodes.get(path);
    if (!node) return null;
    const out = { kind: node.kind, mode: node.mode & 0o7777, uid: node.uid, gid: node.gid, mtimeMs: node.mtimeMs };
    if (node.kind === 'file') out.data = U8.from(node.data.subarray(0, node.size || 0));
    if (node.kind === 'symlink') out.target = node.target;
    return out;
  }

  // -- changes --------------------------------------------------------------

  _changed(path, tree = false) {
    if (!this.store) return;
    const push = (p) => { if (isUnder(p, this.persistRoot)) this.store.changed(p); };
    push(path);
    if (tree) {
      for (const p of this.nodes.keys()) if (isUnder(p, path)) push(p);
    }
  }

  _changedTree(path) {
    this._changed(path, true);
  }

  _touch(node) {
    node.mtimeMs = Date.now();
    node.ctimeMs = node.mtimeMs;
  }

  // -- path lookup ----------------------------------------------------------

  _lookup(path, follow = true, depth = 0) {
    if (depth > 40) throw fsError('ELOOP');
    if (path === '/') return this.nodes.get('/');
    const parts = path.split('/').filter(Boolean);
    let cur = '/';
    let node = this.nodes.get('/');
    for (let i = 0; i < parts.length; i++) {
      if (!node) throw fsError('ENOENT');
      if (node.kind !== 'dir') throw fsError('ENOTDIR');
      cur = joinPath(cur, parts[i]);
      node = this.nodes.get(cur);
      if (!node) throw fsError('ENOENT');
      const last = i === parts.length - 1;
      if (node.kind === 'symlink' && (!last || follow)) {
        const target = normalizeAbs(node.target.startsWith('/') ? node.target : joinPath(parentOf(cur), node.target));
        const rest = parts.slice(i + 1).join('/');
        return this._lookup(rest ? target + '/' + rest : target, follow, depth + 1);
      }
    }
    return node;
  }

  _require(path, follow = true) {
    const node = this._lookup(path, follow);
    if (!node) throw fsError('ENOENT');
    return node;
  }

  _stat(path, node) {
    const isDir = node.kind === 'dir';
    return {
      dev: 1, ino: hashIno(path), nlink: isDir ? 2 : 1,
      mode: node.mode, uid: node.uid === undefined ? 1000 : node.uid,
      gid: node.gid === undefined ? 1000 : node.gid,
      rdev: 0, size: node.kind === 'file' ? node.size : node.kind === 'symlink' ? node.target.length : 0,
      blksize: PAGE_SIZE, blocks: node.kind === 'file' ? Math.ceil(node.size / 512) : 0,
      atimeMs: node.atimeMs || 0, mtimeMs: node.mtimeMs || 0, ctimeMs: node.ctimeMs || 0,
      isDirectory: () => isDir, isFile: () => node.kind === 'file', isSymbolicLink: () => node.kind === 'symlink',
      isCharacterDevice: () => false, isFIFO: () => false, isSocket: () => false, isBlockDevice: () => false,
    };
  }

  // -- fs API ---------------------------------------------------------------

  openSync(path, flags, mode = 0o666) {
    const acc = flags & 3;
    const create = (flags & O.CREAT) !== 0;
    const excl = (flags & O.EXCL) !== 0;
    const trunc = (flags & O.TRUNC) !== 0;
    const dirOnly = (flags & O.DIRECTORY) !== 0;
    const noFollow = (flags & O.NOFOLLOW) !== 0;
    let node = null;
    let exists = true;
    try {
      node = this._lookup(path, !noFollow);
    } catch (e) {
      if (e.code === 'ENOENT') exists = false;
      else if (e.code === 'ELOOP' && noFollow) return this._fail('ELOOP');
      else throw e;
    }
    if (!exists) {
      if (!create) throw fsError('ENOENT');
      this._ensureParents(path);
      node = { kind: 'file', data: new U8(0), size: 0, mode: S_IFREG | ((mode || 0o666) & 0o7777), uid: 1000, gid: 1000,
        mtimeMs: Date.now(), atimeMs: Date.now(), ctimeMs: Date.now() };
      this.nodes.set(path, node);
      this._changed(path);
    } else if (create && excl) {
      throw fsError('EEXIST');
    }
    if (node.kind === 'dir') {
      if (dirOnly === false && acc !== O.RDONLY) throw fsError('EISDIR');
    } else if (dirOnly) {
      throw fsError('ENOTDIR');
    } else if (acc !== O.RDONLY && node.mode !== undefined && this._modePerm(node) !== 0) {
      // Access is enforced by access(); open follows Linux closely enough to
      // refuse a mode-000 file to a non-owner write.
      if ((node.mode & 0o222) === 0) throw fsError('EACCES');
    }
    if (trunc && node.kind === 'file') {
      node.data = new U8(0);
      node.size = 0;
      this._touch(node);
      this._changed(path);
    }
    const handle = this.nextHandle++;
    this.handles.set(handle, { path, node, flags, pos: 0 });
    return handle;
  }

  _modePerm(node) {
    return node.mode & 0o777;
  }

  _fd(handle) {
    const h = this.handles.get(handle);
    if (!h) throw fsError('EBADF');
    return h;
  }

  closeSync(handle) {
    if (!this.handles.has(handle)) throw fsError('EBADF');
    this.handles.delete(handle);
  }

  readSync(handle, buf, offset, length, position) {
    const h = this._fd(handle);
    const node = h.node;
    if (node.kind !== 'file') throw fsError('EISDIR');
    const pos = position === null || position === undefined ? h.pos : Number(position);
    const n = Math.max(0, Math.min(length, node.size - pos));
    buf.set(node.data.subarray(pos, pos + n), offset);
    if (position === null || position === undefined) h.pos += n;
    return n;
  }

  writeSync(handle, buf, offset, length, position) {
    const h = this._fd(handle);
    const node = h.node;
    if (node.kind === 'dir') throw fsError('EISDIR');
    let pos = position === null || position === undefined ? h.pos : Number(position);
    if (h.flags & O.APPEND) pos = node.size;
    const end = pos + length;
    if (end > 0x40000000) throw fsError('ENOMEM');
    if (end > node.data.length) {
      const grown = new U8(Math.max(end, node.data.length * 2, 4096));
      grown.set(node.data);
      node.data = grown;
    }
    node.data.set(buf.subarray(offset, offset + length), pos);
    if (end > node.size) node.size = end;
    if (position === null || position === undefined) h.pos = end;
    this._touch(node);
    this._changed(h.path);
    return length;
  }

  fstatSync(handle) {
    const h = this._fd(handle);
    return this._stat(h.path, h.node);
  }

  statSync(path) {
    const node = this._lookup(path, true);
    if (!node) throw fsError('ENOENT');
    return this._stat(path, node);
  }

  lstatSync(path) {
    const node = this._lookup(path, false);
    if (!node) throw fsError('ENOENT');
    return this._stat(path, node);
  }

  readdirSync(path, opts) {
    const node = this._lookup(path, true);
    if (!node) throw fsError('ENOENT');
    if (node.kind !== 'dir') throw fsError('ENOTDIR');
    const prefix = path === '/' ? '/' : path + '/';
    const names = [];
    for (const p of this.nodes.keys()) {
      if (!p.startsWith(prefix) || p === prefix) continue;
      const rest = p.slice(prefix.length);
      if (rest === '' || rest.includes('/')) continue;
      names.push(rest);
    }
    names.sort();
    if (!opts || !opts.withFileTypes) return names;
    return names.map((name) => {
      const child = this.nodes.get(joinPath(path, name));
      return {
        name,
        isDirectory: () => child.kind === 'dir',
        isFile: () => child.kind === 'file',
        isSymbolicLink: () => child.kind === 'symlink',
        isCharacterDevice: () => false,
        isFIFO: () => false,
        isSocket: () => false,
        isBlockDevice: () => false,
      };
    });
  }

  readlinkSync(path) {
    const node = this._lookup(path, false);
    if (!node) throw fsError('ENOENT');
    if (node.kind !== 'symlink') throw fsError('EINVAL');
    return node.target;
  }

  mkdirSync(path, mode = 0o777) {
    if (this.nodes.has(path)) throw fsError('EEXIST');
    this._ensureParents(path);
    this._dir(path, mode);
    this._changed(path);
  }

  rmdirSync(path) {
    const node = this._lookup(path, false);
    if (!node) throw fsError('ENOENT');
    if (node.kind !== 'dir') throw fsError('ENOTDIR');
    const prefix = path === '/' ? '/' : path + '/';
    for (const p of this.nodes.keys()) if (p.startsWith(prefix)) throw fsError('ENOTEMPTY');
    this.nodes.delete(path);
    this._changedTree(path);
  }

  unlinkSync(path) {
    const node = this._lookup(path, false);
    if (!node) throw fsError('ENOENT');
    if (node.kind === 'dir') throw fsError('EISDIR');
    this.nodes.delete(path);
    this._changed(path);
  }

  renameSync(from, to) {
    const node = this._lookup(from, false);
    if (!node) throw fsError('ENOENT');
    this._ensureParents(to);
    const moving = [];
    const prefix = from === '/' ? '/' : from + '/';
    for (const [p, n] of this.nodes) {
      if (p === from || p.startsWith(prefix)) moving.push([p, n]);
    }
    let oldTo = null;
    try { oldTo = this._lookup(to, false); } catch (e) { oldTo = null; }
    if (oldTo) {
      if (oldTo.kind === 'dir' && node.kind !== 'dir') throw fsError('EISDIR');
      if (oldTo.kind !== 'dir' && node.kind === 'dir') throw fsError('ENOTDIR');
      this.nodes.delete(to);
      this._changedTree(to);
    }
    // Remember the old paths so store.js can delete them.
    const oldPaths = moving.map(([p]) => p);
    for (const [p] of moving) this.nodes.delete(p);
    for (const [p, n] of moving) {
      const dest = p === from ? to : to + p.slice(from.length);
      this.nodes.set(dest, n);
    }
    for (const p of oldPaths) this._changed(p);
    this._changedTree(to);
  }

  symlinkSync(target, path) {
    if (this.nodes.has(path)) throw fsError('EEXIST');
    this._ensureParents(path);
    this.nodes.set(path, { kind: 'symlink', target: String(target), mode: S_IFLNK | 0o777, uid: 1000, gid: 1000,
      mtimeMs: Date.now(), atimeMs: Date.now(), ctimeMs: Date.now() });
    this._changed(path);
  }

  chmodSync(path, mode) {
    const node = this._lookup(path, true);
    if (!node) throw fsError('ENOENT');
    node.mode = (node.mode & S_IFMT) | (mode & 0o7777);
    this._touch(node);
    this._changed(path);
  }

  fchmodSync(handle, mode) {
    const h = this._fd(handle);
    h.node.mode = (h.node.mode & S_IFMT) | (mode & 0o7777);
    this._touch(h.node);
    this._changed(h.path);
  }

  chownSync(path, uid, gid) {
    const node = this._lookup(path, true);
    if (!node) throw fsError('ENOENT');
    node.uid = uid;
    node.gid = gid;
    this._changed(path);
  }

  fchownSync(handle, uid, gid) {
    const h = this._fd(handle);
    h.node.uid = uid;
    h.node.gid = gid;
    this._changed(h.path);
  }

  truncateSync(path, length) {
    const node = this._lookup(path, true);
    if (!node) throw fsError('ENOENT');
    if (node.kind !== 'file') throw fsError('EISDIR');
    this._truncateNode(path, node, length);
  }

  ftruncateSync(handle, length) {
    const h = this._fd(handle);
    if (h.node.kind !== 'file') throw fsError('EINVAL');
    this._truncateNode(h.path, h.node, length);
  }

  _truncateNode(path, node, length) {
    const len = Number(length);
    if (len < 0) throw fsError('EINVAL');
    if (len > 0x40000000) throw fsError('ENOMEM');
    if (len > node.data.length) {
      const grown = new U8(len);
      grown.set(node.data);
      node.data = grown;
    } else {
      node.data.fill(0, len, node.size);
    }
    node.size = len;
    this._touch(node);
    this._changed(path);
  }

  accessSync(path, mode = F_OK) {
    let node;
    try { node = this._lookup(path, true); } catch (e) { return this._fail(e.code || 'ENOENT'); }
    if (!node) return this._fail('ENOENT');
    if (mode !== F_OK) {
      const perm = node.mode & 0o777;
      // uid 1000 owns everything the web host creates; use the owner bits.
      if ((mode & R_OK) && !(perm & 0o400)) return this._fail('EACCES');
      if ((mode & W_OK) && !(perm & 0o200)) return this._fail('EACCES');
      if ((mode & X_OK) && !(perm & 0o100)) return this._fail('EACCES');
    }
    return undefined;
  }

  fsyncSync(handle) {
    this._fd(handle);
    if (this.store && typeof this.store.flushSoon === 'function') this.store.flushSoon();
  }

  _fail(code) {
    throw fsError(code);
  }
}
