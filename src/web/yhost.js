// src/web/yhost.js — the Node CLI and Node platform for a Y web module.
//
// Usage (Node 22; wasm trap handling off):
//   node --disable-wasm-trap-handler src/web/yhost.js run [--fuel=N] [--trace] FILE.wasm [args...]
//   node --disable-wasm-trap-handler src/web/yhost.js validate FILE.wasm
//   node --disable-wasm-trap-handler src/web/yhost.js selftest
//
// The kernel itself is core.js and has no node: import.  This file supplies
// what Node adds: node:fs as the VFS backend, process.env/cwd, the real
// descriptors for stdio, a synchronous sleep and the CLI.  The browser entry
// point is page.js with memfs.js + store.js; both run the same core.

import fs from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  ABI_VERSION, CTX, CTX_SIZE, O, S_IFMT, S_IFREG,
  ctxSetU64, decodeToken, encodeToken,
} from './abi.js';
import { Vfs, basename, normalizePath, encode as utf8Encode, decode as utf8Decode } from './vfs.js';
import { sleepSync } from './sched.js';
import {
  Host as CoreHost, HostError, buildInitialStack, normalizeEnv, parseSections,
  parseYweb, readNameSection, readSLEB, readULEB, readYweb, readMemoryMin,
  findCustomSection, validateModule,
} from './core.js';
import { VirtualDisplay, installGui } from './gui.js';
import { installAudio } from './audio.js';
import { installWeb } from './web.js';

// The Node side of S9's pacing: block for a synchronous sleep, and give the
// event loop a turn with setImmediate exactly as W4 did.
const nodePlatform = {
  sleepSync(ms) {
    sleepSync(ms);
  },
  yieldLoop() {
    return new Promise((resolve) => setImmediate(resolve));
  },
};

function writeFd(fd) {
  return (bytes) => {
    let off = 0;
    while (off < bytes.length) off += fs.writeSync(fd, bytes, off, bytes.length - off);
  };
}

// --display=WxH: Node's virtual display for gui.  opts.display may also be a
// {width,height,eventsText} object (the tests use that), and 0/null means
// "no display" so gui.open answers 0.
export function parseDisplaySize(text) {
  const m = /^([0-9]+)x([0-9]+)$/.exec(String(text || ''));
  if (!m) return null;
  const width = Number(m[1]);
  const height = Number(m[2]);
  if (!(width > 0 && height > 0) || width > 16384 || height > 16384) return null;
  return { width, height };
}

function makeDisplay(value) {
  if (value === undefined || value === null || value === false || value === 0 || value === '' || value === 'none') {
    return null;
  }
  if (typeof value === 'object') {
    return new VirtualDisplay({
      width: value.width,
      height: value.height,
      eventsText: value.eventsText || value.events || '',
    });
  }
  const size = parseDisplaySize(value);
  if (size === null) throw new HostError('bad display size ' + String(value) + ' (want WxH)');
  return new VirtualDisplay(size);
}

// -- the web.* host functions (W8/S10) ---------------------------------------
//
// Node is platform "node": there is no query string, eval runs the script in
// this context (and as a function body when the script wants a return), a
// fetch reads a file: URL or a path relative to the working directory, and
// window.open does not exist.  A remote URL goes to Node's own fetch, and a
// status outside 2xx or a network error is none in Y.

const URL_SCHEME = /^[a-zA-Z][a-zA-Z0-9+.-]*:/;

/** The body a web.fetch asks for, or null (a missing file, non-2xx, error). */
export function nodeFetchBytes(url) {
  const text = String(url);
  if (!URL_SCHEME.test(text) || text.startsWith('file:')) {
    let file;
    try {
      file = fileURLToPath(new URL(text, pathToFileURL(process.cwd() + '/')));
    } catch (e) {
      return null;
    }
    try {
      return new Uint8Array(fs.readFileSync(file));
    } catch (e) {
      return null;
    }
  }
  return fetch(text).then((res) => {
    if (!res.ok) return null;
    return res.arrayBuffer().then((b) => new Uint8Array(b));
  }, () => null);
}

/** web.eval: a script's value, or a function body's return, in this context. */
export function nodeEval(js) {
  try {
    return vm.runInThisContext(js);
  } catch (e) {
    if (!(e && e.name === 'SyntaxError')) throw e;
    return new Function(js)();
  }
}

export class Host extends CoreHost {
  constructor(bytes, opts = {}) {
    const o = { ...opts };
    if (o.env === undefined) o.env = process.env;
    if (o.cwd === undefined) o.cwd = process.cwd();
    if (o.stdout === undefined) o.stdout = writeFd(1);
    if (o.stderr === undefined) o.stderr = writeFd(2);
    if (o.fs === undefined) o.fs = fs;
    if (o.platform === undefined) o.platform = nodePlatform;
    const display = makeDisplay(o.display);
    super(bytes, o);
    this.display = display;
    this.displayPath = o.displayDump || o.display_dump || '';
    this.gui = installGui(this, display);
    // --audio=FILE.wav: the Node WAV sink (W7/S12).  Absent, devs answers 0
    // so snd stays silent and takes no other path.
    this.audio = installAudio(this, { wav: o.audio || '', fs: o.fs, browser: false });
    // W8/S10: the nine web.* names. Node has no query string and no tabs;
    // console.log goes through the program's stdout so the output keeps its
    // order with puts.
    this.web = installWeb(this, {
      platform: 'node',
      param: () => null,
      eval: nodeEval,
      log: (text) => {
        if (typeof this.stdout === 'function') this.stdout(utf8Encode(text + '\n'));
        else console.log(text);
      },
      openUrl: () => false,
      fetchBytes: nodeFetchBytes,
    });
  }

  // --display-dump=FILE: the last frame as a PPM, after the program ends.
  writeDisplayDump() {
    if (!this.displayPath || !this.gui) return false;
    const ppm = this.gui.dumpPPM();
    if (!ppm) return false;
    try {
      fs.writeFileSync(this.displayPath, ppm);
      return true;
    } catch (e) {
      return false;
    }
  }

  run() {
    try {
      return super.run();
    } finally {
      this.finishAudio();
      this.writeDisplayDump();
    }
  }

  async runAsync() {
    try {
      return await super.runAsync();
    } finally {
      this.finishAudio();
      this.writeDisplayDump();
    }
  }

  // Patch the WAV header (the RIFF/data lengths) and close it, whatever the
  // exit status was.
  finishAudio() {
    if (this.audio) this.audio.finish();
  }
}

export function runBytes(bytes, opts = {}) {
  return new Host(bytes, opts).run();
}

export async function runBytesAsync(bytes, opts = {}) {
  return new Host(bytes, opts).runAsync();
}

export function runFile(file, opts = {}) {
  const bytes = fs.readFileSync(file);
  const argv = opts.argv || [file].concat(opts.args || []);
  let exePath = opts.exePath;
  if (!exePath) {
    try {
      exePath = fs.realpathSync(file);
    } catch (e) {
      exePath = file;
    }
  }
  return runBytes(bytes, { ...opts, argv, exePath });
}

// The site's build/web/bin/NAME launcher asks for this first.  The argv[0] is
// the bin name, not the temporary .wasm path.
export function runNode(file, args = []) {
  const name = basename(file).replace(/\.wasm$/, '');
  return runFileAsync(file, { argv: [name].concat((args || []).map(String)) });
}

export async function runFileAsync(file, opts = {}) {
  const bytes = fs.readFileSync(file);
  const argv = opts.argv || [file].concat(opts.args || []);
  let exePath = opts.exePath;
  if (!exePath) {
    try {
      exePath = fs.realpathSync(file);
    } catch (e) {
      exePath = file;
    }
  }
  return runBytesAsync(bytes, { ...opts, argv, exePath });
}

// ---------------------------------------------------------------------------
// selftest: the JS unit tests W3's web-smoke asks for.  Prints exactly
// "selftest: ok" on success.
// ---------------------------------------------------------------------------

function collector() {
  const parts = [];
  return {
    write(b) {
      parts.push(Buffer.from(b));
    },
    text() {
      return Buffer.concat(parts).toString('utf8');
    },
  };
}

export async function selftest() {
  const failures = [];
  const test = (name, fn) => {
    try {
      fn();
    } catch (e) {
      failures.push(name + ': ' + (e && e.message ? e.message : String(e)));
    }
  };
  const check = (cond, msg) => {
    if (!cond) throw new Error(msg);
  };
  const eq = (a, b, msg) => {
    if (a !== b) throw new Error(msg + ': expected ' + JSON.stringify(b) + ', got ' + JSON.stringify(a));
  };

  let buildSmokeWasm = null;
  try {
    const mod = await import('./test/mkfixture.js');
    buildSmokeWasm = mod.buildSmokeWasm;
  } catch (e) {
    failures.push('load test/mkfixture.js: ' + e.message);
  }

  test('LEB128', () => {
    eq(readULEB(new Uint8Array([0xe5, 0x8e, 0x26]), 0).value, 624485, 'u32 624485');
    eq(readULEB(new Uint8Array([0x80, 0x80, 0x80, 0x80, 0x00]), 0).value, 0, 'u32 0');
    eq(readULEB(new Uint8Array([0xff, 0xff, 0xff, 0xff, 0x0f]), 0).value, 0xffffffff, 'u32 max');
    eq(readSLEB(new Uint8Array([0x7f]), 0).value, -1n, 's32 -1');
    eq(readSLEB(new Uint8Array([0x3f]), 0).value, 63n, 's32 63');
    eq(readSLEB(new Uint8Array([0x40]), 0).value, -64n, 's32 -64');
    let threw = false;
    try {
      readULEB(new Uint8Array([0x80]), 0);
    } catch (e) {
      threw = true;
    }
    check(threw, 'truncated LEB must throw');
  });

  test('yweb lines', () => {
    const kv = parseYweb('abi=1\r\n# comment\nstack_hi=8388608\n\nchunks=3\n');
    eq(kv.abi, '1', 'abi');
    eq(kv.stack_hi, '8388608', 'stack_hi');
    eq(kv.chunks, '3', 'chunks');
    let threw = false;
    try {
      parseYweb('not a pair');
    } catch (e) {
      threw = true;
    }
    check(threw, 'malformed line must throw');
  });

  test('context layout', () => {
    eq(CTX.R0, 0, 'r0');
    eq(CTX.X0, 128, 'x0');
    eq(CTX.FS, 256, 'fs');
    eq(CTX.PC, 264, 'pc');
    eq(CTX.FOP, 272, 'fop');
    eq(CTX.FSZ, 280, 'fsz');
    eq(CTX.FA, 288, 'fa');
    eq(CTX.FB, 296, 'fb');
    eq(CTX.FR, 304, 'fr');
    eq(CTX.FX, 312, 'fx');
    eq(CTX.FY, 320, 'fy');
    eq(CTX.FCF, 328, 'fcf');
    eq(CTX.RESERVED, 336, 'reserved');
    eq(CTX_SIZE, 512, 'size');
    const c = new Uint8Array(CTX_SIZE);
    ctxSetU64(c, CTX.R4, 0x1234n);
    const dv = new DataView(c.buffer);
    eq(dv.getBigUint64(32, true), 0x1234n, 'r4 at byte 32');
    ctxSetU64(c, CTX.PC, 0xfeedn);
    eq(dv.getBigUint64(264, true), 0xfeedn, 'pc at byte 264');
    ctxSetU64(c, CTX.FS, 0x5678n);
    eq(dv.getBigUint64(256, true), 0x5678n, 'fs at byte 256');
    eq(dv.getBigUint64(128, true), 0n, 'x0 stays zero');
  });

  test('tokens', () => {
    eq(encodeToken(7, 42), 2 ** 40 + 7 * 2 ** 20 + 42, 'encode');
    const t = decodeToken(encodeToken(7, 42));
    eq(t.chunk, 7, 'chunk');
    eq(t.case, 42, 'case');
    eq(decodeToken(0), null, 'zero is not a token');
    eq(decodeToken(2 ** 41), null, '2^41 is not a token');
    eq(decodeToken(2 ** 40 + 3).case, 3, 'case 3 token');
  });

  test('initial stack', () => {
    const mem = new WebAssembly.Memory({ initial: 2 });
    const st = buildInitialStack(mem, {
      argv: ['prog', 'a b'],
      env: ['A=1', 'B=22'],
      top: 65536,
      random: new Uint8Array(16).fill(0x5a),
    });
    eq(st.rsp % 16, 0, 'rsp alignment');
    check(st.rsp >= 16 && st.rsp < 65536, 'rsp inside the stack region');
    const dv = new DataView(mem.buffer);
    const u8 = new Uint8Array(mem.buffer);
    const at = (ptr) => {
      const off = Number(dv.getBigUint64(ptr, true));
      let end = off;
      while (u8[end] !== 0) end++;
      return utf8Decode(u8.subarray(off, end));
    };
    eq(Number(dv.getBigUint64(st.rsp, true)), 2, 'argc');
    eq(Number(dv.getBigUint64(st.rsp + 8, true)), st.argvPtrs[0], 'argv[0] pointer');
    eq(at(st.rsp + 8), 'prog', 'argv[0]');
    eq(at(st.rsp + 16), 'a b', 'argv[1]');
    eq(Number(dv.getBigUint64(st.rsp + 24, true)), 0, 'argv terminator');
    const envBase = st.rsp + 8 + (st.argc + 1) * 8;
    eq(at(envBase), 'A=1', 'envp[0]');
    eq(at(envBase + 8), 'B=22', 'envp[1]');
    eq(Number(dv.getBigUint64(envBase + 16, true)), 0, 'envp terminator');
    const aux = envBase + (st.envc + 1) * 8;
    eq(Number(dv.getBigUint64(aux, true)), 6, 'AT_PAGESZ');
    eq(Number(dv.getBigUint64(aux + 8, true)), 4096, 'page size');
    eq(Number(dv.getBigUint64(aux + 16, true)), 25, 'AT_RANDOM');
    eq(Number(dv.getBigUint64(aux + 24, true)), st.randomPtr, 'AT_RANDOM pointer');
    eq(Number(dv.getBigUint64(aux + 32, true)), 0, 'AT_NULL');
    eq(Number(dv.getBigUint64(aux + 40, true)), 0, 'AT_NULL value');
    for (let i = 0; i < 16; i++) eq(u8[st.randomPtr + i], 0x5a, 'random byte ' + i);
  });

  test('vfs paths', () => {
    eq(normalizePath('/app', 'x'), '/app/x', 'relative');
    eq(normalizePath('/app', '../a'), '/a', 'parent');
    eq(normalizePath('/', 'a//b/./c/..'), '/a/b', 'normalize');
    eq(normalizePath('/app', '/x/../y'), '/y', 'absolute');
    eq(normalizePath('/', '../../x'), '/x', 'root clamp');

    const vfs = new Vfs({
      cwd: '/work',
      argv: ['prog', 'x y'],
      env: ['A=1', 'B=22'],
      stdout: () => {},
      stderr: () => {},
    });
    eq(vfs.getcwd(), '/work', 'cwd');
    let fd = vfs.open('/proc/self/environ', O.RDONLY);
    check(fd >= 3, 'open environ');
    let rd = vfs.read(fd, 100);
    check(typeof rd === 'object', 'read environ');
    eq(utf8Decode(rd.data), 'A=1\0B=22\0', 'environ bytes');
    eq(vfs.close(fd), 0, 'close environ');

    fd = vfs.open('/proc/self/cmdline', O.RDONLY);
    check(fd >= 3, 'open cmdline');
    rd = vfs.read(fd, 100);
    eq(utf8Decode(rd.data), 'prog\0x y\0', 'cmdline bytes');
    eq(vfs.close(fd), 0, 'close cmdline');

    const st = vfs.stat('/proc/self/cmdline');
    check(typeof st === 'object', 'stat cmdline');
    eq(st.mode & S_IFMT, S_IFREG, 'cmdline is a regular file');
    eq(vfs.chdir('/proc/self'), 0, 'chdir proc');
    eq(vfs.getcwd(), '/proc/self', 'new cwd');
    eq(vfs.resolve('environ'), '/proc/self/environ', 'resolve against cwd');

    fd = vfs.open('/proc/0/comm', O.RDONLY);
    check(fd >= 3, 'open host comm');
    rd = vfs.read(fd, 100);
    eq(utf8Decode(rd.data), 'yhost\n', 'proc/0/comm');
    eq(vfs.close(fd), 0, 'close host comm');

    const seen = [];
    const hooked = new Vfs({
      cwd: '/',
      argv: ['p'],
      env: [],
      stdin: () => new Uint8Array([0x41, 0x42]),
      stdout: (b) => seen.push(...b),
      stderr: () => {},
    });
    const stdinRead = hooked.read(0, 10);
    check(typeof stdinRead === 'object', 'stdin hook read');
    eq(utf8Decode(stdinRead.data), 'AB', 'stdin hook bytes');
    eq(hooked.write(1, new Uint8Array([0x43])), 1, 'stdout hook write');
    eq(seen.join(','), '67', 'stdout hook saw C');

    fd = vfs.open('/dev/null', O.WRONLY);
    check(fd >= 3, 'open null');
    eq(vfs.write(fd, Buffer.from([1, 2, 3])), 3, 'write null');
    eq(vfs.close(fd), 0, 'close null');
  });

  if (buildSmokeWasm !== null) {
    test('fixture validation', () => {
      const v = validateModule(buildSmokeWasm());
      check(v.ok, 'fixture must validate: ' + v.errors.join('; '));
      eq(v.info.abi, 1, 'abi');
      eq(v.info.chunks, 1, 'chunks');
      eq(v.info.entry, 2n ** 40n, 'entry token');
      eq(v.info.entryChunk, 0, 'entry chunk');
      eq(v.info.entryCase, 0, 'entry case');
      eq(v.info.memoryMin, 18, 'memory minimum');
      eq(v.info.protocol, 'throw', 'protocol without set_why');

      const bad = validateModule(buildSmokeWasm({ abi: 2 }));
      check(!bad.ok, 'abi 2 must be refused');
      check(
        bad.errors.some((e) => e.indexOf('abi mismatch') >= 0),
        'abi error is reported'
      );

      const sections = parseSections(buildSmokeWasm());
      check(sections.some((s) => s.id === 0), 'custom sections are parsed');
      const payload = findCustomSection(buildSmokeWasm(), 'yweb');
      check(payload !== null, 'yweb is found');
      eq(parseYweb(utf8Decode(payload)).abi, '1', 'yweb content');

      const nm = readNameSection(buildSmokeWasm());
      check(nm !== null, 'name section is parsed');
      eq(nm.functions.get(2), 'resume', 'name of function 2');
    });

    test('context exports', () => {
      const h = new Host(buildSmokeWasm(), {
        argv: ['prog'],
        env: [],
        random: new Uint8Array(16),
      });
      h.setFuel(10);
      eq(Number(h.exports.why()), 0, 'why() starts at 0');
      h.saveContext(h.mainThread);
      eq(h.mainThread.pc, 0n, 'ctx_save wrote the context (the fixture zeroes it)');
      h.loadContext(h.mainThread);
    });

    test('syscall boundary', () => {
      const h = new Host(buildSmokeWasm(), {
        argv: ['prog', 'x'],
        env: ['A=1'],
        cwd: process.cwd(),
        random: new Uint8Array(16),
      });
      const scratch = h.mmap.alloc(4096, 4096);
      const path = scratch;
      const buf = scratch + 256;
      const args = scratch + 512;

      h.writeMemory(path, utf8Encode('/proc/self/cmdline\0'));
      const fd = Number(h.sys(2n, BigInt(path), 0n, 0n, 0n, 0n, 0n));
      check(fd >= 3, 'open cmdline through sys');
      const n = Number(h.sys(0n, BigInt(fd), BigInt(buf), 128n, 0n, 0n, 0n));
      eq(utf8Decode(h.memoryBytes(buf, n)), 'prog\0x\0', 'read cmdline through sys');
      eq(Number(h.sys(3n, BigInt(fd), 0n, 0n, 0n, 0n, 0n)), 0, 'close through sys');

      h.writeMemory(path, utf8Encode('/proc/self/environ\0'));
      const fd2 = Number(h.sys(2n, BigInt(path), 0n, 0n, 0n, 0n, 0n));
      const n2 = Number(h.sys(0n, BigInt(fd2), BigInt(buf), 128n, 0n, 0n, 0n));
      eq(utf8Decode(h.memoryBytes(buf, n2)), 'A=1\0', 'environ through sys');
      h.sys(3n, BigInt(fd2), 0n, 0n, 0n, 0n, 0n);

      const addr = Number(h.sys(9n, 0n, 8192n, 3n, 0x22n, -1n, 0n));
      check(addr >= h.info.heapLo, 'anonymous mmap returns heap space');
      eq(Number(h.sys(11n, BigInt(addr), 8192n, 0n, 0n, 0n, 0n)), 0, 'munmap');
      eq(Number(h.sys(318n, BigInt(buf), 16n, 0n, 0n, 0n, 0n)), 16, 'getrandom');
      eq(Number(h.sys(228n, 1n, BigInt(buf), 0n, 0n, 0n, 0n)), 0, 'clock_gettime');

      const handle = h.register('app.echo', (a) => a[0] + 1n);
      h.writeMemory(path, utf8Encode('app.echo\0'));
      eq(
        Number(h.sys(22785n, BigInt(path), 8n, 0n, 0n, 0n, 0n)),
        handle,
        'HOST_SYM finds a registered function'
      );
      h.writeMemory(args, new Uint8Array(new BigInt64Array([41n]).buffer));
      eq(h.sys(22786n, BigInt(handle), BigInt(args), 1n, 0n, 0n, 0n), 42n, 'HOST_CALL result');
    });

    test('fixture run (YWhy protocol)', () => {
      const out = collector();
      const err = collector();
      const status = runBytes(buildSmokeWasm({ status: 7 }), {
        argv: ['prog'],
        env: ['A=1'],
        stdout: (b) => out.write(b),
        stderr: (b) => err.write(b),
        random: new Uint8Array(16),
      });
      eq(status, 7, 'exit status');
      eq(out.text(), 'hi\n', 'stdout');
      eq(err.text(), '', 'stderr');
    });

    test('fixture run (set_why protocol)', () => {
      const out = collector();
      const status = runBytes(buildSmokeWasm({ status: 3, setWhy: true }), {
        argv: ['prog'],
        env: [],
        stdout: (b) => out.write(b),
        stderr: () => {},
        random: new Uint8Array(16),
      });
      eq(status, 3, 'exit status through set_why');
      eq(out.text(), 'hi\n', 'stdout');
    });

    test('trap status', () => {
      for (const pair of [[4, 132], [5, 133], [8, 136], [11, 139]]) {
        const status = runBytes(buildSmokeWasm({ trapSignal: pair[0] }), {
          argv: ['prog'],
          env: [],
          stdout: () => {},
          stderr: () => {},
          random: new Uint8Array(16),
        });
        eq(status, pair[1], 'trap(' + pair[0] + ')');
      }
    });

    test('exit_group and status masking', () => {
      const out = collector();
      let status = runBytes(buildSmokeWasm({ status: 7, exitSyscall: 231 }), {
        argv: ['prog'],
        env: [],
        stdout: (b) => out.write(b),
        stderr: () => {},
        random: new Uint8Array(16),
      });
      eq(status, 7, 'exit_group(7)');
      eq(out.text(), 'hi\n', 'exit_group still wrote stdout');
      status = runBytes(buildSmokeWasm({ status: 300 }), {
        argv: ['prog'],
        env: [],
        stdout: () => {},
        stderr: () => {},
        random: new Uint8Array(16),
      });
      eq(status, 44, 'exit status is masked to 8 bits');
    });

    test('wasm runtime error status', () => {
      const err = collector();
      const status = runBytes(buildSmokeWasm({ oob: true }), {
        argv: ['prog'],
        env: [],
        stdout: () => {},
        stderr: (b) => err.write(b),
        random: new Uint8Array(16),
      });
      eq(status, 139, 'out-of-bounds is SIGSEGV');
      check(err.text().indexOf('segmentation fault (wasm:') >= 0, 'runtime error message');
    });
  }

  if (failures.length > 0) {
    for (const f of failures) console.error('selftest: FAIL ' + f);
    console.log('selftest: ' + failures.length + ' failure(s)');
    return 1;
  }
  console.log('selftest: ok');
  return 0;
}

// ---------------------------------------------------------------------------
// CLI.
// ---------------------------------------------------------------------------

function usage() {
  console.error('usage (Node 22; trap handling off):');
  console.error('  node --disable-wasm-trap-handler src/web/yhost.js run [--fuel=N] [--trace]');
  console.error('       [--display=WxH] [--events=FILE] [--display-dump=FILE]');
  console.error('       [--audio=FILE.wav] FILE.wasm [args...]');
  console.error('  node --disable-wasm-trap-handler src/web/yhost.js validate FILE.wasm');
  console.error('  node --disable-wasm-trap-handler src/web/yhost.js selftest');
}

async function main(argv) {
  const cmd = argv[0];
  if (cmd === undefined || cmd === '-h' || cmd === '--help') {
    usage();
    return cmd === undefined ? 2 : 0;
  }
  if (cmd === 'selftest') return selftest();
  if (cmd === 'validate') {
    const file = argv[1];
    if (!file) {
      usage();
      return 2;
    }
    let bytes;
    try {
      bytes = fs.readFileSync(file);
    } catch (e) {
      console.error('yhost: cannot read ' + file + ': ' + e.message);
      return 2;
    }
    const v = validateModule(bytes);
    if (!v.ok) {
      for (const e of v.errors) console.error('yhost: ' + file + ': ' + e);
      return 1;
    }
    const i = v.info;
    console.log(
      file +
        ': ok abi=' +
        i.abi +
        ' chunks=' +
        i.chunks +
        ' entry=0x' +
        i.entry.toString(16) +
        ' (chunk ' +
        i.entryChunk +
        ', case ' +
        i.entryCase +
        ') memory_min=' +
        i.memoryMin +
        ' protocol=' +
        i.protocol
    );
    return 0;
  }
  if (cmd !== 'run') {
    console.error('yhost: unknown command ' + cmd);
    usage();
    return 2;
  }

  let i = 1;
  let fuel = 1000000;
  let trace = false;
  let display = null;
  let displayDump = '';
  let eventsFile = '';
  let audio = '';
  while (i < argv.length && argv[i].startsWith('-')) {
    const a = argv[i];
    if (a === '--') {
      i++;
      break;
    }
    if (a.startsWith('--fuel=')) {
      const n = Number(a.slice('--fuel='.length));
      if (!Number.isInteger(n) || n < 1) {
        console.error('yhost: --fuel needs a positive integer');
        return 2;
      }
      fuel = n;
    } else if (a === '--trace') {
      trace = true;
    } else if (a.startsWith('--display=')) {
      const size = parseDisplaySize(a.slice('--display='.length));
      if (size === null) {
        console.error('yhost: --display needs WxH');
        return 2;
      }
      display = size;
    } else if (a.startsWith('--events=')) {
      eventsFile = a.slice('--events='.length);
      if (eventsFile === '') {
        console.error('yhost: --events needs a file');
        return 2;
      }
    } else if (a.startsWith('--display-dump=')) {
      displayDump = a.slice('--display-dump='.length);
      if (displayDump === '') {
        console.error('yhost: --display-dump needs a file');
        return 2;
      }
    } else if (a.startsWith('--audio=')) {
      audio = a.slice('--audio='.length);
      if (audio === '') {
        console.error('yhost: --audio needs a file');
        return 2;
      }
    } else {
      console.error('yhost: unknown option ' + a);
      usage();
      return 2;
    }
    i++;
  }
  const file = argv[i++];
  if (!file) {
    usage();
    return 2;
  }
  if (eventsFile !== '' && display === null) {
    console.error('yhost: --events needs --display');
    return 2;
  }
  if (eventsFile !== '') {
    try {
      display = { ...display, eventsText: fs.readFileSync(eventsFile, 'utf8') };
    } catch (e) {
      console.error('yhost: cannot read ' + eventsFile + ': ' + e.message);
      return 2;
    }
  }
  const progArgs = argv.slice(i);
  try {
    return await runFileAsync(file, {
      argv: [file].concat(progArgs),
      env: process.env,
      cwd: process.cwd(),
      fuel,
      trace,
      display,
      displayDump,
      audio,
    });
  } catch (e) {
    if (e instanceof HostError) {
      console.error('yhost: ' + file + ': ' + e.message);
      return 1;
    }
    console.error('yhost: ' + (e && e.message ? e.message : String(e)));
    return 2;
  }
}

function invokedAsScript() {
  const arg = process.argv[1];
  if (!arg) return false;
  try {
    return pathToFileURL(fs.realpathSync(arg)).href === import.meta.url;
  } catch (e) {
    return false;
  }
}

if (invokedAsScript()) {
  try {
    const code = await main(process.argv.slice(2));
    process.exitCode = code & 255;
  } catch (e) {
    console.error('yhost: internal error: ' + (e && e.stack ? e.stack : String(e)));
    process.exitCode = 134;
  }
}
