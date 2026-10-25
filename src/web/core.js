// src/web/core.js — the platform-neutral host for a Y web module.
//
// This is the Linux kernel side of the web target:
// it reads the yweb section, checks the ABI, builds the initial stack, owns
// the context and the green-thread scheduler, and implements the syscalls and
// host calls.  It imports nothing from Node: the file system is vfs.js over a
// backend (Node fs in node mode, memfs.js in a browser), stdio and pacing come
// from opts/stdout, and the CLI lives in yhost.js.

import {
  ABI_VERSION, AT, AT_NULL, AT_PAGESZ, AT_RANDOM, CLOCK, CLONE, CTX, CTX_SIZE,
  E, EFD, F, FD_CLOEXEC, FUTEX, MAP, MFD, O, PAGE_SIZE, POLL, REG, RENAME, SEEK,
  S_IFCHR, S_IFDIR, S_IFIFO, S_IFLNK, S_IFMT, S_IFREG, SIG, STAT, STATX,
  STATX_BASIC_STATS, SYS, TFD, UTS_FIELD, UTS_SIZE, WHY, Y_SYS,
  ctxSetU64, decodeToken, encodeToken,
} from './abi.js';
import { Vfs, basename, normalizePath, encode as utf8Encode, decode as utf8Decode } from './vfs.js';
import { Scheduler, YWhy, YTrap, sleepSync } from './sched.js';
import { U8, randomBytes } from './bytes.js';

// A slice of the event loop. MessageChannel is spelled the same in a browser
// and in Node 22 and has no setTimeout clamp (S9's pacing).
let yieldChannel = null;
let yieldQueue = [];
function defaultYieldLoop() {
  if (typeof MessageChannel !== 'function') {
    return new Promise((resolve) => setTimeout(resolve, 0));
  }
  if (yieldChannel === null) {
    yieldChannel = new MessageChannel();
    yieldChannel.port1.onmessage = () => {
      const q = yieldQueue;
      yieldQueue = [];
      for (const resolve of q) resolve();
    };
  }
  return new Promise((resolve) => {
    yieldQueue.push(resolve);
    yieldChannel.port2.postMessage(0);
  });
}

const UTF8 = new TextEncoder();
const UTF8_STRICT = new TextDecoder('utf-8', { fatal: true });

export class HostError extends Error {
  constructor(message) {
    super(message);
    this.name = 'HostError';
  }
}

function cstr(bytes) {
  return utf8Decode(bytes);
}

// ---------------------------------------------------------------------------
// Minimal wasm binary reader: sections, LEB128, names, the yweb section.
// The engine parses the module itself; this is only for the metadata the host
// must trust before it runs anything.
// ---------------------------------------------------------------------------

export function readULEB(bytes, pos, end = bytes.length) {
  let value = 0;
  let shift = 0;
  let p = pos;
  for (;;) {
    if (p >= end) throw new HostError('truncated LEB128');
    const b = bytes[p++];
    value += (b & 0x7f) * 2 ** shift;
    if ((b & 0x80) === 0) break;
    shift += 7;
    if (shift > 49) throw new HostError('LEB128 value is too large');
  }
  return { value, next: p };
}

export function readSLEB(bytes, pos, end = bytes.length) {
  let value = 0n;
  let shift = 0n;
  let p = pos;
  for (;;) {
    if (p >= end) throw new HostError('truncated LEB128');
    const b = bytes[p++];
    value |= BigInt(b & 0x7f) << shift;
    if ((b & 0x80) === 0) {
      if ((b & 0x40) !== 0) value -= 1n << (shift + 7n);
      break;
    }
    shift += 7n;
    if (shift > 70n) throw new HostError('SLEB128 value is too large');
  }
  return { value, next: p };
}

export function readName(bytes, pos, end = bytes.length) {
  const len = readULEB(bytes, pos, end);
  const stop = len.next + len.value;
  if (stop > end) throw new HostError('name extends past its section');
  return { value: cstr(bytes.subarray(len.next, stop)), next: stop };
}

export function parseSections(bytes) {
  if (!(bytes instanceof Uint8Array)) bytes = new Uint8Array(bytes);
  if (bytes.length < 8) throw new HostError('module is shorter than the wasm header');
  if (bytes[0] !== 0x00 || bytes[1] !== 0x61 || bytes[2] !== 0x73 || bytes[3] !== 0x6d) {
    throw new HostError('not a wasm module (bad magic)');
  }
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const version = dv.getUint32(4, true);
  if (version !== 1) throw new HostError('unsupported wasm version ' + version);
  const out = [];
  let pos = 8;
  while (pos < bytes.length) {
    const id = bytes[pos++];
    const size = readULEB(bytes, pos);
    pos = size.next;
    const payloadStart = pos;
    const payloadEnd = pos + size.value;
    if (payloadEnd > bytes.length) throw new HostError('section extends past the end of the module');
    out.push({ id, size: size.value, payloadStart, payloadEnd });
    pos = payloadEnd;
  }
  return out;
}

export function findCustomSection(bytes, name) {
  if (!(bytes instanceof Uint8Array)) bytes = new Uint8Array(bytes);
  for (const sec of parseSections(bytes)) {
    if (sec.id !== 0) continue;
    const got = readName(bytes, sec.payloadStart, sec.payloadEnd);
    if (got.value === name) return bytes.subarray(got.next, sec.payloadEnd);
  }
  return null;
}

export function parseYweb(text) {
  const kv = Object.create(null);
  for (let line of String(text).split(/\r?\n/)) {
    if (line === '') continue;
    if (line[0] === '#') continue;
    const eq = line.indexOf('=');
    if (eq <= 0) throw new HostError('malformed yweb line: ' + JSON.stringify(line));
    const key = line.slice(0, eq).trim();
    if (key === '') throw new HostError('empty yweb key');
    kv[key] = line.slice(eq + 1).trim();
  }
  return kv;
}

export function readYweb(bytes) {
  const payload = findCustomSection(bytes, 'yweb');
  if (payload === null) return null;
  return parseYweb(UTF8_STRICT.decode(payload));
}

// The -g name section: function index -> name.  Used for diagnostics only.
export function readNameSection(bytes) {
  const payload = findCustomSection(bytes, 'name');
  if (payload === null) return null;
  let pos = 0;
  let moduleName = null;
  const functions = new Map();
  while (pos < payload.length) {
    const id = payload[pos++];
    const size = readULEB(payload, pos, payload.length);
    pos = size.next;
    const end = pos + size.value;
    if (end > payload.length) throw new HostError('name subsection extends past the section');
    if (id === 1) {
      moduleName = readName(payload, pos, end).value;
    } else if (id === 2) {
      let p = pos;
      const count = readULEB(payload, p, end);
      p = count.next;
      for (let i = 0; i < count.value; i++) {
        const idx = readULEB(payload, p, end);
        p = idx.next;
        const nm = readName(payload, p, end);
        p = nm.next;
        functions.set(idx.value, nm.value);
      }
    }
    pos = end;
  }
  return { moduleName, functions };
}

export function readMemoryMin(bytes) {
  const sec = parseSections(bytes).find((s) => s.id === 5);
  if (!sec) return null;
  let pos = sec.payloadStart;
  const count = readULEB(bytes, pos, sec.payloadEnd);
  pos = count.next;
  if (count.value === 0) return null;
  const flags = readULEB(bytes, pos, sec.payloadEnd);
  pos = flags.next;
  const min = readULEB(bytes, pos, sec.payloadEnd);
  pos = min.next;
  let max = null;
  if ((flags.value & 1) !== 0) {
    const m = readULEB(bytes, pos, sec.payloadEnd);
    max = m.value;
  }
  return { count: count.value, min: min.value, max };
}

// ---------------------------------------------------------------------------
// Validation.  Run mode calls this before instantiation; validate mode prints
// it.  Every check here is something the host must not guess (R10).
// ---------------------------------------------------------------------------

function decField(kv, key, errors) {
  const raw = kv[key];
  if (raw === undefined) {
    errors.push('yweb is missing ' + key);
    return null;
  }
  if (!/^(0|[1-9][0-9]*)$/.test(raw)) {
    errors.push('yweb ' + key + ' is not a decimal integer: ' + JSON.stringify(raw));
    return null;
  }
  const n = Number(raw);
  if (!Number.isSafeInteger(n)) {
    errors.push('yweb ' + key + ' is not a safe integer: ' + raw);
    return null;
  }
  return n;
}

export function validateModule(input) {
  const errors = [];
  let bytes;
  try {
    bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  } catch (e) {
    return { ok: false, errors: ['module bytes are not a Uint8Array: ' + e.message], info: null };
  }

  let module;
  try {
    module = new WebAssembly.Module(bytes);
  } catch (e) {
    return { ok: false, errors: ['not valid wasm: ' + e.message], info: null };
  }

  let sections;
  try {
    sections = parseSections(bytes);
  } catch (e) {
    return { ok: false, errors: [e.message], info: null };
  }

  let kv = null;
  try {
    kv = readYweb(bytes);
  } catch (e) {
    errors.push(e.message);
  }
  if (kv === null) errors.push('missing custom section "yweb"');

  const info = {
    abi: null,
    chunks: null,
    stackLo: null,
    stackHi: null,
    dataLo: null,
    dataEnd: null,
    heapLo: null,
    entry: null,
    entryChunk: null,
    entryCase: null,
    threads: null,
    gui: null,
    audio: null,
    memoryMin: null,
    hasSetWhy: false,
    protocol: null,
    names: null,
    hasYsrc: false,
    sections: sections.length,
  };

  if (kv !== null) {
    if (kv.abi === undefined) {
      errors.push('yweb is missing abi');
    } else if (kv.abi !== String(ABI_VERSION)) {
      errors.push('abi mismatch: module says ' + kv.abi + ', host supports ' + ABI_VERSION);
    } else {
      info.abi = ABI_VERSION;
    }

    const stackLo = decField(kv, 'stack_lo', errors);
    const stackHi = decField(kv, 'stack_hi', errors);
    const dataLo = decField(kv, 'data_lo', errors);
    const dataEnd = decField(kv, 'data_end', errors);
    const heapLo = decField(kv, 'heap_lo', errors);
    const entryN = decField(kv, 'entry', errors);
    const chunks = decField(kv, 'chunks', errors);
    const threads = decField(kv, 'threads', errors);
    const gui = decField(kv, 'gui', errors);
    const audio = decField(kv, 'audio', errors);

    info.stackLo = stackLo;
    info.stackHi = stackHi;
    info.dataLo = dataLo;
    info.dataEnd = dataEnd;
    info.heapLo = heapLo;
    info.chunks = chunks;
    info.threads = threads;
    info.gui = gui;
    info.audio = audio;

    if (stackLo !== null && stackLo !== 0) {
      errors.push('stack_lo must be 0 (D6 puts the stack at address 0), got ' + stackLo);
    }
    if (stackHi !== null) {
      if (stackHi <= 0 || stackHi > 2 ** 32) errors.push('stack_hi is out of range: ' + stackHi);
      if (stackHi % 8 !== 0) errors.push('stack_hi is not 8-byte aligned: ' + stackHi);
    }
    if (stackLo !== null && stackHi !== null && stackHi <= stackLo) {
      errors.push('stack_hi must be above stack_lo');
    }
    if (dataLo !== null && stackHi !== null && dataLo < stackHi) {
      errors.push('data_lo is below stack_hi (S3 places data at STACK_HI)');
    }
    if (dataLo !== null && dataEnd !== null && dataEnd < dataLo) {
      errors.push('data_end is below data_lo');
    }
    if (dataEnd !== null && heapLo !== null && heapLo < dataEnd) {
      errors.push('heap_lo is below data_end');
    }
    if (heapLo !== null) {
      if (heapLo % 65536 !== 0) errors.push('heap_lo is not a multiple of 64 KiB: ' + heapLo);
      if (heapLo > 2 ** 32) errors.push('heap_lo is above the wasm32 address space');
    }
    if (chunks !== null && (chunks < 1 || chunks > 2 ** 20)) {
      errors.push('chunks is outside 1..2^20: ' + chunks);
    }
    for (const key of ['threads', 'gui', 'audio']) {
      const v = info[key];
      if (v !== null && v !== 0 && v !== 1) errors.push('yweb ' + key + ' must be 0 or 1, got ' + v);
    }
    if (entryN !== null) {
      const tok = decodeToken(entryN);
      if (tok === null) {
        errors.push('entry is not a code token (2^40 + chunk<<20 + case): ' + entryN);
      } else {
        info.entry = BigInt(entryN);
        info.entryChunk = tok.chunk;
        info.entryCase = tok.case;
        if (chunks !== null && tok.chunk >= chunks) {
          errors.push('entry chunk ' + tok.chunk + ' is beyond chunks=' + chunks);
        }
      }
    }
  }

  let mem = null;
  try {
    mem = readMemoryMin(bytes);
  } catch (e) {
    errors.push('bad memory section: ' + e.message);
  }
  if (mem === null) {
    errors.push('module defines no memory');
  } else {
    info.memoryMin = mem.min;
    if (info.dataEnd !== null) {
      if (info.dataEnd > 2 ** 32) {
        errors.push('data_end is above the wasm32 address space');
      } else {
        const need = Math.ceil((info.dataEnd + 1024 * 1024) / 65536);
        if (mem.min < need) {
          errors.push('memory minimum is ' + mem.min + ' pages, ABI 1 needs ' + need + ' (data_end + 1 MiB)');
        }
        if (mem.min * 65536 < info.dataEnd) {
          errors.push('memory minimum does not cover data_end');
        }
      }
    }
  }

  let wasmImports = [];
  let wasmExports = [];
  try {
    wasmImports = WebAssembly.Module.imports(module);
    wasmExports = WebAssembly.Module.exports(module);
  } catch (e) {
    errors.push('cannot read the import/export tables: ' + e.message);
  }

  const wanted = new Map([
    ['y.sys', 'function'],
    ['y.trap', 'function'],
  ]);
  for (const im of wasmImports) {
    const q = im.module + '.' + im.name;
    if (wanted.has(q)) {
      if (im.kind !== wanted.get(q)) errors.push('import ' + q + ' has kind ' + im.kind + ', want ' + wanted.get(q));
      wanted.delete(q);
    } else {
      errors.push('unexpected import ' + q + ' (ABI 1 imports only y.sys and y.trap)');
    }
  }
  for (const q of wanted.keys()) errors.push('missing import ' + q);

  const exp = new Map(wasmExports.map((e) => [e.name, e]));
  const requiredExports = [
    ['memory', 'memory'],
    ['resume', 'function'],
    ['ctx_save', 'function'],
    ['ctx_load', 'function'],
    ['set_fuel', 'function'],
    ['why', 'function'],
  ];
  for (const pair of requiredExports) {
    const found = exp.get(pair[0]);
    if (!found) errors.push('missing export ' + pair[0]);
    else if (found.kind !== pair[1]) errors.push('export ' + pair[0] + ' has kind ' + found.kind + ', want ' + pair[1]);
  }
  const setWhy = exp.get('set_why');
  if (setWhy && setWhy.kind !== 'function') errors.push('export set_why is not a function');
  info.hasSetWhy = !!setWhy && setWhy.kind === 'function';
  info.protocol = info.hasSetWhy ? 'set_why' : 'throw';

  try {
    info.names = readNameSection(bytes);
  } catch (e) {
    errors.push('bad name section: ' + e.message);
  }
  try {
    info.hasYsrc = findCustomSection(bytes, 'ysrc') !== null;
  } catch (e) {
    errors.push('bad ysrc section: ' + e.message);
  }

  return { ok: errors.length === 0, errors, info, module, bytes };
}

// ---------------------------------------------------------------------------
// Appendix B: the Linux initial stack.
//
// rsp -> argc, argv[0..argc-1], 0, envp[0..n-1], 0,
//        auxv {AT_PAGESZ,4096}, {AT_RANDOM,ptr}, {AT_NULL,0}
//        ... strings and 16 random bytes, below stack_hi.
// ---------------------------------------------------------------------------

export function buildInitialStack(memory, opts = {}) {
  const top = opts.top;
  const argv = (opts.argv || []).map(String);
  const env = (opts.env || []).map(String);
  if (!Number.isInteger(top) || top <= 0 || top > 2 ** 32) {
    throw new HostError('stack_hi is out of range: ' + top);
  }
  const buffer = memory.buffer;
  if (top > buffer.byteLength) throw new HostError('stack_hi is beyond the initial memory');
  const u8 = new Uint8Array(buffer);
  let pos = top;

  let random;
  if (opts.random === undefined || opts.random === null) {
    random = new Uint8Array(16);
    random.set(randomBytes(random.length));
  } else {
    random = Uint8Array.from(opts.random);
  }
  if (random.length !== 16) throw new HostError('AT_RANDOM needs exactly 16 bytes');
  pos -= random.length;
  u8.set(random, pos);
  const randomPtr = pos;

  const writeString = (s) => {
    const b = UTF8.encode(s);
    pos -= b.length + 1;
    if (pos < 0) throw new HostError('initial stack overflows the stack region');
    u8.set(b, pos);
    u8[pos + b.length] = 0;
    return pos;
  };

  const argvPtrs = argv.map(writeString);
  const envPtrs = env.map(writeString);

  pos = Math.floor(pos / 8) * 8;
  const words = 1 + (argv.length + 1) + (env.length + 1) + 6;
  const rsp = Math.floor((pos - words * 8) / 16) * 16;
  if (rsp < 16 || rsp >= pos) throw new HostError('initial stack does not fit below stack_hi');

  const dv = new DataView(buffer);
  let p = rsp;
  const put = (v) => {
    dv.setBigUint64(p, BigInt(v), true);
    p += 8;
  };
  put(argv.length);
  for (const ptr of argvPtrs) put(ptr);
  put(0);
  for (const ptr of envPtrs) put(ptr);
  put(0);
  const auxvPtr = p;
  put(AT_PAGESZ);
  put(PAGE_SIZE);
  put(AT_RANDOM);
  put(randomPtr);
  put(AT_NULL);
  put(0);

  return {
    rsp,
    argc: argv.length,
    envc: env.length,
    argvPtrs,
    envPtrs,
    auxvPtr,
    randomPtr,
    stringsStart: pos,
  };
}

// ---------------------------------------------------------------------------
// Anonymous mmap over the wasm heap.  The thread context(s) are the first
// kernel-private pages, so a program's mmap can never land on one.
// ---------------------------------------------------------------------------

class MmapAllocator {
  constructor(memory, base) {
    this.memory = memory;
    this.base = Math.ceil(base / PAGE_SIZE) * PAGE_SIZE;
    this.allocs = [];
  }

  growTo(end) {
    const have = this.memory.buffer.byteLength;
    if (end <= have) return true;
    const pages = Math.ceil((end - have) / 65536);
    try {
      return this.memory.grow(pages) !== -1;
    } catch (e) {
      return false;
    }
  }

  _coalesce() {
    this.allocs.sort((x, y) => x.start - y.start);
    const out = [];
    for (const r of this.allocs) {
      const last = out[out.length - 1];
      if (last && last.end === r.start && last.tag === r.tag) last.end = r.end;
      else out.push(r);
    }
    this.allocs = out;
  }

  alloc(size, align = PAGE_SIZE, tag = 'anon') {
    const n = Math.max(PAGE_SIZE, Math.ceil(Math.max(1, size) / PAGE_SIZE) * PAGE_SIZE);
    const a = Math.max(PAGE_SIZE, align | 0);
    let at = this.base;
    for (const r of this.allocs) {
      at = Math.ceil(at / a) * a;
      if (at + n <= r.start) break;
      if (r.end > at) at = Math.ceil(r.end / a) * a;
    }
    at = Math.ceil(at / a) * a;
    if (at + n > 2 ** 32) throw new HostError('mmap would leave the wasm32 address space');
    if (!this.growTo(at + n)) throw new HostError('out of memory growing the wasm heap');
    this.allocs.push({ start: at, end: at + n, tag });
    this._coalesce();
    new Uint8Array(this.memory.buffer, at, n).fill(0);
    return at;
  }

  // MAP_FIXED: replace whatever covers [addr, addr+size).
  allocAt(addr, size, tag = 'anon') {
    const n = Math.max(PAGE_SIZE, Math.ceil(Math.max(1, size) / PAGE_SIZE) * PAGE_SIZE);
    const start = Math.floor(addr / PAGE_SIZE) * PAGE_SIZE;
    const end = start + n;
    if (start < this.base || end > 2 ** 32) return -E.EINVAL;
    if (!this.growTo(end)) return -E.ENOMEM;
    const keep = [];
    for (const r of this.allocs) {
      if (r.end <= start || r.start >= end) {
        keep.push(r);
        continue;
      }
      if (r.start < start) keep.push({ start: r.start, end: start, tag: r.tag });
      if (r.end > end) keep.push({ start: end, end: r.end, tag: r.tag });
    }
    this.allocs = keep;
    this.allocs.push({ start, end, tag });
    this._coalesce();
    new Uint8Array(this.memory.buffer, start, n).fill(0);
    return start;
  }

  free(addr, len) {
    const end = addr + len;
    for (let i = 0; i < this.allocs.length; i++) {
      const r = this.allocs[i];
      if (addr < r.start || end > r.end) continue;
      this.allocs.splice(i, 1);
      if (addr > r.start) this.allocs.push({ start: r.start, end: addr, tag: r.tag });
      if (end < r.end) this.allocs.push({ start: end, end: r.end, tag: r.tag });
      this._coalesce();
      return true;
    }
    return false;
  }

  contains(addr, len) {
    const end = addr + len;
    for (const r of this.allocs) {
      if (addr >= r.start && end <= r.end) return r;
    }
    return null;
  }

  ranges() {
    return this.allocs.map((r) => ({ start: r.start, end: r.end, perms: 'rw-p', tag: r.tag }));
  }

  bytesAllocated() {
    let n = 0;
    for (const r of this.allocs) n += r.end - r.start;
    return n;
  }
}

// ---------------------------------------------------------------------------
// The process: one module instance, one vfs, one fd table, env/argv, cwd.
// ---------------------------------------------------------------------------

export function normalizeEnv(env) {
  if (Array.isArray(env)) return env.map(String);
  const out = [];
  const obj = env || {};
  for (const k of Object.keys(obj).sort()) {
    if (obj[k] !== undefined) out.push(k + '=' + obj[k]);
  }
  return out;
}

function toNumber(v) {
  if (typeof v === 'bigint') {
    if (v >= -9007199254740991n && v <= 9007199254740991n) return Number(v);
    return Number(BigInt.asIntN(64, v));
  }
  return Number(v);
}

function writeStat(dv, st) {
  const u8 = new Uint8Array(dv.buffer, dv.byteOffset, STAT.SIZE_BYTES);
  u8.fill(0);
  dv.setBigUint64(STAT.DEV, BigInt(st.dev || 0), true);
  dv.setBigUint64(STAT.INO, BigInt(st.ino || 0), true);
  dv.setBigUint64(STAT.NLINK, BigInt(st.nlink || 0), true);
  dv.setUint32(STAT.MODE, (st.mode || 0) >>> 0, true);
  dv.setUint32(STAT.UID, (st.uid === undefined ? 1000 : st.uid) >>> 0, true);
  dv.setUint32(STAT.GID, (st.gid === undefined ? 1000 : st.gid) >>> 0, true);
  dv.setBigUint64(STAT.RDEV, BigInt(st.rdev || 0), true);
  dv.setBigInt64(STAT.SIZE, BigInt(Math.trunc(st.size || 0)), true);
  dv.setBigInt64(STAT.BLKSIZE, BigInt(st.blksize || PAGE_SIZE), true);
  dv.setBigInt64(STAT.BLOCKS, BigInt(st.blocks || Math.ceil((st.size || 0) / 512)), true);
  const putTime = (ms, off) => {
    const v = Math.max(0, Math.floor(ms || 0));
    dv.setBigInt64(off, BigInt(Math.floor(v / 1000)), true);
    dv.setBigInt64(off + 8, BigInt(Math.floor((v % 1000) * 1e6)), true);
  };
  putTime(st.atimeMs, STAT.ATIME);
  putTime(st.mtimeMs, STAT.MTIME);
  putTime(st.ctimeMs, STAT.CTIME);
}

export class Host {
  constructor(bytes, opts = {}) {
    const checked = validateModule(bytes);
    if (!checked.ok) {
      throw new HostError('invalid web module:\n  ' + checked.errors.join('\n  '));
    }
    this.info = checked.info;
    this.module = checked.module;
    this.bytes = checked.bytes;
    this.argv = (Array.isArray(opts.argv) && opts.argv.length ? opts.argv : ['a.out']).map(String);
    this.env = normalizeEnv(opts.env === undefined ? [] : opts.env);
    this.name = opts.name || basename(this.argv[0] || 'a.out');
    this.cwd = opts.cwd || '/';
    this.fuel = opts.fuel === undefined ? 1000000 : Number(opts.fuel);
    if (!Number.isInteger(this.fuel) || this.fuel < 1) {
      throw new HostError('fuel must be a positive integer');
    }
    this.trace = !!opts.trace;
    this.traced = new Set();
    this.exitStatus = 0;
    this.pendingWait = null;
    this.status = null;
    this.trapped = false;
    this.trapSignal = 0;
    this.asyncMode = false;
    this.platform = opts.platform || null;
    // The audio platform is installed by yhost.js/page.js; core
    // only routes the four private numbers here.  A host without one answers
    // 0/-ENOSYS exactly as W3 did.
    this.audio = opts.audio || null;
    this.hidden = false;
    this.hiddenAt = 0;
    this.hiddenWaiters = [];
    this.nextTid = 2;
    this.sliceMs = opts.sliceMs === undefined ? 8 : Number(opts.sliceMs);
    this.hrtimeBase = 0n;
    this.monoBaseMs = typeof performance?.now === 'function' ? performance.now() : Date.now();
    this.pausedMs = 0;
    this.hostFunctions = new Map();
    this.hostHandles = [null];
    this.stdout = opts.stdout || (() => {});
    this.stderr = opts.stderr || (() => {});
    this.exePath = opts.exePath || (this.argv[0] && this.argv[0].startsWith('/') ? this.argv[0] : '/app/' + this.name);
    this.vfs = opts.vfs || new Vfs({
      fs: opts.fs,
      store: opts.store,
      memfs: opts.memfs,
      cwd: this.cwd,
      argv: this.argv,
      env: this.env,
      name: this.name,
      exePath: this.exePath,
      stdout: this.stdout,
      stderr: this.stderr,
      stdin: opts.stdin,
      now: () => this.now(),
      maps: () => this.memoryRanges(),
      threads: () => (this.sched ? this.sched.liveCount() : 1),
      memoryPages: () => Math.floor((this.memory ? this.memory.buffer.byteLength : 0) / 65536),
    });

    this.memory = null;
    this.exports = null;
    this.instance = null;
    this.imports = {
      y: {
        sys: (...a) => this.sys(...a),
        trap: (sig) => {
          throw new YTrap(sig);
        },
      },
    };
    this.instance = new WebAssembly.Instance(this.module, this.imports);
    this.exports = this.instance.exports;
    this.memory = this.exports.memory;
    if (!(this.memory instanceof WebAssembly.Memory)) {
      throw new HostError('export "memory" is not a WebAssembly.Memory');
    }
    if (this.memory.buffer.byteLength < this.info.dataEnd) {
      throw new HostError('module memory is smaller than data_end');
    }
    this.hasSetWhy = this.info.hasSetWhy;
    this.mmap = new MmapAllocator(this.memory, this.info.heapLo);
    // Kernel-private context pages come from the mmap region before the
    // program can ask for any.
    this.scratchCtx = this.mmap.alloc(CTX_SIZE, 16, 'kernel');
    const stack = buildInitialStack(this.memory, {
      argv: this.argv,
      env: this.env,
      top: this.info.stackHi,
      random: opts.random,
    });
    this.stack = stack;
    this.mainThread = this.makeThread(this.info.entry, stack.rsp, 1);
    this.sched = new Scheduler(this, { fuel: this.fuel, trace: this.trace, sliceMs: this.sliceMs });
    this.sched.addThread(this.mainThread);
  }

  makeThread(pc, rsp, id) {
    const ctx = this.mmap.alloc(CTX_SIZE, 16, 'kernel');
    const bytes = new Uint8Array(CTX_SIZE);
    ctxSetU64(bytes, CTX.PC, pc);
    ctxSetU64(bytes, CTX.R4, BigInt(rsp));
    ctxSetU64(bytes, CTX.FS, 0n);
    this.writeMemory(ctx, bytes);
    return {
      id,
      ctx,
      pc,
      state: 'runnable',
      needsLoad: true,
      wait: null,
      ctid: 0,
      ownsCtx: true,
      exitCode: 0,
    };
  }

  // -- memory views (always fresh: a memory.grow detaches the old buffer) ----

  memoryBytes(ptr, len) {
    const buffer = this.memory.buffer;
    if (!Number.isInteger(ptr) || ptr < 0 || !Number.isInteger(len) || len < 0) return null;
    if (ptr + len > buffer.byteLength) return null;
    return new Uint8Array(buffer, ptr, len);
  }

  memoryDataView(ptr, len) {
    const buffer = this.memory.buffer;
    if (!Number.isInteger(ptr) || ptr < 0 || !Number.isInteger(len) || len < 0) return null;
    if (ptr + len > buffer.byteLength) return null;
    return new DataView(buffer, ptr, len);
  }

  writeMemory(ptr, bytes) {
    const view = this.memoryBytes(ptr, bytes.length);
    if (view === null) throw new HostError('host wrote outside wasm memory');
    view.set(bytes);
  }

  readCString(ptr) {
    if (!Number.isInteger(ptr) || ptr < 0 || ptr >= this.memory.buffer.byteLength) return null;
    const u8 = new Uint8Array(this.memory.buffer);
    const max = Math.min(u8.length, ptr + 4096);
    let end = ptr;
    while (end < max && u8[end] !== 0) end++;
    if (end >= max) return null;
    return utf8Decode(u8.subarray(ptr, end));
  }

  readCtxWord(thread, off) {
    const dv = new DataView(this.memory.buffer, thread.ctx, CTX_SIZE);
    return dv.getBigUint64(off, true);
  }

  writeCtxWord(thread, off, value) {
    const dv = new DataView(this.memory.buffer, thread.ctx, CTX_SIZE);
    dv.setBigUint64(off, BigInt.asUintN(64, BigInt(value)), true);
  }

  // -- the kernel interface used by sched.js --------------------------------

  resume(pc) {
    // $why is not part of the context, and the module checks it after every
    // syscall.  A module that exports set_why gets it cleared before the next
    // slice; a throwing module never sets it at all.
    if (this.hasSetWhy) this.exports.set_why(WHY.NONE);
    this.exports.resume(BigInt(pc));
  }

  why() {
    return toNumber(this.exports.why());
  }

  setFuel(n) {
    this.exports.set_fuel(n > 0x7fffffff ? 0x7fffffff : n | 0);
  }

  loadContext(thread) {
    this.exports.ctx_load(thread.ctx);
  }

  saveContext(thread) {
    this.exports.ctx_save(thread.ctx);
    const dv = new DataView(this.memory.buffer, thread.ctx, CTX_SIZE);
    thread.pc = dv.getBigUint64(CTX.PC, true);
  }

  // S8 step 5: the result goes into rax before the next ctx_load.
  applyWake(thread, result) {
    try {
      this.setCtxWord(thread.ctx, CTX.R0, result);
    } catch (e) {
      throw new HostError('wake result is not an i64: ' + String(result));
    }
    thread.needsLoad = true;
  }

  now() {
    if (this.hidden) return this.hiddenAt - this.pausedMs;
    return performance.now() - this.pausedMs;
  }

  // pause_hidden (S9): while the page is hidden CLOCK_MONOTONIC stands still
  // and the scheduler runs nothing.  CLOCK_REALTIME keeps moving.
  setHidden(hidden) {
    const flag = !!hidden;
    if (flag === this.hidden) return;
    const t = performance.now();
    if (flag) {
      this.hidden = true;
      this.hiddenAt = t;
    } else {
      this.pausedMs += Math.max(0, t - this.hiddenAt);
      this.hidden = false;
      const waiters = this.hiddenWaiters;
      this.hiddenWaiters = [];
      for (const resolve of waiters) resolve();
    }
    if (this.audio && typeof this.audio.setHidden === 'function') {
      try { this.audio.setHidden(flag); } catch (e) { /* audio is optional */ }
    }
    if (this.platform && typeof this.platform.onHidden === 'function') {
      try { this.platform.onHidden(flag); } catch (e) { /* audio is optional */ }
    }
  }

  isPaused() {
    return this.hidden;
  }

  async waitUnpaused() {
    if (!this.hidden) return;
    await new Promise((resolve) => this.hiddenWaiters.push(resolve));
  }

  monoNs() {
    // One origin for CLOCK_MONOTONIC, the scheduler's deadlines and
    // CLOCK_NANOSLEEP(TIMER_ABSTIME): performance.now()'s.
    return BigInt(Math.floor(this.now() * 1e6));
  }

  realtimeNs() {
    return BigInt(Date.now()) * 1000000n;
  }

  sleepUntil(deadline) {
    const ms = deadline - this.now();
    if (!(ms > 0)) return;
    if (this.platform && typeof this.platform.sleepSync === 'function') this.platform.sleepSync(ms);
    else sleepSync(ms);
  }

  async sleepUntilAsync(deadline) {
    const ms = deadline - this.now();
    if (ms <= 0) return;
    await new Promise((resolve) => setTimeout(resolve, Math.ceil(ms)));
  }

  async yieldLoop() {
    if (this.platform && typeof this.platform.yieldLoop === 'function') await this.platform.yieldLoop();
    else await defaultYieldLoop();
  }

  ctxWord(ctxAddr, off) {
    if (this.memoryBytes(ctxAddr, CTX_SIZE) === null) return 0n;
    const dv = new DataView(this.memory.buffer, ctxAddr, CTX_SIZE);
    return dv.getBigUint64(off, true);
  }

  setCtxWord(ctxAddr, off, value) {
    const view = this.memoryBytes(ctxAddr, CTX_SIZE);
    if (view === null) throw new HostError('thread context is outside wasm memory');
    const dv = new DataView(view.buffer, view.byteOffset, CTX_SIZE);
    dv.setBigUint64(off, BigInt.asUintN(64, BigInt(value)), true);
  }

  // Wake every blocked thread that is waiting on one futex address.
  futexWake(addr, count = 0x7fffffff, bitset = 0) {
    let n = 0;
    for (const t of this.sched.threads) {
      if (n >= count) break;
      if (t.state !== 'blocked' || !t.wait || t.wait.kind !== 'futex') continue;
      if (t.wait.addr !== addr) continue;
      if (bitset !== 0 && (t.wait.bitset & bitset) === 0) continue;
      if (this.sched.wakeThread(t, 0n)) n++;
    }
    if (n > 0) this.sched.serviceWaits();
    return n;
  }

  // Move waiters from one futex word to another (FUTEX_REQUEUE).
  futexRequeue(addr, fromAddr, count2, bitset = 0) {
    let n = 0;
    for (const t of this.sched.threads) {
      if (n >= count2) break;
      if (t.state !== 'blocked' || !t.wait || t.wait.kind !== 'futex') continue;
      if (t.wait.addr !== fromAddr) continue;
      if (bitset !== 0 && (t.wait.bitset & bitset) === 0) continue;
      t.wait.addr = addr;
      n++;
    }
    return n;
  }

  futexWaiters(addr) {
    let n = 0;
    for (const t of this.sched.threads) {
      if (t.state !== 'blocked' || !t.wait || t.wait.kind !== 'futex') continue;
      if (t.wait.addr === addr) n++;
    }
    return n;
  }

  notifyFd() {
    if (this.sched) this.sched.serviceWaits();
  }

  threadExit(thread) {
    if (thread.ctid) {
      const view = this.memoryBytes(thread.ctid, 4);
      if (view !== null) view.fill(0);
      this.futexWake(thread.ctid, 0x7fffffff);
    }
    if (thread.ownsCtx && thread !== this.mainThread) {
      try {
        this.mmap.free(thread.ctx, PAGE_SIZE);
      } catch (e) {
        /* the context page is gone with the process */
      }
      thread.ownsCtx = false;
    }
    this.notifyFd();
  }

  // Address ranges for /proc/self/maps (S9).
  memoryRanges() {
    const ranges = [];
    if (this.info.stackHi > 0) {
      ranges.push({ start: 0, end: this.info.stackHi, perms: 'rw-p', name: '[stack]' });
    }
    if (this.info.dataEnd > this.info.stackHi) {
      ranges.push({ start: this.info.stackHi, end: this.info.dataEnd, perms: 'r--p', name: this.exePath });
    }
    if (this.info.heapLo > this.info.dataEnd) {
      ranges.push({ start: this.info.dataEnd, end: this.info.heapLo, perms: 'rw-p', name: '[heap]' });
    }
    for (const r of this.mmap.ranges()) {
      const name = r.tag === 'kernel' ? '[yhost]' : r.tag === 'stack' ? '[stack]' : '[anon]';
      ranges.push({ start: r.start, end: r.end, perms: 'rw-p', name });
    }
    ranges.sort((a, b) => a.start - b.start);
    return ranges;
  }

  // -- host calls (Appendix C), the scaffolding std/web will use -------------

  register(name, fn) {
    if (typeof name !== 'string' || name === '') throw new HostError('host function name must be non-empty');
    if (typeof fn !== 'function') throw new HostError('host function ' + name + ' is not callable');
    if (this.hostFunctions.has(name)) throw new HostError('host function already registered: ' + name);
    const handle = this.hostHandles.length;
    this.hostHandles.push(fn);
    this.hostFunctions.set(name, handle);
    return handle;
  }

  hostSym(name) {
    const handle = this.hostFunctions.get(name);
    return handle === undefined ? 0 : handle;
  }

  yMem() {
    const host = this;
    return {
      str(ptr, len) {
        const b = host.memoryBytes(ptr, len);
        return b === null ? null : utf8Decode(b);
      },
      bytes(ptr, len) {
        const b = host.memoryBytes(ptr, len);
        return b === null ? null : Uint8Array.from(b);
      },
      write(ptr, byte) {
        const b = host.memoryBytes(ptr, 1);
        if (b === null) return false;
        b[0] = byte & 0xff;
        return true;
      },
      i64(ptr) {
        const dv = host.memoryDataView(ptr, 8);
        return dv === null ? null : dv.getBigInt64(0, true);
      },
      set64(ptr, value) {
        const dv = host.memoryDataView(ptr, 8);
        if (dv === null) return false;
        dv.setBigInt64(0, BigInt.asIntN(64, BigInt(value)), true);
        return true;
      },
    };
  }

  // -- run ------------------------------------------------------------------

  run() {
    let status;
    try {
      status = this.sched.run();
    } catch (e) {
      const message = e && e.message ? e.message : String(e);
      const stack = e && e.stack ? e.stack : '';
      const line = 'yhost: internal error: ' + message + '\n' + (stack ? stack + '\n' : '');
      try {
        this.vfs.write(2, utf8Encode(line));
      } catch (ignored) {
        /* stderr is gone; the status still reports the bug */
      }
      this.trapped = true;
      this.status = 134;
      return 134;
    }
    if (this.sched.message) {
      try {
        this.vfs.write(2, utf8Encode(this.sched.message + '\n'));
      } catch (ignored) {
        /* see above */
      }
    }
    this.status = status & 255;
    return this.status;
  }

  // S9's event-loop pacing: the async loop yields between slices so timers and
  // host promises can settle (MessageChannel in the page, setImmediate in Node).
  async runAsync() {
    this.asyncMode = true;
    let status;
    try {
      status = await this.sched.runAsync();
    } catch (e) {
      const message = e && e.message ? e.message : String(e);
      const stack = e && e.stack ? e.stack : '';
      const line = 'yhost: internal error: ' + message + '\n' + (stack ? stack + '\n' : '');
      try {
        this.vfs.write(2, utf8Encode(line));
      } catch (ignored) {
        /* stderr is gone; the status still reports the bug */
      }
      this.trapped = true;
      this.status = 134;
      return 134;
    }
    if (this.sched.message) {
      try {
        this.vfs.write(2, utf8Encode(this.sched.message + '\n'));
      } catch (ignored) {
        /* see above */
      }
    }
    this.status = status & 255;
    return this.status;
  }

  // -- yield / exit requests ------------------------------------------------

  // exit_group(status): the whole process.  exit(status): this thread; when it
  // is the last one the process ends with its status (Linux semantics).
  requestExit(status, group = true) {
    const st = status & 255;
    const t = this.sched.current;
    if (!group && t && this.sched.liveCount() > 1) {
      t.exitCode = st;
      t.exitReason = 'exit';
      if (this.hasSetWhy) {
        this.exports.set_why(WHY.THREAD_EXIT);
        return 0;
      }
      throw new YWhy(WHY.THREAD_EXIT);
    }
    this.exitStatus = st;
    if (t) {
      t.exitCode = st;
      t.exitReason = group ? 'group' : 'exit';
    }
    if (this.hasSetWhy) {
      this.exports.set_why(WHY.EXIT);
      return 0;
    }
    throw new YWhy(WHY.EXIT, { status: st });
  }

  requestWhy(reason, opts) {
    this.pendingWait = opts && opts.wait !== undefined ? opts.wait : null;
    if (this.hasSetWhy) {
      this.exports.set_why(reason);
      return 0;
    }
    // Without a set_why export the import throws, so the post-syscall
    // register/flag sync of S8 step 4 does not run.  Recreate it from a
    // context snapshot before unwinding: rax = placeholder, rcx = $pc,
    // r11 = 0, as the x86 syscall convention promises.
    if (reason !== WHY.EXIT) this.setYieldResult(0n);
    throw new YWhy(reason, opts || {});
  }

  setYieldResult(result) {
    const t = this.sched.current;
    if (!t) return;
    this.saveContext(t);
    this.writeCtxWord(t, CTX.R0, result);
    this.writeCtxWord(t, CTX.R1, t.pc);
    this.writeCtxWord(t, CTX.R11, 0n);
    this.loadContext(t);
  }

  // Park the current thread on a wait object; returns the placeholder result.
  block(wait) {
    return this.requestWhy(WHY.BLOCK, { wait });
  }

  // -- syscalls -------------------------------------------------------------

  sys(nrArg, ...args) {
    const nr = toNumber(nrArg);
    const a = args.map(toNumber);
    const r = this.dispatch(nr, a);
    if (typeof r === 'bigint') return r;
    const n = Number(r);
    if (!Number.isFinite(n)) throw new Error('syscall ' + nr + ' returned ' + String(r));
    return BigInt(Math.trunc(n));
  }

  unimplemented(nr) {
    if (this.trace && !this.traced.has(nr)) {
      this.traced.add(nr);
      this.vfs.write(2, utf8Encode('yhost: unimplemented syscall ' + nr + '\n'));
    }
    return -E.ENOSYS;
  }

  // Every syscall S9 lists for Node is here.  Still refused, with the errno a
  // program expects: fork/exec (ENOSYS), wait4 (ECHILD), sockets
  // (EAFNOSUPPORT/ENOTSOCK), epoll/inotify (ENOSYS), ptrace (EPERM), and every
  // number not in the Linux table (ENOSYS).
  dispatch(nr, a) {
    switch (nr) {
      // -- files, descriptors ------------------------------------------------
      case SYS.read:
        return this.sysRead(a[0], a[1], a[2]);
      case SYS.write:
        return this.sysWrite(a[0], a[1], a[2]);
      case SYS.open:
        return this.sysOpen(a[0], a[1], a[2]);
      case SYS.openat:
        return this.sysOpenat(a[0], a[1], a[2], a[3]);
      case SYS.close: {
        const r = this.vfs.close(a[0]);
        this.notifyFd();
        return r;
      }
      case SYS.lseek:
        return this.vfs.lseek(a[0], a[1], a[2]);
      case SYS.stat:
        return this.sysStat(a[0], a[1], true);
      case SYS.lstat:
        return this.sysStat(a[0], a[1], false);
      case SYS.fstat:
        return this.sysFstat(a[0], a[1]);
      case SYS.newfstatat:
        return this.sysNewfstatat(a[0], a[1], a[2], a[3]);
      case SYS.statx:
        return this.sysStatx(a[0], a[1], a[2], a[3], a[4]);
      case SYS.access:
        return this.sysAccess(a[0], a[1]);
      case SYS.faccessat:
        return this.sysFaccessat(a[0], a[1], a[2], a[3]);
      case SYS.getdents64:
      case SYS.getdents:
        return this.sysGetdents(a[0], a[1], a[2]);
      case SYS.pread64:
        return this.sysPread(a[0], a[1], a[2], a[3]);
      case SYS.pwrite64:
        return this.sysPwrite(a[0], a[1], a[2], a[3]);
      case SYS.readv:
        return this.sysReadv(a[0], a[1], a[2]);
      case SYS.writev:
        return this.sysWritev(a[0], a[1], a[2]);
      case SYS.truncate:
        return this.sysTruncate(a[0], a[1]);
      case SYS.ftruncate:
        return this.vfs.ftruncate(a[0], a[1]);
      case SYS.dup:
        return this.vfs.dup(a[0], 3, false);
      case SYS.dup2:
        return this.vfs.dup2(a[0], a[1], false);
      case SYS.dup3:
        if (a[0] === a[1]) return -E.EINVAL;
        return this.vfs.dup2(a[0], a[1], (a[2] & O.CLOEXEC) !== 0);
      case SYS.pipe:
        return this.sysPipe(a[0], 0);
      case SYS.pipe2:
        return this.sysPipe(a[0], a[1]);
      case SYS.fcntl:
        return this.sysFcntl(a[0], a[1], a[2]);
      case SYS.ioctl:
        return this.sysIoctl(a[0], a[1], a[2]);
      case SYS.flock:
        return 0;
      case SYS.fsync:
      case SYS.fdatasync:
        return this.sysSync(a[0]);
      case SYS.memfd_create:
        return this.sysMemfd(a[0], a[1]);
      case SYS.eventfd:
        return this.vfs.eventfd(a[0], 0);
      case SYS.eventfd2:
        return this.vfs.eventfd(a[0], a[1]);
      case SYS.timerfd_create:
        return this.vfs.timerfd(a[0], a[1]);
      case SYS.timerfd_settime:
        return this.sysTimerfdSettime(a[0], a[1], a[2], a[3]);
      case SYS.timerfd_gettime:
        return this.sysTimerfdGettime(a[0], a[1]);

      // -- path mutation and lookup -----------------------------------------
      case SYS.getcwd:
        return this.sysGetcwd(a[0], a[1]);
      case SYS.chdir:
        return this.sysChdir(a[0]);
      case SYS.fchdir:
        return this.vfs.fchdir(a[0]);
      case SYS.mkdir:
        return this.sysMkdir(AT.FDCWD, a[0], a[1]);
      case SYS.mkdirat:
        return this.sysMkdir(a[0], a[1], a[2]);
      case SYS.rmdir:
        return this.sysRmdir(a[0]);
      case SYS.unlink:
        return this.sysUnlink(AT.FDCWD, a[0], 0);
      case SYS.unlinkat:
        return this.sysUnlink(a[0], a[1], a[2]);
      case SYS.rename:
        return this.sysRename(AT.FDCWD, a[0], AT.FDCWD, a[1], 0);
      case SYS.renameat:
        return this.sysRename(a[0], a[1], a[2], a[3], 0);
      case SYS.renameat2:
        return this.sysRename(a[0], a[1], a[2], a[3], a[4]);
      case SYS.symlink:
        return this.sysSymlink(a[0], AT.FDCWD, a[1]);
      case SYS.symlinkat:
        return this.sysSymlink(a[0], a[1], a[2]);
      case SYS.readlink:
        return this.sysReadlink(a[0], a[1], a[2]);
      case SYS.readlinkat:
        return this.sysReadlinkat(a[0], a[1], a[2], a[3]);
      case SYS.chmod:
        return this.sysChmod(a[0], a[1], true);
      case SYS.fchmod:
        return this.vfs.fchmod(a[0], a[1]);
      case SYS.fchmodat:
        return this.sysFchmodat(a[0], a[1], a[2], a[3]);
      case SYS.chown:
        return this.sysChown(a[0], a[1], a[2], true);
      case SYS.lchown:
        return this.sysChown(a[0], a[1], a[2], false);
      case SYS.fchown:
        return this.sysFchown(a[0], a[1], a[2]);
      case SYS.fchownat:
        return this.sysFchownat(a[0], a[1], a[2], a[3], a[4]);
      case SYS.umask:
        return this.sysUmask(a[0]);

      // -- memory ------------------------------------------------------------
      case SYS.mmap:
        return this.sysMmap(a[0], a[1], a[2], a[3], a[4], a[5]);
      case SYS.munmap:
        return this.sysMunmap(a[0], a[1]);
      case SYS.mremap:
        return this.sysMremap(a[0], a[1], a[2], a[3], a[4]);
      case SYS.mprotect:
      case SYS.madvise:
      case SYS.msync:
      case SYS.mlock:
        return 0;
      case SYS.brk:
        return this.info.heapLo;

      // -- waiting -----------------------------------------------------------
      case SYS.poll:
        return this.sysPoll(a[0], a[1], a[2], false);
      case SYS.ppoll:
        return this.sysPoll(a[0], a[1], a[2], true, a[3]);
      case SYS.select:
        return this.sysSelect(a[0], a[1], a[2], a[3], a[4], false);
      case SYS.pselect6:
        return this.sysSelect(a[0], a[1], a[2], a[3], a[4], true, a[5]);

      // -- threads and time --------------------------------------------------
      case SYS.clone:
        return this.sysClone(a[0], a[1], a[2], a[3], a[4]);
      case SYS.clone3:
        return this.sysClone3(a[0], a[1]);
      case SYS.futex:
        return this.sysFutex(a[0], a[1], a[2], a[3], a[4], a[5]);
      case SYS.set_tid_address:
        return this.sysSetTidAddress(a[0]);
      case SYS.get_robust_list:
        return this.sysGetRobustList(a[1], a[2]);
      case SYS.set_robust_list:
        return 0;
      case SYS.gettid:
        return this.sched.current ? this.sched.current.id : 1;
      case SYS.getpid:
        return 1;
      case SYS.getppid:
        return 0;
      case SYS.getuid:
      case SYS.geteuid:
      case SYS.getgid:
      case SYS.getegid:
        return 1000;
      case SYS.getpgrp:
      case SYS.setsid:
        return 1;
      case SYS.sched_yield:
        this.requestWhy(WHY.YIELD);
        return 0;
      case SYS.exit:
        return this.requestExit(a[0], false);
      case SYS.exit_group:
        return this.requestExit(a[0], true);
      case SYS.kill:
        return this.sysKill(a[0], a[1]);
      case SYS.tkill:
        return this.sysKill(0, a[1]);
      case SYS.tgkill:
        return this.sysKill(a[1], a[2]);
      case SYS.arch_prctl:
        return this.sysArchPrctl(a[0], a[1]);
      case SYS.clock_gettime:
        return this.sysClockGettime(a[0], a[1]);
      case SYS.clock_getres:
        return this.sysClockGetres(a[0], a[1]);
      case SYS.clock_nanosleep:
        return this.sysClockNanosleep(a[0], a[1], a[2], a[3]);
      case SYS.nanosleep:
        return this.sysNanosleep(a[0], a[1]);
      case SYS.gettimeofday:
        return this.sysGettimeofday(a[0], a[1]);
      case SYS.time:
        return this.sysTime(a[0]);
      case SYS.times:
        return this.sysTimes(a[0]);
      case SYS.getrandom:
        return this.sysGetrandom(a[0], a[1], a[2]);
      case SYS.uname:
        return this.sysUname(a[0]);
      case SYS.sysinfo:
        return this.sysSysinfo(a[0]);
      case SYS.getrlimit:
        return this.sysGetrlimit(a[0], a[1]);
      case SYS.setrlimit:
        return 0;
      case SYS.prlimit64:
        return this.sysPrlimit64(a[0], a[1], a[2], a[3]);
      case SYS.getrusage:
        return this.sysZero(a[1], 144);

      // -- signals: accepted, never delivered (S9) ---------------------------
      case SYS.rt_sigaction:
      case SYS.rt_sigprocmask:
      case SYS.sigaltstack:
      case SYS.prctl:
        return 0;

      // -- refused exactly as S9 says ---------------------------------------
      case SYS.fork:
      case SYS.vfork:
      case SYS.execve:
      case SYS.execveat:
        return -E.ENOSYS;
      case SYS.wait4:
        return -E.ECHILD;
      case SYS.socket:
      case SYS.socketpair:
        return -E.EAFNOSUPPORT;
      case SYS.connect:
      case SYS.accept:
      case SYS.sendto:
      case SYS.recvfrom:
      case SYS.sendmsg:
      case SYS.recvmsg:
      case SYS.shutdown:
      case SYS.bind:
      case SYS.listen:
      case SYS.getsockname:
      case SYS.getpeername:
      case SYS.setsockopt:
      case SYS.getsockopt:
      case SYS.accept4:
        return -E.ENOTSOCK;
      case SYS.ptrace:
        return -E.EPERM;
      case SYS.epoll_wait:
      case SYS.epoll_ctl:
      case SYS.epoll_pwait:
      case SYS.epoll_create:
      case SYS.epoll_create1:
      case SYS.inotify_init:
      case SYS.inotify_init1:
        return -E.ENOSYS;

      // -- Appendix C private numbers ---------------------------------------
      case Y_SYS.HOST_SYM:
        return this.sysHostSym(a[0], a[1]);
      case Y_SYS.HOST_CALL:
        return this.sysHostCall(a[0], a[1], a[2]);
      case Y_SYS.AUDIO_DEVS:
        return this.audio ? this.audio.devs() : 0;
      case Y_SYS.AUDIO_OPEN:
        return this.audio ? this.audio.open(a[0], a[1]) : -E.ENOSYS;
      case Y_SYS.AUDIO_WRITE:
        return this.audio ? this.audio.write(a[0], a[1], a[2]) : -E.ENOSYS;
      case Y_SYS.AUDIO_CLOSE:
        return this.audio ? this.audio.close(a[0]) : -E.ENOSYS;
      default:
        return this.unimplemented(nr);
    }
  }

  sysRead(fd, ptr, count) {
    if (count < 0) return -E.EINVAL;
    if (count > 0x7ffff000) return -E.EINVAL;
    if (count === 0) return 0;
    if (this.memoryBytes(ptr, count) === null) return -E.EFAULT;
    const r = this.vfs.read(fd, count);
    if (typeof r === 'number') return r;
    if (r.block) return this.blockRead(fd, ptr, count, r.block);
    const view = this.memoryBytes(ptr, r.data.length);
    if (view === null) return -E.EFAULT;
    view.set(r.data);
    this.notifyFd();
    return r.data.length;
  }

  // Park a thread on a pipe/eventfd/timerfd read; the read is retried when the
  // wait object becomes ready and its length becomes rax (S8 step 5).
  blockRead(fd, ptr, count, block) {
    const wait = {
      kind: block.kind,
      pipe: block.pipe,
      eventfd: block.eventfd,
      timerfd: block.timerfd,
      ready: () => {
        if (block.kind === 'pipe-read') return block.pipe.len > 0 || block.pipe.writers === 0;
        if (block.kind === 'eventfd-read') return block.eventfd.count > 0n;
        if (block.kind === 'timerfd-read') return block.timerfd.due(this.now()) > 0;
        if (block.kind === 'stdin-console') return block.stdin.hasData() || block.stdin.eof;
        return false;
      },
      resume: () => {
        const rr = this.vfs.read(fd, count);
        if (typeof rr === 'number') return BigInt(rr);
        if (rr.block) return 0n;
        const view = this.memoryBytes(ptr, rr.data.length);
        if (view === null) return BigInt(-E.EFAULT);
        view.set(rr.data);
        this.notifyFd();
        return BigInt(rr.data.length);
      },
    };
    if (block.kind === 'timerfd-read' && Number.isFinite(block.timerfd.next)) wait.until = block.timerfd.next;
    if (block.kind === 'stdin-console' && typeof block.stdin.waitPromise === 'function') {
      wait.promise = block.stdin.waitPromise();
    }
    return this.block(wait);
  }

  sysWrite(fd, ptr, count) {
    if (count < 0) return -E.EINVAL;
    if (count > 0x7ffff000) return -E.EINVAL;
    if (count === 0) return 0;
    const view = this.memoryBytes(ptr, count);
    if (view === null) return -E.EFAULT;
    const r = this.vfs.write(fd, view);
    if (typeof r === 'number') {
      if (r >= 0) this.notifyFd();
      return r;
    }
    if (!r.block) return -E.EIO;
    const base = r.written || 0;
    if (r.block.kind === 'pipe-write') {
      const pipe = r.block.pipe;
      const rest = r.block.rest;
      const wait = {
        kind: 'pipe-write',
        pipe,
        ready: () => pipe.readers === 0 || pipe.len + rest.length <= pipe.capacity,
        resume: () => {
          const w = this.vfs.write(fd, rest);
          if (typeof w === 'number') {
            this.notifyFd();
            if (w < 0) return BigInt(base > 0 ? base : w);
            return BigInt(base + w);
          }
          return BigInt(-E.EAGAIN);
        },
      };
      return this.block(wait);
    }
    if (r.block.kind === 'eventfd-write') {
      const ev = r.block.eventfd;
      const wait = {
        kind: 'eventfd-write',
        eventfd: ev,
        ready: () => ev.count + r.block.value <= 0xfffffffffffffffen,
        resume: () => {
          const w = this.vfs.write(fd, view);
          if (typeof w === 'number') {
            this.notifyFd();
            return BigInt(w);
          }
          return BigInt(-E.EAGAIN);
        },
      };
      return this.block(wait);
    }
    return -E.EIO;
  }

  sysOpen(ptr, flags, mode) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    return this.vfs.open(path, flags, mode);
  }

  resolveAt(dirfd, path) {
    if (dirfd === AT.FDCWD) return path;
    const e = this.vfs.get(dirfd);
    if (!e || e.ofd.kind !== 'dir') return null;
    return normalizePath(e.ofd.path, path);
  }

  sysOpenat(dirfd, ptr, flags, mode) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    const abs = this.resolveAt(dirfd, path);
    if (abs === null) return -E.EBADF;
    return this.vfs.open(abs, flags, mode);
  }

  sysStat(ptr, out, follow) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    const st = this.vfs.stat(path, follow);
    if (typeof st === 'number') return st;
    const dv = this.memoryDataView(out, STAT.SIZE_BYTES);
    if (dv === null) return -E.EFAULT;
    writeStat(dv, st);
    return 0;
  }

  sysFstat(fd, out) {
    const st = this.vfs.fstat(fd);
    if (typeof st === 'number') return st;
    const dv = this.memoryDataView(out, STAT.SIZE_BYTES);
    if (dv === null) return -E.EFAULT;
    writeStat(dv, st);
    return 0;
  }

  sysNewfstatat(dirfd, ptr, out, flags) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    const abs = this.resolveAt(dirfd, path);
    if (abs === null) return -E.EBADF;
    const follow = (flags & AT.SYMLINK_NOFOLLOW) === 0;
    const st = this.vfs.stat(abs, follow);
    if (typeof st === 'number') return st;
    const dv = this.memoryDataView(out, STAT.SIZE_BYTES);
    if (dv === null) return -E.EFAULT;
    writeStat(dv, st);
    return 0;
  }

  sysAccess(ptr, mode) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    return this.vfs.access(path, mode);
  }

  sysFaccessat(dirfd, ptr, mode, flags) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    const abs = this.resolveAt(dirfd, path);
    if (abs === null) return -E.EBADF;
    return this.vfs.access(abs, mode);
  }

  _mapTag(flags) {
    if ((flags & 0x20000) !== 0) return 'stack'; // MAP_STACK
    return 'anon';
  }

  sysMmap(addr, len, prot, flags, fd, off) {
    if (len <= 0) return -E.EINVAL;
    if ((flags & MAP.ANONYMOUS) === 0) return -E.ENODEV;
    if ((flags & MAP.FIXED) !== 0) {
      if (addr % PAGE_SIZE !== 0) return -E.EINVAL;
      const at = this.mmap.allocAt(addr, len, this._mapTag(flags));
      return at;
    }
    if ((flags & 0x100000) !== 0) {
      // MAP_FIXED_NOREPLACE: fail if anything is there.
      if (this.mmap.contains(addr, len)) return -E.EEXIST;
      return this.mmap.allocAt(addr, len, this._mapTag(flags));
    }
    try {
      return this.mmap.alloc(len, PAGE_SIZE, this._mapTag(flags));
    } catch (e) {
      return -E.ENOMEM;
    }
  }

  sysMunmap(addr, len) {
    if (len <= 0 || addr % PAGE_SIZE !== 0 || len % PAGE_SIZE !== 0) return -E.EINVAL;
    let end = addr + len;
    let any = false;
    for (;;) {
      let hit = null;
      for (const a of this.mmap.allocs) {
        if (a.start < end && a.end > addr) {
          hit = a;
          break;
        }
      }
      if (hit === null) break;
      const from = Math.max(addr, hit.start);
      const to = Math.min(end, hit.end);
      if (!this.mmap.free(from, to - from)) break;
      any = true;
    }
    return any ? 0 : -E.INVAL;
  }

  sysMremap(oldAddr, oldSize, newSize, flags, newAddr) {
    if (oldSize <= 0 || newSize <= 0) return -E.EINVAL;
    if (oldAddr % PAGE_SIZE !== 0) return -E.EINVAL;
    if (!this.mmap.contains(oldAddr, oldSize)) return -E.EFAULT;
    if (newSize <= oldSize) {
      if (newSize < oldSize) this.mmap.free(oldAddr + newSize, oldSize - newSize);
      return oldAddr;
    }
    if (this.mmap.contains(oldAddr, newSize)) return oldAddr;
    if ((flags & 2) !== 0) {
      // MREMAP_FIXED: the destination is exact.
      const at = this.mmap.allocAt(newAddr, newSize, 'anon');
      if (typeof at !== 'number' || at < 0) return at;
      const copy = Math.min(oldSize, newSize);
      new Uint8Array(this.memory.buffer, at, copy).set(
        new Uint8Array(this.memory.buffer, oldAddr, copy)
      );
      this.mmap.free(oldAddr, oldSize);
      return at;
    }
    if ((flags & 1) === 0) return -E.ENOMEM; // no MAYMOVE and it does not fit
    let at;
    try {
      at = this.mmap.alloc(newSize, PAGE_SIZE, 'anon');
    } catch (e) {
      return -E.ENOMEM;
    }
    const copy = Math.min(oldSize, newSize);
    new Uint8Array(this.memory.buffer, at, copy).set(
      new Uint8Array(this.memory.buffer, oldAddr, copy)
    );
    this.mmap.free(oldAddr, oldSize);
    return at;
  }

  sysClockGettime(clockid, ptr) {
    const dv = this.memoryDataView(ptr, 16);
    if (dv === null) return -E.EFAULT;
    let ns;
    if (clockid === CLOCK.REALTIME || clockid === CLOCK.REALTIME_COARSE) {
      ns = BigInt(Date.now()) * 1000000n;
    } else if (clockid >= CLOCK.MONOTONIC && clockid <= CLOCK.BOOTTIME) {
      ns = this.monoNs();
    } else return -E.EINVAL;
    dv.setBigUint64(0, ns / 1000000000n, true);
    dv.setBigUint64(8, ns % 1000000000n, true);
    return 0;
  }

  sysClockGetres(clockid, ptr) {
    const dv = this.memoryDataView(ptr, 16);
    if (dv === null) return -E.EFAULT;
    dv.setBigUint64(0, 0n, true);
    dv.setBigUint64(8, 1000n, true);
    return 0;
  }

  sysGettimeofday(tv, tz) {
    const ms = Date.now();
    if (tv !== 0) {
      const dv = this.memoryDataView(tv, 16);
      if (dv === null) return -E.EFAULT;
      dv.setBigInt64(0, BigInt(Math.floor(ms / 1000)), true);
      dv.setBigInt64(8, BigInt(Math.floor((ms % 1000) * 1000)), true);
    }
    return 0;
  }

  sysTime(tloc) {
    const sec = Math.floor(Date.now() / 1000);
    if (tloc !== 0) {
      const dv = this.memoryDataView(tloc, 8);
      if (dv === null) return -E.EFAULT;
      dv.setBigInt64(0, BigInt(sec), true);
    }
    return sec;
  }

  sysGetrandom(ptr, len, flags) {
    if (len < 0) return -E.EINVAL;
    if (len === 0) return 0;
    const view = this.memoryBytes(ptr, len);
    if (view === null) return -E.EFAULT;
    // crypto.getRandomValues has a 64 KiB cap; S9 asks for chunks of 64 KiB.
    let off = 0;
    while (off < view.length) {
      const n = Math.min(65536, view.length - off);
      view.set(randomBytes(n), off);
      off += n;
    }
    return len;
  }

  sysUname(ptr) {
    const dv = this.memoryDataView(ptr, UTS_SIZE);
    if (dv === null) return -E.EFAULT;
    const u8 = new Uint8Array(dv.buffer, dv.byteOffset, UTS_SIZE);
    u8.fill(0);
    const fields = ['Linux', 'web', '6.0.0-yweb', '#1', 'wasm32', ''];
    for (let i = 0; i < fields.length; i++) {
      const b = utf8Encode(fields[i]);
      if (b.length >= UTS_FIELD) return -E.EINVAL;
      u8.set(b, i * UTS_FIELD);
    }
    return 0;
  }

  sysGetcwd(buf, size) {
    const path = this.vfs.getcwd();
    const need = path.length + 1;
    if (size < need) return -E.ERANGE;
    const view = this.memoryBytes(buf, need);
    if (view === null) return -E.EFAULT;
    view.set(utf8Encode(path));
    view[path.length] = 0;
    return need;
  }

  sysChdir(ptr) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    return this.vfs.chdir(path);
  }

  sysUmask(mask) {
    const old = this.vfs.umask;
    this.vfs.umask = mask & 0o777;
    return old;
  }

  // A timespec in wasm memory -> milliseconds, or a negative errno.
  readTimespec(ptr) {
    const dv = this.memoryDataView(ptr, 16);
    if (dv === null) return -E.EFAULT;
    const sec = Number(dv.getBigInt64(0, true));
    const nsec = Number(dv.getBigInt64(8, true));
    if (sec < 0 || nsec < 0 || nsec >= 1e9) return -E.EINVAL;
    return sec * 1000 + nsec / 1e6;
  }

  writeTimespec(ptr, ms) {
    const dv = this.memoryDataView(ptr, 16);
    if (dv === null) return -E.EFAULT;
    const total = Math.max(0, Math.ceil(ms * 1e6));
    dv.setBigInt64(0, BigInt(Math.floor(total / 1e9)), true);
    dv.setBigInt64(8, BigInt(total % 1e9), true);
    return 0;
  }

  // The green thread sleeps; the scheduler uses the deadline to wake it even
  // when no other thread can run.
  sleepBlock(untilMs) {
    if (!(untilMs > this.now())) return 0;
    return this.block({ kind: 'sleep', until: untilMs, onTimeout: () => 0n });
  }

  sysNanosleep(req, rem) {
    const ms = this.readTimespec(req);
    if (typeof ms === 'number' && ms < 0) return ms;
    return this.sleepBlock(this.now() + ms);
  }

  sysClockNanosleep(clockid, flags, req, rem) {
    if (clockid < CLOCK.REALTIME || clockid > CLOCK.BOOTTIME) return -E.EINVAL;
    const ms = this.readTimespec(req);
    if (typeof ms === 'number' && ms < 0) return ms;
    if ((flags & 1) === 0) return this.sleepBlock(this.now() + ms);
    // TIMER_ABSTIME: the value is on the requested clock's timeline.
    let until;
    if (clockid === CLOCK.REALTIME || clockid === CLOCK.REALTIME_COARSE) {
      until = this.mono() + (ms - Date.now());
    } else until = ms;
    return this.sleepBlock(until);
  }

  mono() {
    return this.now();
  }

  sysGetrlimit(resource, ptr) {
    const dv = this.memoryDataView(ptr, 16);
    if (dv === null) return -E.EFAULT;
    let cur;
    let max;
    if (resource === 3) {
      cur = max = BigInt(this.info.stackHi);
    } else if (resource === 7) {
      cur = max = 1024n;
    } else if (resource === 9) {
      cur = max = 4n * 1024n * 1024n * 1024n;
    } else {
      cur = max = 1024n * 1024n;
    }
    dv.setBigUint64(0, cur, true);
    dv.setBigUint64(8, max, true);
    return 0;
  }

  sysPrlimit64(pid, resource, newLim, oldLim) {
    if (oldLim !== 0) {
      const r = this.sysGetrlimit(resource, oldLim);
      if (r !== 0) return r;
    }
    return 0;
  }

  sysZero(ptr, len) {
    if (ptr === 0) return 0;
    const view = this.memoryBytes(ptr, len);
    if (view === null) return -E.EFAULT;
    view.fill(0);
    return 0;
  }

  sysArchPrctl(code, addr) {
    const t = this.sched.current;
    if (!t) return -E.EINVAL;
    if (code === 0x1002) {
      // SET_FS: the context is the only writable copy of the wasm global.
      this.saveContext(t);
      this.writeCtxWord(t, CTX.FS, BigInt(addr));
      this.loadContext(t);
      return 0;
    }
    if (code === 0x1003) {
      // GET_FS.
      this.saveContext(t);
      const dv = this.memoryDataView(addr, 8);
      if (dv === null) return -E.EFAULT;
      dv.setBigUint64(0, this.readCtxWord(t, CTX.FS), true);
      return 0;
    }
    return -E.EINVAL;
  }

  // S9 futex: WAIT/WAKE/REQUEUE with the bitset forms and timeouts.
  sysFutex(uaddr, op, val, timeout, uaddr2, val3) {
    if (uaddr % 4 !== 0) return -E.EINVAL;
    const cmd = op & FUTEX.CMD_MASK;
    const count = val < 0 ? 0x7fffffff : val;

    if (cmd === FUTEX.WAKE) return this.futexWake(uaddr, count);
    if (cmd === FUTEX.WAKE_BITSET) {
      if ((val3 >>> 0) === 0) return -E.EINVAL;
      return this.futexWake(uaddr, count, val3 >>> 0);
    }
    if (cmd === FUTEX.WAIT || cmd === FUTEX.WAIT_BITSET) {
      const dv = this.memoryDataView(uaddr, 4);
      if (dv === null) return -E.EFAULT;
      if (dv.getInt32(0, true) !== (val | 0)) return -E.EAGAIN;
      let bitset = 0xffffffff;
      if (cmd === FUTEX.WAIT_BITSET) {
        bitset = val3 >>> 0;
        if (bitset === 0) return -E.EINVAL;
      }
      let until = Infinity;
      if (timeout !== 0) {
        const ms = this.readTimespec(timeout);
        if (typeof ms === 'number' && ms < 0) return ms;
        if (cmd === FUTEX.WAIT) {
          until = this.now() + ms;
        } else if ((op & FUTEX.CLOCK_REALTIME) !== 0) {
          until = this.now() + (ms - Date.now());
        } else {
          until = ms; // WAIT_BITSET: an absolute CLOCK_MONOTONIC time
        }
      }
      return this.block({
        kind: 'futex',
        addr: uaddr,
        bitset,
        until,
        onTimeout: () => BigInt(-E.ETIMEDOUT),
      });
    }
    if (cmd === FUTEX.REQUEUE || cmd === FUTEX.CMP_REQUEUE) {
      if (cmd === FUTEX.CMP_REQUEUE) {
        const dv = this.memoryDataView(uaddr, 4);
        if (dv === null) return -E.EFAULT;
        if (dv.getInt32(0, true) !== (val3 | 0)) return -E.EAGAIN;
      }
      if (uaddr2 % 4 !== 0) return -E.EINVAL;
      const woke = this.futexWake(uaddr, count);
      const moved = this.futexRequeue(uaddr2, uaddr, timeout < 0 ? 0x7fffffff : timeout);
      return woke + moved;
    }
    return -E.ENOSYS;
  }

  // S9: SIGKILL/SIGTERM/SIGINT end the process with 128+sig, signal 0
  // succeeds, every other signal is accepted and never delivered.
  sysKill(pid, sig) {
    sig = sig & 0xff;
    if (sig === 0) return 0;
    if (sig === SIG.SIGKILL || sig === SIG.SIGTERM || sig === SIG.SIGINT) {
      return this.requestExit(128 + sig, true);
    }
    if (sig === SIG.SIGSEGV || sig === SIG.SIGILL || sig === SIG.SIGFPE ||
        sig === SIG.SIGTRAP) {
      return 0;
    }
    return 0;
  }

  sysFcntl(fd, cmd, arg) {
    switch (cmd) {
      case F.DUPFD:
        return this.vfs.dup(fd, arg, false);
      case F.DUPFD_CLOEXEC:
        return this.vfs.dup(fd, arg, true);
      case F.GETFD:
        return this.vfs.getCloexec(fd);
      case F.SETFD:
        return this.vfs.setCloexec(fd, (arg & FD_CLOEXEC) !== 0);
      case F.GETFL:
        return this.vfs.fdFlags(fd);
      case F.SETFL: {
        const oldFlags = this.vfs.fdFlags(fd);
        if (typeof oldFlags === 'number' && oldFlags < 0) return oldFlags;
        const keep = oldFlags & ~(O.NONBLOCK | O.APPEND);
        return this.vfs.setFdFlags(fd, keep | (arg & (O.NONBLOCK | O.APPEND)));
      }
      case F.GETLK:
        return this.sysZero(arg, 32);
      case F.SETLK:
      case F.SETLKW:
        return 0;
      default:
        return -E.EINVAL;
    }
  }

  sysReadlink(ptr, buf, size) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    return this.copyLink(this.vfs.readlink(path), buf, size);
  }

  sysReadlinkat(dirfd, ptr, buf, size) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    const abs = this.resolveAt(dirfd, path);
    if (abs === null) return -E.EBADF;
    return this.copyLink(this.vfs.readlink(abs), buf, size);
  }

  copyLink(target, buf, size) {
    if (typeof target === 'number') return target;
    if (size <= 0) return -E.EINVAL;
    const b = utf8Encode(target);
    const n = Math.min(size, b.length);
    const view = this.memoryBytes(buf, n);
    if (view === null) return -E.EFAULT;
    view.set(b.subarray(0, n));
    return n;
  }

  // -- the rest of S9 -------------------------------------------------------

  sysSetTidAddress(ptr) {
    const t = this.sched.current;
    if (t && ptr !== 0) {
      if (this.memoryDataView(ptr, 4) === null) return -E.EFAULT;
      t.ctid = ptr;
    }
    return t ? t.id : 1;
  }

  sysGetRobustList(headPtr, lenPtr) {
    if (lenPtr !== 0) {
      const dv = this.memoryDataView(lenPtr, 8);
      if (dv === null) return -E.EFAULT;
      dv.setBigUint64(0, 24n, true);
    }
    if (headPtr !== 0) {
      const dv = this.memoryDataView(headPtr, 8);
      if (dv === null) return -E.EFAULT;
      dv.setBigUint64(0, 0n, true);
    }
    return 0;
  }

  // -- directories and statx ------------------------------------------------

  sysGetdents(fd, ptr, count) {
    if (count <= 0) return -E.EINVAL;
    const r = this.vfs.getdents(fd, count);
    if (typeof r === 'number') return r;
    const view = this.memoryBytes(ptr, r.length);
    if (view === null) return -E.EFAULT;
    view.set(r);
    return r.length;
  }

  writeStatx(dv, st) {
    const u8 = new Uint8Array(dv.buffer, dv.byteOffset, STATX.SIZE_BYTES);
    u8.fill(0);
    dv.setUint32(STATX.MASK, STATX_BASIC_STATS, true);
    dv.setUint32(STATX.BLKSIZE, (st.blksize || PAGE_SIZE) >>> 0, true);
    dv.setBigUint64(STATX.ATTRIBUTES, 0n, true);
    dv.setUint32(STATX.NLINK, (st.nlink || 1) >>> 0, true);
    dv.setUint32(STATX.UID, (st.uid === undefined ? 1000 : st.uid) >>> 0, true);
    dv.setUint32(STATX.GID, (st.gid === undefined ? 1000 : st.gid) >>> 0, true);
    dv.setUint16(STATX.MODE, (st.mode || 0) & 0xffff, true);
    dv.setBigUint64(STATX.INO, BigInt(st.ino || 0), true);
    dv.setBigUint64(STATX.SIZE, BigInt(Math.trunc(st.size || 0)), true);
    dv.setBigUint64(STATX.BLOCKS, BigInt(st.blocks || 0), true);
    dv.setBigUint64(STATX.ATTRIBUTES_MASK, 0n, true);
    const putTime = (ms, off) => {
      const v = Math.max(0, Math.floor(ms || 0));
      dv.setBigInt64(off, BigInt(Math.floor(v / 1000)), true);
      dv.setUint32(off + 8, Math.floor((v % 1000) * 1e6) >>> 0, true);
    };
    putTime(st.atimeMs, STATX.ATIME);
    putTime(st.mtimeMs, STATX.MTIME);
    putTime(st.ctimeMs, STATX.CTIME);
    dv.setUint32(STATX.RDEV_MAJOR, 0, true);
    dv.setUint32(STATX.RDEV_MINOR, 0, true);
    dv.setUint32(STATX.DEV_MAJOR, 0, true);
    dv.setUint32(STATX.DEV_MINOR, 0, true);
  }

  sysStatx(dirfd, ptr, flags, mask, out) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    let st;
    if (path === '' && (flags & AT.EMPTY_PATH) !== 0) {
      st = this.vfs.fstat(dirfd);
    } else {
      const abs = this.resolveAt(dirfd, path);
      if (abs === null) return -E.EBADF;
      st = this.vfs.stat(abs, (flags & AT.SYMLINK_NOFOLLOW) === 0);
    }
    if (typeof st === 'number') return st;
    const dv = this.memoryDataView(out, STATX.SIZE_BYTES);
    if (dv === null) return -E.EFAULT;
    this.writeStatx(dv, st);
    return 0;
  }

  // -- positional I/O and vectors ------------------------------------------

  sysPread(fd, ptr, count, offset) {
    if (count < 0) return -E.EINVAL;
    if (count > 0x7ffff000) return -E.EINVAL;
    if (count === 0) return 0;
    const r = this.vfs.readAt(fd, count, offset);
    if (typeof r === 'number') return r;
    const view = this.memoryBytes(ptr, r.data.length);
    if (view === null) return -E.EFAULT;
    view.set(r.data);
    return r.data.length;
  }

  sysPwrite(fd, ptr, count, offset) {
    if (count < 0) return -E.EINVAL;
    if (count > 0x7ffff000) return -E.EINVAL;
    if (count === 0) return 0;
    const view = this.memoryBytes(ptr, count);
    if (view === null) return -E.EFAULT;
    return this.vfs.writeAt(fd, view, offset);
  }

  readIovecs(iov, cnt) {
    if (cnt < 0 || cnt > 1024) return -E.EINVAL;
    const out = [];
    for (let i = 0; i < cnt; i++) {
      const dv = this.memoryDataView(iov + i * 16, 16);
      if (dv === null) return -E.EFAULT;
      const base = Number(dv.getBigUint64(0, true));
      const len = Number(dv.getBigUint64(8, true));
      if (len < 0 || this.memoryBytes(base, len) === null) return -E.EFAULT;
      out.push({ base, len });
    }
    return out;
  }

  sysReadv(fd, iov, cnt) {
    const vecs = this.readIovecs(iov, cnt);
    if (typeof vecs === 'number') return vecs;
    let total = 0;
    for (const v of vecs) {
      if (v.len === 0) continue;
      const r = this.vfs.read(fd, v.len);
      if (typeof r === 'number') return total > 0 ? total : r;
      if (r.block) {
        if (total > 0) break;
        return this.blockReadv(fd, vecs, r.block);
      }
      const view = this.memoryBytes(v.base, r.data.length);
      if (view === null) return total > 0 ? total : -E.EFAULT;
      view.set(r.data);
      total += r.data.length;
      if (r.data.length < v.len) break;
    }
    if (total > 0) this.notifyFd();
    return total;
  }

  blockReadv(fd, vecs, block) {
    const wait = {
      kind: block.kind,
      pipe: block.pipe,
      eventfd: block.eventfd,
      timerfd: block.timerfd,
      ready: () => {
        if (block.kind === 'pipe-read') return block.pipe.len > 0 || block.pipe.writers === 0;
        if (block.kind === 'eventfd-read') return block.eventfd.count > 0n;
        if (block.kind === 'timerfd-read') return block.timerfd.due(this.now()) > 0;
        if (block.kind === 'stdin-console') return block.stdin.hasData() || block.stdin.eof;
        return false;
      },
      resume: () => {
        let total = 0;
        for (const v of vecs) {
          if (v.len === 0) continue;
          const r = this.vfs.read(fd, v.len);
          if (typeof r === 'number') return BigInt(total > 0 ? total : r);
          if (r.block) break;
          const view = this.memoryBytes(v.base, r.data.length);
          if (view === null) return BigInt(total > 0 ? total : -E.EFAULT);
          view.set(r.data);
          total += r.data.length;
          if (r.data.length < v.len) break;
        }
        this.notifyFd();
        return BigInt(total);
      },
    };
    if (block.kind === 'timerfd-read' && Number.isFinite(block.timerfd.next)) wait.until = block.timerfd.next;
    if (block.kind === 'stdin-console' && typeof block.stdin.waitPromise === 'function') {
      wait.promise = block.stdin.waitPromise();
    }
    return this.block(wait);
  }

  sysWritev(fd, iov, cnt) {
    const vecs = this.readIovecs(iov, cnt);
    if (typeof vecs === 'number') return vecs;
    const parts = [];
    for (const v of vecs) {
      if (v.len === 0) continue;
      parts.push(U8.from(this.memoryBytes(v.base, v.len)));
    }
    const data = parts.length === 1 ? parts[0] : U8.concat(parts);
    return this._writeBytes(fd, data);
  }

  _writeBytes(fd, bytes) {
    const r = this.vfs.write(fd, bytes);
    if (typeof r === 'number') {
      if (r >= 0) this.notifyFd();
      return r;
    }
    if (!r.block) return -E.EIO;
    const base = r.written || 0;
    if (r.block.kind === 'pipe-write') {
      const pipe = r.block.pipe;
      const rest = r.block.rest;
      return this.block({
        kind: 'pipe-write',
        pipe,
        ready: () => pipe.readers === 0 || pipe.len + rest.length <= pipe.capacity,
        resume: () => {
          const w = this.vfs.write(fd, rest);
          if (typeof w === 'number') {
            this.notifyFd();
            if (w < 0) return BigInt(base > 0 ? base : w);
            return BigInt(base + w);
          }
          return BigInt(-E.EAGAIN);
        },
      });
    }
    if (r.block.kind === 'eventfd-write') {
      const ev = r.block.eventfd;
      const value = r.block.value;
      const copy = U8.from(bytes);
      return this.block({
        kind: 'eventfd-write',
        eventfd: ev,
        ready: () => ev.count + value <= 0xfffffffffffffffen,
        resume: () => {
          const w = this.vfs.write(fd, copy);
          if (typeof w === 'number') {
            this.notifyFd();
            return BigInt(w);
          }
          return BigInt(-E.EAGAIN);
        },
      });
    }
    return -E.EIO;
  }

  sysTruncate(ptr, length) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    return this.vfs.truncate(path, length);
  }

  // -- pipes and synthetic files -------------------------------------------

  sysPipe(ptr, flags) {
    if (flags & ~(O.NONBLOCK | O.CLOEXEC)) return -E.EINVAL;
    const dv = this.memoryDataView(ptr, 8);
    if (dv === null) return -E.EFAULT;
    const r = this.vfs.pipe(flags | O.CLOEXEC);
    if (typeof r === 'number') return r;
    dv.setInt32(0, r.readFd, true);
    dv.setInt32(4, r.writeFd, true);
    return r.writeFd;
  }

  sysIoctl(fd, req, arg) {
    if (req === 0x541b) {
      // FIONREAD
      const n = this.vfs.bytesReady(fd);
      if (typeof n === 'number' && n < 0) return n;
      const dv = this.memoryDataView(arg, 4);
      if (dv === null) return -E.EFAULT;
      dv.setInt32(0, n, true);
      return 0;
    }
    if (req === 0x5421) {
      // FIONBIO
      const dv = this.memoryDataView(arg, 4);
      if (dv === null) return -E.EFAULT;
      const on = dv.getInt32(0, true) !== 0;
      const cur = this.vfs.fdFlags(fd);
      if (typeof cur === 'number' && cur < 0) return cur;
      return this.vfs.setFdFlags(fd, on ? cur | O.NONBLOCK : cur & ~O.NONBLOCK);
    }
    // TCGETS/TCSETS/TIOCGWINSZ answer -ENOTTY in S9.
    return -E.ENOTTY;
  }

  sysSync(fd) {
    const e = this.vfs.get(fd);
    if (!e) return -E.EBADF;
    return this.vfs.sync(fd);
  }

  sysMemfd(ptr, flags) {
    const name = this.readCString(ptr);
    if (name === null) return -E.EFAULT;
    return this.vfs.memfd(name, flags);
  }

  readItimerspec(ptr) {
    const dv = this.memoryDataView(ptr, 32);
    if (dv === null) return -E.EFAULT;
    const fields = [];
    for (let i = 0; i < 4; i++) {
      const v = Number(dv.getBigInt64(i * 8, true));
      if (v < 0) return -E.EINVAL;
      fields.push(v);
    }
    if (fields[1] >= 1e9 || fields[3] >= 1e9) return -E.EINVAL;
    return {
      interval: { sec: fields[0], nsec: fields[1] },
      value: { sec: fields[2], nsec: fields[3] },
    };
  }

  writeItimerspec(ptr, spec) {
    const dv = this.memoryDataView(ptr, 32);
    if (dv === null) return -E.EFAULT;
    dv.setBigInt64(0, BigInt(spec.intervalSec), true);
    dv.setBigInt64(8, BigInt(spec.intervalNsec), true);
    dv.setBigInt64(16, BigInt(spec.valueSec), true);
    dv.setBigInt64(24, BigInt(spec.valueNsec), true);
    return 0;
  }

  sysTimerfdSettime(fd, flags, newPtr, oldPtr) {
    const spec = this.readItimerspec(newPtr);
    if (typeof spec === 'number') return spec;
    const old = this.vfs.timerfdSet(fd, spec, (flags & TFD.TIMER_ABSTIME) !== 0);
    if (typeof old === 'number') return old;
    if (oldPtr !== 0) {
      const r = this.writeItimerspec(oldPtr, old);
      if (r !== 0) return r;
    }
    this.notifyFd();
    return 0;
  }

  sysTimerfdGettime(fd, ptr) {
    const cur = this.vfs.timerfdGet(fd);
    if (typeof cur === 'number') return cur;
    return this.writeItimerspec(ptr, cur);
  }

  // -- path mutation --------------------------------------------------------

  sysMkdir(dirfd, ptr, mode) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    const abs = this.resolveAt(dirfd, path);
    if (abs === null) return -E.EBADF;
    return this.vfs.mkdir(abs, mode);
  }

  sysRmdir(ptr) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    return this.vfs.rmdir(path);
  }

  sysUnlink(dirfd, ptr, flags) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    const abs = this.resolveAt(dirfd, path);
    if (abs === null) return -E.EBADF;
    return (flags & AT.REMOVEDIR) !== 0 ? this.vfs.rmdir(abs) : this.vfs.unlink(abs);
  }

  sysRename(olddirfd, oldPtr, newdirfd, newPtr, flags) {
    const from = this.readCString(oldPtr);
    if (from === null) return -E.EFAULT;
    const to = this.readCString(newPtr);
    if (to === null) return -E.EFAULT;
    const absFrom = this.resolveAt(olddirfd, from);
    const absTo = this.resolveAt(newdirfd, to);
    if (absFrom === null || absTo === null) return -E.EBADF;
    return this.vfs.rename(absFrom, absTo, flags);
  }

  sysSymlink(targetPtr, dirfd, linkPtr) {
    const target = this.readCString(targetPtr);
    if (target === null) return -E.EFAULT;
    const link = this.readCString(linkPtr);
    if (link === null) return -E.EFAULT;
    const abs = this.resolveAt(dirfd, link);
    if (abs === null) return -E.EBADF;
    return this.vfs.symlink(target, abs);
  }

  sysChmod(ptr, mode, follow) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    return this.vfs.chmod(path, mode, follow);
  }

  sysFchmodat(dirfd, ptr, mode, flags) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    const abs = this.resolveAt(dirfd, path);
    if (abs === null) return -E.EBADF;
    return this.vfs.chmod(abs, mode, (flags & AT.SYMLINK_NOFOLLOW) === 0);
  }

  sysChown(ptr, uid, gid, follow) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    return this.vfs.chown(path, uid, gid, follow);
  }

  sysFchown(fd, uid, gid) {
    const e = this.vfs.get(fd);
    if (!e) return -E.EBADF;
    return this.vfs.fchown(fd, uid, gid);
  }

  sysFchownat(dirfd, ptr, uid, gid, flags) {
    const path = this.readCString(ptr);
    if (path === null) return -E.EFAULT;
    const abs = this.resolveAt(dirfd, path);
    if (abs === null) return -E.EBADF;
    return this.vfs.chown(abs, uid, gid, (flags & AT.SYMLINK_NOFOLLOW) === 0);
  }

  // -- poll/ppoll/select/pselect6 ------------------------------------------

  pollEntries(fdsPtr, nfds) {
    if (nfds < 0 || nfds > 1024) return -E.EINVAL;
    if (nfds === 0) return [];
    if (this.memoryDataView(fdsPtr, nfds * 8) === null) return -E.EFAULT;
    const list = [];
    for (let i = 0; i < nfds; i++) {
      const dv = this.memoryDataView(fdsPtr + i * 8, 8);
      list.push({
        ptr: fdsPtr + i * 8,
        fd: dv.getInt32(0, true),
        events: dv.getInt16(4, true) & 0xffff,
        revents: 0,
      });
    }
    return list;
  }

  pollCompute(list) {
    let n = 0;
    for (const p of list) {
      p.revents = this.vfs.pollFd(p.fd, p.events);
      if (p.revents !== 0) n++;
    }
    return n;
  }

  pollWrite(list) {
    let n = 0;
    for (const p of list) {
      const dv = this.memoryDataView(p.ptr, 8);
      if (dv === null) continue;
      dv.setInt16(6, p.revents, true);
      if (p.revents !== 0) n++;
    }
    return n;
  }

  pollDeadline(list, until) {
    for (const p of list) {
      const e = this.vfs.get(p.fd);
      if (e && e.ofd.kind === 'timerfd' && Number.isFinite(e.ofd.timerfd.next)) {
        until = Math.min(until, e.ofd.timerfd.next);
      }
    }
    return until;
  }

  sysPoll(fdsPtr, nfds, timeout, isPpoll) {
    const list = this.pollEntries(fdsPtr, nfds);
    if (typeof list === 'number') return list;
    if (nfds === 0) {
      // No descriptors: only the timeout matters.
      if (!isPpoll) {
        if (timeout <= 0) return 0;
        return this.sleepBlock(this.now() + timeout);
      }
      if (timeout === 0) return 0;
      const ms = this.readTimespec(timeout);
      if (typeof ms === 'number' && ms < 0) return ms;
      return this.sleepBlock(this.now() + ms);
    }
    if (this.pollCompute(list) > 0) return this.pollWrite(list);
    let until = Infinity;
    if (isPpoll) {
      if (timeout !== 0) {
        const ms = this.readTimespec(timeout);
        if (typeof ms === 'number' && ms < 0) return ms;
        until = this.now() + ms;
      }
    } else if (timeout >= 0) {
      until = this.now() + timeout;
    }
    until = this.pollDeadline(list, until);
    const wait = {
      kind: 'poll',
      fds: list,
      ready: () => this.pollCompute(list) > 0,
      resume: () => BigInt(this.pollWrite(list)),
      until,
      onTimeout: () => {
        this.pollCompute(list);
        return BigInt(this.pollWrite(list));
      },
    };
    return this.block(wait);
  }

  readFdSet(ptr, nfds) {
    const set = new Set();
    if (ptr === 0) return set;
    const bytes = Math.ceil(nfds / 8);
    if (bytes === 0) return set;
    const view = this.memoryBytes(ptr, bytes);
    if (view === null) return null;
    for (let i = 0; i < nfds; i++) {
      if ((view[i >> 3] & (1 << (i & 7))) !== 0) set.add(i);
    }
    return set;
  }

  writeFdSet(ptr, nfds, set) {
    if (ptr === 0) return 0;
    const bytes = Math.ceil(nfds / 8);
    if (bytes === 0) return 0;
    const view = this.memoryBytes(ptr, bytes);
    if (view === null) return -E.EFAULT;
    view.fill(0);
    for (const fd of set) {
      if (fd >= 0 && fd < nfds) view[fd >> 3] |= 1 << (fd & 7);
    }
    return 0;
  }

  selectLists(nfds, rfds, wfds, efds) {
    if (nfds < 0 || nfds > 1024) return -E.EINVAL;
    const rset = this.readFdSet(rfds, nfds);
    const wset = this.readFdSet(wfds, nfds);
    const eset = this.readFdSet(efds, nfds);
    if (rset === null || wset === null || eset === null) return -E.EFAULT;
    const wanted = new Set([...rset, ...wset, ...eset]);
    const list = [];
    for (const fd of [...wanted].sort((a, b) => a - b)) {
      let events = 0;
      if (rset.has(fd)) events |= POLL.IN;
      if (wset.has(fd)) events |= POLL.OUT;
      if (eset.has(fd)) events |= POLL.PRI;
      list.push({ fd, events, revents: 0, r: rset.has(fd), w: wset.has(fd), e: eset.has(fd) });
    }
    return { list, nfds, rfds, wfds, efds };
  }

  selectReady(state) {
    let n = 0;
    for (const p of state.list) {
      p.revents = this.vfs.pollFd(p.fd, p.events);
      if (p.revents !== 0) n++;
    }
    return n;
  }

  selectWrite(state) {
    const rs = new Set();
    const ws = new Set();
    const es = new Set();
    let n = 0;
    for (const p of state.list) {
      if (p.revents === 0) continue;
      n++;
      if (p.r && (p.revents & (POLL.IN | POLL.HUP | POLL.ERR | POLL.NVAL)) !== 0) rs.add(p.fd);
      if (p.w && (p.revents & (POLL.OUT | POLL.ERR | POLL.NVAL)) !== 0) ws.add(p.fd);
      if (p.e && (p.revents & (POLL.PRI | POLL.ERR | POLL.NVAL)) !== 0) es.add(p.fd);
    }
    const a = this.writeFdSet(state.rfds, state.nfds, rs);
    const b = this.writeFdSet(state.wfds, state.nfds, ws);
    const c = this.writeFdSet(state.efds, state.nfds, es);
    if (a !== 0 || b !== 0 || c !== 0) return -E.EFAULT;
    return n;
  }

  selectTimeoutMs(timeoutPtr, isPselect) {
    if (timeoutPtr === 0) return Infinity;
    let ms;
    if (isPselect) {
      ms = this.readTimespec(timeoutPtr);
    } else {
      const dv = this.memoryDataView(timeoutPtr, 16);
      if (dv === null) return -E.EFAULT;
      const sec = Number(dv.getBigInt64(0, true));
      const usec = Number(dv.getBigInt64(8, true));
      if (sec < 0 || usec < 0 || usec >= 1e6) return -E.EINVAL;
      ms = sec * 1000 + usec / 1000;
    }
    if (typeof ms === 'number' && ms < 0) return ms;
    return ms;
  }

  sysSelect(nfds, rfds, wfds, efds, timeoutPtr, isPselect) {
    const state = this.selectLists(nfds, rfds, wfds, efds);
    if (typeof state === 'number') return state;
    const ms = this.selectTimeoutMs(timeoutPtr, isPselect);
    if (typeof ms === 'number' && ms < 0) return ms;
    const until0 = Number.isFinite(ms) ? this.now() + ms : Infinity;
    // select(0, NULL, NULL, NULL, tv) is the classic portable sleep.
    if (nfds === 0) return this.sleepBlock(until0);
    if (this.selectReady(state) > 0) return this.selectWrite(state);
    let until = until0;
    until = this.pollDeadline(state.list, until);
    return this.block({
      kind: 'select',
      fds: state.list,
      ready: () => this.selectReady(state) > 0,
      resume: () => BigInt(this.selectWrite(state)),
      until,
      onTimeout: () => {
        this.selectReady(state);
        return BigInt(this.selectWrite(state));
      },
    });
  }

  // -- threads --------------------------------------------------------------

  writeTid(ptr, id) {
    if (ptr === 0) return 0;
    const dv = this.memoryDataView(ptr, 4);
    if (dv === null) return -E.EFAULT;
    dv.setInt32(0, id, true);
    return 0;
  }

  cloneCommon(flags, stack, ptid, ctid, tls) {
    if ((flags & CLONE.VM) === 0) return -E.ENOSYS;
    const parent = this.sched.current;
    if (!parent) return -E.EINVAL;
    if (flags & CLONE.PARENT_SETTID) {
      if (this.memoryDataView(ptid, 4) === null) return -E.EFAULT;
    }
    if (flags & (CLONE.CHILD_SETTID | CLONE.CHILD_CLEARTID)) {
      if (this.memoryDataView(ctid, 4) === null) return -E.EFAULT;
    }
    const id = this.nextTid++;
    let ctx;
    try {
      ctx = this.mmap.alloc(CTX_SIZE, 16, 'kernel');
    } catch (e) {
      return -E.ENOMEM;
    }
    this.exports.ctx_save(ctx);
    const childPc = this.ctxWord(ctx, CTX.PC);
    let childRsp = this.ctxWord(ctx, CTX.R4);
    if (stack !== 0) childRsp = BigInt(stack);
    this.setCtxWord(ctx, CTX.R0, 0n);
    this.setCtxWord(ctx, CTX.R4, childRsp);
    if (flags & CLONE.SETTLS) this.setCtxWord(ctx, CTX.FS, tls);
    const child = {
      id,
      ctx,
      pc: childPc,
      state: 'runnable',
      needsLoad: true,
      wait: null,
      ctid: (flags & CLONE.CHILD_CLEARTID) !== 0 ? ctid : 0,
      ownsCtx: true,
      exitCode: 0,
      exitReason: 'exit',
      tgid: parent.tgid || 1,
    };
    this.sched.addThread(child);
    if (flags & CLONE.PARENT_SETTID) this.writeTid(ptid, id);
    if (flags & CLONE.CHILD_SETTID) this.writeTid(ctid, id);
    return id;
  }

  sysClone(flags, stack, ptid, ctid, tls) {
    return this.cloneCommon(flags >>> 0, stack, ptid, ctid, tls);
  }

  sysClone3(uargs, size) {
    if (size < 64) return -E.EINVAL;
    const len = Math.min(size, 88);
    const dv = this.memoryDataView(uargs, len);
    if (dv === null) return -E.EFAULT;
    const flags = Number(dv.getBigUint64(0, true));
    if (!Number.isSafeInteger(flags)) return -E.EINVAL;
    const childTid = Number(dv.getBigUint64(16, true));
    const parentTid = Number(dv.getBigUint64(24, true));
    const stackBase = Number(dv.getBigUint64(40, true));
    const stackSize = Number(dv.getBigUint64(48, true));
    const tls = len >= 64 ? Number(dv.getBigUint64(56, true)) : 0;
    if (stackSize !== 0 && stackBase === 0) return -E.EINVAL;
    let stack = 0;
    if (stackBase !== 0) {
      stack = Math.floor((stackBase + stackSize) / 16) * 16;
    }
    return this.cloneCommon(flags >>> 0, stack, parentTid, childTid, tls);
  }

  // -- misc ----------------------------------------------------------------

  sysTimes(ptr) {
    if (ptr !== 0) {
      const view = this.memoryBytes(ptr, 32);
      if (view === null) return -E.EFAULT;
      view.fill(0);
    }
    return Math.max(0, Math.floor(this.now() / 10)); // 100 Hz clock_t
  }

  sysSysinfo(ptr) {
    const dv = this.memoryDataView(ptr, 112);
    if (dv === null) return -E.EFAULT;
    new Uint8Array(dv.buffer, dv.byteOffset, 112).fill(0);
    const pages = this.memoryPages();
    const total = BigInt(pages) * 4096n;
    dv.setBigInt64(0, BigInt(Math.floor(this.now() / 1000)), true);
    dv.setBigUint64(32, total, true);
    dv.setBigUint64(40, total, true);
    dv.setUint16(80, this.sched ? this.sched.liveCount() : 1, true);
    dv.setBigUint64(88, total, true);
    dv.setBigUint64(96, total, true);
    dv.setUint32(104, 1, true);
    return 0;
  }

  memoryPages() {
    return Math.floor((this.memory ? this.memory.buffer.byteLength : 0) / 65536);
  }

  sysHostSym(ptr, len) {
    const view = this.memoryBytes(ptr, len);
    if (view === null) return -E.EFAULT;
    return this.hostSym(utf8Decode(view));
  }

  sysHostCall(handle, argsPtr, n) {
    const fn = this.hostHandles[handle];
    if (typeof fn !== 'function') return -E.EBADF;
    if (n < 0) return -E.EINVAL;
    const args = [];
    for (let i = 0; i < n; i++) {
      const dv = this.memoryDataView(argsPtr + i * 8, 8);
      if (dv === null) return -E.EFAULT;
      args.push(dv.getBigInt64(0, true));
    }
    let r;
    try {
      r = fn(args, this.yMem());
    } catch (e) {
      return -E.EIO;
    }
    if (r && typeof r.then === 'function') {
      if (!this.asyncMode) {
        // The synchronous loop cannot settle a promise: say so instead of
        // hanging.  runAsync() (the CLI) and the browser host support it.
        return this.unimplemented(Y_SYS.HOST_CALL);
      }
      let settled = false;
      let value = 0n;
      let failure = 0n;
      const promise = Promise.resolve(r).then(
        (v) => {
          settled = true;
          if (typeof v === 'bigint') value = v;
          else if (v === undefined || v === null) value = 0n;
          else if (typeof v === 'number') value = BigInt(Math.trunc(v));
          else failure = BigInt(-E.EINVAL);
        },
        () => {
          settled = true;
          failure = BigInt(-E.EIO);
        }
      );
      return this.block({
        kind: 'hostcall',
        promise,
        ready: () => settled,
        resume: () => (failure !== 0n ? failure : value),
      });
    }
    if (r === undefined || r === null) return 0;
    if (typeof r === 'bigint') return r;
    if (typeof r === 'number') return r;
    return Number(r);
  }
}

// ---------------------------------------------------------------------------
// Convenience entry points.
// ---------------------------------------------------------------------------

export function runBytes(bytes, opts = {}) {
  const host = new Host(bytes, opts);
  return host.run();
}

export async function runBytesAsync(bytes, opts = {}) {
  const host = new Host(bytes, opts);
  return host.runAsync();
}

