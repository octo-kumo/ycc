// src/web/test/host.test.js — the Node host against hand-built wasm modules.
//
// Run: node --disable-wasm-trap-handler --test src/web/test/host.test.js
//
// Every module is a real ABI-1 web module built by wasmgen.js; the host runs
// it through the same resume/ctx_save/why path the compiler emits.  A test
// asserts on stdout bytes (text and little-endian i64 results the fixture
// emits) and on the process status.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildScript, THREAD_FLAGS, LAYOUT } from './wasmgen.js';
import { Host, runBytes } from '../yhost.js';
import { E, O, AT, POLL } from '../abi.js';

const I64 = (b, off = 0) => b.readBigInt64LE(off);
const I32 = (b, off = 0) => b.readInt32LE(off);
const S = (b) => b.toString('latin1');

function run(items, opts = {}) {
  const bytes = buildScript(items, { setWhy: opts.setWhy });
  const out = [];
  const err = [];
  const status = runBytes(bytes, {
    argv: opts.argv || ['prog'],
    env: opts.env || [],
    cwd: opts.cwd || process.cwd(),
    fuel: opts.fuel || 1000000,
    stdout: (b) => out.push(Buffer.from(b)),
    stderr: (b) => err.push(Buffer.from(b)),
    stdin: opts.stdin,
    random: opts.random || new Uint8Array(16),
  });
  return { status, out: Buffer.concat(out), err: Buffer.concat(err) };
}

function runHost(items, opts = {}) {
  const bytes = buildScript(items, { setWhy: opts.setWhy });
  const out = [];
  const err = [];
  const host = new Host(bytes, {
    argv: opts.argv || ['prog'],
    env: opts.env || [],
    cwd: opts.cwd || process.cwd(),
    fuel: opts.fuel || 1000000,
    stdout: (b) => out.push(Buffer.from(b)),
    stderr: (b) => err.push(Buffer.from(b)),
    stdin: opts.stdin,
    random: opts.random || new Uint8Array(16),
  });
  const status = host.run();
  return { status, host, out: Buffer.concat(out), err: Buffer.concat(err) };
}

function scratch() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'yweb-test-'));
}

function cleanup(dir) {
  try {
    fs.rmSync(dir, { recursive: true, force: true });
  } catch (e) {
    /* a failed test may leave a file behind */
  }
}


// ---------------------------------------------------------------------------
// Threads: clone, gettid, exit, join through futex, preemption, yield.
// ---------------------------------------------------------------------------

function threadPrologue(stackBytes = 0x40000) {
  return [
    { op: 'sys', nr: 9, args: [0, stackBytes, 3, 0x22, -1, 0], out: 'stack' },
  ];
}

test('clone/gettid/exit/futex join', () => {
  const { status, out } = run([
    ...threadPrologue(),
    { op: 'put', addr: 'stacktop', value: { slot: 'stack', add: 0x3f000 } },
    { op: 'sys', nr: 56, args: [THREAD_FLAGS, { slot: 'stacktop' }, { addr: 'ptid' }, { addr: 'ctid' }, { addr: 'tls' }], out: 'tid', outAfter: true },
    { op: 'branchZero', to: 'child', else: 'parent' },
    { op: 'label', name: 'child' },
    { op: 'sys', nr: 186, args: [], out: 'mytid' },
    { op: 'emit', slot: 'mytid' },
    { op: 'writeStr', text: 'C' },
    { op: 'exit', code: 0, group: false },
    { op: 'label', name: 'parent' },
    { op: 'writeStr', text: 'P' },
    { op: 'sys', nr: 202, args: [{ addr: 'ctid' }, 0, { slot: 'tid' }, 0, 0, 0], out: 'fw' },
    { op: 'writeStr', text: 'J' },
    { op: 'emit', slot: 'tid' },
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 0);
  const text = S(out);
  assert.ok(text.startsWith('P'), 'parent ran first');
  assert.equal(I64(out, 1), 2n, 'child gettid');
  assert.equal(text[9], 'C');
  assert.equal(text[10], 'J');
  assert.equal(I64(out, 11), 2n, 'parent saw the same tid');
});

test('three threads, each joined through its own ctid', () => {
  const items = [...threadPrologue(0x80000)];
  const stacks = ['s1', 's2', 's3'];
  const ctids = ['c1', 'c2', 'c3'];
  const tids = ['t1', 't2', 't3'];
  stacks.forEach((s, i) => {
    items.push({ op: 'put', addr: s, value: { slot: 'stack', add: 0x10000 * (i + 1) } });
    items.push({ op: 'sys', nr: 56, args: [THREAD_FLAGS, { slot: s }, { addr: 'pt' + i }, { addr: ctids[i] }, { addr: 'tls' }], out: tids[i], outAfter: true });
    items.push({ op: 'branchZero', to: 'child', else: 'after' + i });
    items.push({ op: 'label', name: 'after' + i });
  });
  // Join in order; each wait is on that thread's ctid.
  tids.forEach((t, i) => {
    items.push({ op: 'sys', nr: 202, args: [{ addr: ctids[i] }, 0, { slot: t }, 0, 0, 0], out: 'fw' });
    items.push({ op: 'writeStr', text: 'j' });
    items.push({ op: 'emit', slot: t });
  });
  items.push({ op: 'exit', code: 0 });
  items.push({ op: 'label', name: 'child' });
  items.push({ op: 'sys', nr: 186, args: [], out: 'mytid' });
  items.push({ op: 'writeStr', text: 'c' });
  items.push({ op: 'emit', slot: 'mytid' });
  items.push({ op: 'exit', code: 0, group: false });
  const { status, out } = run(items);
  assert.equal(status, 0);
  // Layout: c tid c tid c tid j tid j tid j tid.
  assert.equal(out.length, 6 + 6 * 8);
  const childTids = [1, 10, 19].map((off) => I64(out, off));
  const joinTids = [28, 37, 46].map((off) => I64(out, off));
  assert.deepEqual(childTids.map(String).sort(), ['2', '3', '4'], 'children ran');
  assert.deepEqual(joinTids.map(String).sort(), ['2', '3', '4'], 'parent joined each');
  for (let i = 0; i < 6; i++) assert.equal(out[i * 9], i < 3 ? 0x63 : 0x6a);
});

test('preemption: a spinning thread and the parent both make progress', () => {
  const { status, out, host } = runHost([
    ...threadPrologue(),
    { op: 'put', addr: 'stacktop', value: { slot: 'stack', add: 0x3f000 } },
    { op: 'sys', nr: 56, args: [THREAD_FLAGS, { slot: 'stacktop' }, { addr: 'ptid' }, { addr: 'ctid' }, { addr: 'tls' }], out: 'tid', outAfter: true },
    { op: 'branchZero', to: 'child', else: 'parent' },
    { op: 'label', name: 'child' },
    { op: 'writeStr', text: 'c1' },
    { op: 'spin', n: 500000 },
    { op: 'writeStr', text: 'c2' },
    { op: 'exit', code: 0, group: false },
    { op: 'label', name: 'parent' },
    { op: 'writeStr', text: 'p1' },
    { op: 'spin', n: 500000 },
    { op: 'writeStr', text: 'p2' },
    { op: 'sys', nr: 202, args: [{ addr: 'ctid' }, 0, { slot: 'tid' }, 0, 0, 0], out: 'fw' },
    { op: 'writeStr', text: 'pj' },
    { op: 'exit', code: 0 },
  ], { fuel: 800 });
  assert.equal(status, 0);
  const text = S(out);
  for (const m of ['p1', 'c1', 'p2', 'c2', 'pj']) {
    assert.ok(text.includes(m), 'missing ' + m + ' in ' + JSON.stringify(text));
  }
  assert.ok(host.sched.slices > 4, 'preemption produced several slices: ' + host.sched.slices);
});

test('sched_yield and futex requeue/wake_bitset', () => {
  const { status, out } = run([
    ...threadPrologue(),
    { op: 'put', addr: 'stacktop', value: { slot: 'stack', add: 0x3f000 } },
    { op: 'sys', nr: 56, args: [THREAD_FLAGS, { slot: 'stacktop' }, { addr: 'ptid' }, { addr: 'ctid' }, { addr: 'tls' }], out: 'tid', outAfter: true },
    { op: 'branchZero', to: 'child', else: 'parent' },
    { op: 'label', name: 'child' },
    { op: 'sys', nr: 24, args: [], out: 'y' },
    { op: 'writeStr', text: 'c' },
    { op: 'exit', code: 0, group: false },
    { op: 'label', name: 'parent' },
    { op: 'writeStr', text: 'p' },
    { op: 'sys', nr: 202, args: [{ addr: 'ctid' }, 0, { slot: 'tid' }, 0, 0, 0], out: 'fw' },
    { op: 'writeStr', text: 'j' },
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 0);
  assert.equal(S(out), 'pcj');
});

test('futex requeue moves one waiter and both wake', () => {
  const items = [...threadPrologue(0x80000)];
  for (let i = 0; i < 2; i++) {
    items.push({ op: 'put', addr: 's' + i, value: { slot: 'stack', add: 0x10000 * (i + 1) } });
    items.push({ op: 'sys', nr: 56, args: [THREAD_FLAGS, { slot: 's' + i }, { addr: 'pt' + i }, { addr: 'c' + i }, { addr: 'tls' }], out: 't' + i, outAfter: true });
    items.push({ op: 'branchZero', to: 'child', else: 'a' + i });
    items.push({ op: 'label', name: 'a' + i });
  }
  items.push({ op: 'sleep', ms: 30 }); // let both children park on futex A
  items.push({ op: 'sys', nr: 202, args: [{ addr: 'A' }, 3, 0, 1, { addr: 'B' }, 0], out: 'moved' });
  items.push({ op: 'emit', slot: 'moved' });
  items.push({ op: 'sys', nr: 202, args: [{ addr: 'A' }, 1, 1, 0, 0, 0], out: 'wa' });
  items.push({ op: 'emit', slot: 'wa' });
  items.push({ op: 'sys', nr: 202, args: [{ addr: 'B' }, 1, 1, 0, 0, 0], out: 'wb' });
  items.push({ op: 'emit', slot: 'wb' });
  items.push({ op: 'sleep', ms: 30 });
  items.push({ op: 'exit', code: 0 });
  items.push({ op: 'label', name: 'child' });
  items.push({ op: 'sys', nr: 202, args: [{ addr: 'A' }, 0, 0, 0, 0, 0], out: 'fw' });
  items.push({ op: 'sys', nr: 186, args: [], out: 'mytid' });
  items.push({ op: 'writeStr', text: 'w' });
  items.push({ op: 'emit', slot: 'mytid' });
  items.push({ op: 'exit', code: 0, group: false });
  const { status, out } = run(items);
  assert.equal(status, 0);
  assert.equal(I64(out, 0), 1n, 'one waiter requeued');
  assert.equal(I64(out, 8), 1n, 'one woken on A');
  assert.equal(I64(out, 16), 1n, 'one woken on B');
  assert.equal(out.length, 24 + 2 * 9);
  const woken = [I64(out, 25), I64(out, 34)].map(String).sort();
  assert.deepEqual(woken, ['2', '3'], 'both waiters ran: ' + JSON.stringify(S(out)));
});

test('futex WAIT_BITSET is woken only by a matching bitset', () => {
  const { status, out } = run([
    ...threadPrologue(),
    { op: 'put', addr: 'stacktop', value: { slot: 'stack', add: 0x3f000 } },
    { op: 'sys', nr: 56, args: [THREAD_FLAGS, { slot: 'stacktop' }, { addr: 'ptid' }, { addr: 'ctid' }, { addr: 'tls' }], out: 'tid', outAfter: true },
    { op: 'branchZero', to: 'child', else: 'parent' },
    { op: 'label', name: 'child' },
    { op: 'sys', nr: 202, args: [{ addr: 'A' }, 9, 0, 0, 0, 1], out: 'fw' },
    { op: 'writeStr', text: 'w' },
    { op: 'exit', code: 0, group: false },
    { op: 'label', name: 'parent' },
    { op: 'sleep', ms: 30 },
    { op: 'sys', nr: 202, args: [{ addr: 'A' }, 10, 1, 0, 0, 2], out: 'n1' },
    { op: 'emit', slot: 'n1' },
    { op: 'sys', nr: 202, args: [{ addr: 'A' }, 10, 1, 0, 0, 1], out: 'n2' },
    { op: 'emit', slot: 'n2' },
    { op: 'sleep', ms: 30 },
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 0);
  assert.equal(I64(out, 0), 0n, 'bitset 2 does not wake bitset 1');
  assert.equal(I64(out, 8), 1n, 'bitset 1 wakes it');
  assert.ok(S(out.subarray(16)).includes('w'), 'the waiter ran');
});

// ---------------------------------------------------------------------------
// argv, env, the initial stack, /proc/self.
// ---------------------------------------------------------------------------

test('argv, env, /proc/self and the initial stack', () => {
  const dir = scratch();
  try {
    const { status, out } = run([
      { op: 'sys', nr: 2, args: [{ str: '/proc/self/cmdline' }, 0, 0], out: 'fd' },
      { op: 'sys', nr: 0, args: [{ slot: 'fd' }, { buf: 0 }, 128], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 128 },
      { op: 'sys', nr: 3, args: [{ slot: 'fd' }] },
      { op: 'sys', nr: 2, args: [{ str: '/proc/self/environ' }, 0, 0], out: 'fd' },
      { op: 'sys', nr: 0, args: [{ slot: 'fd' }, { buf: 0 }, 128], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 128 },
      { op: 'sys', nr: 2, args: [{ str: '/proc/self/status' }, 0, 0], out: 'fd' },
      { op: 'sys', nr: 0, args: [{ slot: 'fd' }, { buf: 0 }, 128], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 16 },
      { op: 'sys', nr: 89, args: [{ str: '/proc/self/cwd' }, { buf: 1 }, 256], out: 'n' },
      { op: 'emitMem', addr: 'buf2', count: 256 },
      { op: 'sys', nr: 89, args: [{ str: '/proc/self/exe' }, { buf: 1 }, 256], out: 'n' },
      { op: 'emitMem', addr: 'buf2', count: 256 },
      { op: 'sys', nr: 79, args: [{ buf: 1 }, 256], out: 'n' },
      { op: 'emitMem', addr: 'buf2', count: 256 },
      { op: 'exit', code: 0 },
    ], { argv: ['prog', 'arg1'], env: ['A=1', 'B=two'], cwd: dir });
    assert.equal(status, 0);
    const text = S(out);
    assert.match(text, /prog\0arg1\0/);
    assert.match(text, /A=1\0B=two\0/);
    assert.match(text, /Name:\tprog\n/);
    assert.ok(text.includes(dir), 'readlink /proc/self/cwd');
    assert.ok(text.includes('/app/prog'), 'readlink /proc/self/exe');
  } finally {
    cleanup(dir);
  }
});

// ---------------------------------------------------------------------------
// Files: open, write, lseek, read, pread/pwrite, readv/writev, truncate.
// ---------------------------------------------------------------------------

test('files: open/write/lseek/read/pread/pwrite/readv/writev/truncate', () => {
  const dir = scratch();
  const file = path.join(dir, 'f1');
  try {
    const { status, out } = run([
      { op: 'sys', nr: 2, args: [{ str: file }, O.RDWR | O.CREAT | O.TRUNC, 0o600], out: 'fd' },
      { op: 'sys', nr: 1, args: [{ slot: 'fd' }, { str: 'hello world' }, 11], out: 'n' },
      { op: 'sys', nr: 8, args: [{ slot: 'fd' }, 0, 0], out: 'pos' },
      { op: 'sys', nr: 0, args: [{ slot: 'fd' }, { buf: 0 }, 5], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 5 },
      { op: 'sys', nr: 17, args: [{ slot: 'fd' }, { buf: 0 }, 6, 6], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 6 },
      { op: 'sys', nr: 18, args: [{ slot: 'fd' }, { str: 'HELLO' }, 5, 0], out: 'n' },
      { op: 'sys', nr: 8, args: [{ slot: 'fd' }, 0, 0] },
      { op: 'sys', nr: 0, args: [{ slot: 'fd' }, { buf: 0 }, 11], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 11 },
      { op: 'sys', nr: 76, args: [{ str: file }, 5], out: 'r' },
      { op: 'sys', nr: 4, args: [{ str: file }, { buf: 1 }], out: 'r' },
      { op: 'emitMem', addr: 'buf2', add: 48, count: 8 },
      { op: 'sys', nr: 8, args: [{ slot: 'fd' }, 3, 0] },
      { op: 'put', addr: 'buf3', add: 0, value: { str: 'XYZ' } },
      { op: 'put', addr: 'buf3', add: 8, value: 3 },
      { op: 'put', addr: 'buf3', add: 16, value: { str: 'abc' } },
      { op: 'put', addr: 'buf3', add: 24, value: 3 },
      { op: 'sys', nr: 20, args: [{ slot: 'fd' }, { addr: 'buf3' }, 2], out: 'n' },
      { op: 'emit', slot: 'n' },
      { op: 'sys', nr: 8, args: [{ slot: 'fd' }, 0, 0] },
      { op: 'put', addr: 'buf3', add: 0, value: { buf: 0 } },
      { op: 'put', addr: 'buf3', add: 8, value: 3 },
      { op: 'put', addr: 'buf3', add: 16, value: { buf: 1 } },
      { op: 'put', addr: 'buf3', add: 24, value: 3 },
      { op: 'sys', nr: 19, args: [{ slot: 'fd' }, { addr: 'buf3' }, 2], out: 'n' },
      { op: 'emit', slot: 'n' },
      { op: 'emitMem', addr: 'buf', count: 3 },
      { op: 'emitMem', addr: 'buf2', count: 3 },
      { op: 'sys', nr: 77, args: [{ slot: 'fd' }, 2], out: 'r' },
      { op: 'sys', nr: 5, args: [{ slot: 'fd' }, { buf: 1 }], out: 'r' },
      { op: 'emitMem', addr: 'buf2', add: 48, count: 8 },
      { op: 'sys', nr: 3, args: [{ slot: 'fd' }] },
      { op: 'exit', code: 0 },
    ], { cwd: dir });
    assert.equal(status, 0);
    // Layout: hello | world | HELLO world | size 5 | writev 6 | readv 6 |
    // HELXYZ | size 2.
    assert.equal(S(out.subarray(0, 5)), 'hello');
    assert.equal(S(out.subarray(5, 11)), 'world\0');
    assert.equal(S(out.subarray(11, 22)), 'HELLO world');
    assert.equal(I64(out, 22), 5n, 'truncate(5)');
    assert.equal(I64(out, 30), 6n, 'writev wrote 6 bytes');
    assert.equal(I64(out, 38), 6n, 'readv read 6 bytes');
    assert.equal(S(out.subarray(46, 52)), 'HELXYZ', 'writev/readv data');
    assert.equal(I64(out, 52), 2n, 'ftruncate(2)');
    assert.equal(fs.statSync(file).size, 2);
  } finally {
    cleanup(dir);
  }
});

// ---------------------------------------------------------------------------
// stat/lstat/fstat/statx/access.
// ---------------------------------------------------------------------------

test('stat/lstat/fstat/statx/access', () => {
  const dir = scratch();
  const file = path.join(dir, 's1');
  const link = path.join(dir, 'l1');
  try {
    fs.writeFileSync(file, 'abcdef');
    fs.symlinkSync(file, link);
    const { status, out } = run([
      { op: 'sys', nr: 4, args: [{ str: file }, { buf: 0 }], out: 'r' },
      { op: 'emitMem', addr: 'buf', add: 48, count: 8 },  // size
      { op: 'emitMem', addr: 'buf', add: 24, count: 4 },  // mode
      { op: 'sys', nr: 6, args: [{ str: link }, { buf: 0 }], out: 'r' },
      { op: 'emitMem', addr: 'buf', add: 24, count: 4 },  // lstat mode: symlink
      { op: 'sys', nr: 4, args: [{ str: link }, { buf: 0 }], out: 'r' },
      { op: 'emitMem', addr: 'buf', add: 48, count: 8 },  // stat follows: 6
      { op: 'sys', nr: 332, args: [AT.FDCWD, { str: file }, 0, 0, { buf: 1 }], out: 'r' },
      { op: 'emitMem', addr: 'buf2', add: 40, count: 8 }, // statx size
      { op: 'emitMem', addr: 'buf2', add: 28, count: 2 }, // statx mode
      { op: 'sys', nr: 21, args: [{ str: file }, 0], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'sys', nr: 21, args: [{ str: path.join(dir, 'nope') }, 0], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'exit', code: 0 },
    ], { cwd: dir });
    assert.equal(status, 0);
    assert.equal(I64(out, 0), 6n, 'stat size');
    assert.equal(I32(out, 8) & 0o170000, 0o100000, 'stat mode is a regular file');
    assert.equal(I32(out, 12) & 0o170000, 0o120000, 'lstat mode is a symlink');
    assert.equal(I64(out, 16), 6n, 'stat follows the symlink');
    assert.equal(I64(out, 24), 6n, 'statx size');
    assert.equal(out.readUInt16LE(32) & 0o170000, 0o100000, 'statx mode');
    assert.equal(I64(out, 34), 0n, 'access(F_OK) succeeds');
    assert.equal(I64(out, 42), BigInt(-E.ENOENT), 'access(ENOENT)');
  } finally {
    cleanup(dir);
  }
});

// ---------------------------------------------------------------------------
// Directories and path mutation.
// ---------------------------------------------------------------------------

test('mkdir/getdents64/rename/symlink/readlink/chmod/chown/unlink/rmdir', () => {
  const dir = scratch();
  const sub = path.join(dir, 'sub');
  const file = path.join(sub, 'a.txt');
  const moved = path.join(sub, 'b.txt');
  const link = path.join(dir, 'ln');
  try {
    const { status, out } = run([
      { op: 'sys', nr: 83, args: [{ str: sub }, 0o755], out: 'r' },
      { op: 'sys', nr: 2, args: [{ str: file }, O.RDWR | O.CREAT, 0o644], out: 'fd' },
      { op: 'sys', nr: 3, args: [{ slot: 'fd' }] },
      { op: 'sys', nr: 82, args: [{ str: file }, { str: moved }], out: 'r' },
      { op: 'sys', nr: 88, args: [{ str: moved }, { str: link }], out: 'r' },
      { op: 'sys', nr: 89, args: [{ str: link }, { buf: 0 }, 256], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 256 },
      { op: 'sys', nr: 90, args: [{ str: moved }, 0o600], out: 'r' },
      { op: 'sys', nr: 4, args: [{ str: moved }, { buf: 1 }], out: 'r' },
      { op: 'emitMem', addr: 'buf2', add: 24, count: 4 },
      { op: 'sys', nr: 92, args: [{ str: moved }, 1234, 5678], out: 'r' },
      { op: 'sys', nr: 4, args: [{ str: moved }, { buf: 1 }], out: 'r' },
      { op: 'emitMem', addr: 'buf2', add: 28, count: 4 }, // uid
      { op: 'emitMem', addr: 'buf2', add: 32, count: 4 }, // gid
      { op: 'sys', nr: 2, args: [{ str: sub }, O.RDONLY | O.DIRECTORY], out: 'dfd' },
      { op: 'sys', nr: 217, args: [{ slot: 'dfd' }, { buf: 0 }, 512], out: 'n' },
      { op: 'emit', slot: 'n' },
      { op: 'emitMem', addr: 'buf', count: 512 },
      { op: 'sys', nr: 3, args: [{ slot: 'dfd' }] },
      { op: 'sys', nr: 87, args: [{ str: moved }], out: 'r' },
      { op: 'sys', nr: 87, args: [{ str: link }], out: 'r' },
      { op: 'sys', nr: 84, args: [{ str: sub }], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'exit', code: 0 },
    ], { cwd: dir });
    assert.equal(status, 0);
    const text = S(out);
    assert.ok(text.startsWith(moved), 'readlink follows the new name: ' + JSON.stringify(text.slice(0, 40)));
    // readlink emitted 256 bytes, then mode (4), uid (4), gid (4), n (8).
    const mode = I32(out, 256);
    assert.equal(mode & 0o777, 0o600, 'chmod stored');
    const after = 256 + 4;
    assert.equal(out.readUInt32LE(after), 1234, 'chown uid');
    assert.equal(out.readUInt32LE(after + 4), 5678, 'chown gid');
    const n = Number(I64(out, after + 8));
    assert.ok(n > 0, 'getdents returned records');
    const records = out.subarray(after + 16, after + 16 + n);
    const names = [];
    for (let p = 0; p + 19 <= records.length; ) {
      const reclen = records.readUInt16LE(p + 16);
      if (reclen === 0) break;
      const nameEnd = records.indexOf(0, p + 19);
      names.push(records.subarray(p + 19, nameEnd < 0 ? p + reclen : nameEnd).toString());
      p += reclen;
    }
    assert.ok(names.includes('.') && names.includes('..'), 'dot entries');
    assert.ok(names.includes('b.txt'), 'directory listing: ' + JSON.stringify(names));
    assert.equal(I64(out, out.length - 8), 0n, 'rmdir succeeds');
    assert.equal(fs.existsSync(sub), false);
  } finally {
    cleanup(dir);
  }
});

// ---------------------------------------------------------------------------
// dup/dup2/dup3/fcntl and pipes.
// ---------------------------------------------------------------------------

test('pipe2, dup/dup2/dup3, fcntl and EOF/EPIPE', () => {
  const dir = scratch();
  const file = path.join(dir, 'p1');
  try {
    const { status, out } = run([
      { op: 'sys', nr: 293, args: [{ addr: 'pfds' }, 0], out: 'w' },
      { op: 'load32', slot: 'rfd', addr: 'pfds', add: 0 },
      { op: 'load32', slot: 'wfd', addr: 'pfds', add: 4 },
      { op: 'sys', nr: 32, args: [{ slot: 'wfd' }], out: 'dupfd' },
      { op: 'sys', nr: 1, args: [{ slot: 'dupfd' }, { str: 'one' }, 3], out: 'n' },
      { op: 'sys', nr: 0, args: [{ slot: 'rfd' }, { buf: 0 }, 3], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 3 },
      { op: 'sys', nr: 33, args: [{ slot: 'wfd' }, 10], out: 'r' },
      { op: 'sys', nr: 1, args: [10, { str: 'two' }, 3], out: 'n' },
      { op: 'sys', nr: 0, args: [{ slot: 'rfd' }, { buf: 0 }, 3], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 3 },
      { op: 'sys', nr: 292, args: [{ slot: 'wfd' }, 11, O.CLOEXEC], out: 'r' },
      { op: 'sys', nr: 72, args: [11, 1, 0], out: 'r' }, // F_GETFD -> FD_CLOEXEC
      { op: 'emit', slot: 'r' },
      { op: 'sys', nr: 72, args: [{ slot: 'rfd' }, 4, O.NONBLOCK], out: 'r' }, // F_SETFL
      { op: 'sys', nr: 0, args: [{ slot: 'rfd' }, { buf: 0 }, 3], out: 'r' },
      { op: 'emit', slot: 'r' }, // -EAGAIN
      { op: 'sys', nr: 3, args: [{ slot: 'wfd' }] },
      { op: 'sys', nr: 3, args: [{ slot: 'dupfd' }] },
      { op: 'sys', nr: 3, args: [10] },
      { op: 'sys', nr: 3, args: [11] },
      { op: 'sys', nr: 0, args: [{ slot: 'rfd' }, { buf: 0 }, 3], out: 'r' },
      { op: 'emit', slot: 'r' }, // 0 (EOF)
      { op: 'sys', nr: 3, args: [{ slot: 'rfd' }] },
      { op: 'sys', nr: 293, args: [{ addr: 'pfds' }, 0], out: 'w' },
      { op: 'load32', slot: 'rfd', addr: 'pfds', add: 0 },
      { op: 'load32', slot: 'wfd', addr: 'pfds', add: 4 },
      { op: 'sys', nr: 3, args: [{ slot: 'rfd' }] },
      { op: 'sys', nr: 1, args: [{ slot: 'wfd' }, { str: 'x' }, 1], out: 'r' },
      { op: 'emit', slot: 'r' }, // -EPIPE
      { op: 'exit', code: 0 },
    ], { cwd: dir });
    assert.equal(status, 0);
    const text = S(out);
    assert.ok(text.startsWith('onetwo'), 'dup shares the pipe: ' + JSON.stringify(text.slice(0, 10)));
    const base = text.indexOf('onetwo') + 6;
    const vals = [];
    for (let i = base; i + 8 <= out.length; i += 8) vals.push(I64(out, i));
    assert.equal(vals[0], 1n, 'F_GETFD sees FD_CLOEXEC');
    assert.equal(vals[1], BigInt(-E.EAGAIN), 'O_NONBLOCK read is EAGAIN');
    assert.equal(vals[2], 0n, 'EOF after the writers close');
    assert.equal(vals[3], BigInt(-E.EPIPE), 'write with no reader is EPIPE');
  } finally {
    cleanup(dir);
  }
});

// ---------------------------------------------------------------------------
// poll/ppoll/select/pselect6: readiness, timeout and blocking wakeups.
// ---------------------------------------------------------------------------

test('poll and ppoll: readiness, timeout, blocking wakeup', () => {
  const dir = scratch();
  try {
    const items = [
      { op: 'sys', nr: 293, args: [{ addr: 'pfds' }, 0], out: 'w' },
      { op: 'load32', slot: 'rfd', addr: 'pfds', add: 0 },
      { op: 'load32', slot: 'wfd', addr: 'pfds', add: 4 },
      // poll(empty read end, POLLIN, 0) -> 0
      { op: 'put32', addr: 'buf', add: 0, value: { slot: 'rfd' } },
      { op: 'put16', addr: 'buf', add: 4, value: POLL.IN },
      { op: 'sys', nr: 7, args: [{ buf: 0 }, 1, 0], out: 'n' },
      { op: 'emit', slot: 'n' },
      // write, then poll -> 1 and POLLIN
      { op: 'sys', nr: 1, args: [{ slot: 'wfd' }, { str: 'x' }, 1], out: 'n' },
      { op: 'sys', nr: 7, args: [{ buf: 0 }, 1, 0], out: 'n' },
      { op: 'emit', slot: 'n' },
      { op: 'load16', slot: 'rev', addr: 'buf', add: 6 },
      { op: 'emit', slot: 'rev' },
      { op: 'sys', nr: 0, args: [{ slot: 'rfd' }, { buf: 1 }, 1], out: 'n' },
      { op: 'emitMem', addr: 'buf2', count: 1 },
      // poll the write end for POLLOUT
      { op: 'put32', addr: 'buf', add: 0, value: { slot: 'wfd' } },
      { op: 'put16', addr: 'buf', add: 4, value: POLL.OUT },
      { op: 'sys', nr: 7, args: [{ buf: 0 }, 1, 0], out: 'n' },
      { op: 'emit', slot: 'n' },
      // close the writer: the read end reports POLLHUP
      { op: 'sys', nr: 3, args: [{ slot: 'wfd' }] },
      { op: 'put32', addr: 'buf', add: 0, value: { slot: 'rfd' } },
      { op: 'put16', addr: 'buf', add: 4, value: POLL.IN },
      { op: 'sys', nr: 7, args: [{ buf: 0 }, 1, 0], out: 'n' },
      { op: 'load16', slot: 'rev', addr: 'buf', add: 6 },
      { op: 'emit', slot: 'rev' },
      // ppoll with a 25ms timeout on a fresh empty pipe
      { op: 'sys', nr: 293, args: [{ addr: 'pfds' }, 0], out: 'w' },
      { op: 'load32', slot: 'rfd', addr: 'pfds', add: 0 },
      { op: 'put32', addr: 'buf', add: 0, value: { slot: 'rfd' } },
      { op: 'put16', addr: 'buf', add: 4, value: POLL.IN },
      { op: 'put', addr: 'ts', add: 0, value: 0 },
      { op: 'put', addr: 'ts', add: 8, value: 25000000 },
      { op: 'sys', nr: 271, args: [{ buf: 0 }, 1, { addr: 'ts' }, 0, 0], out: 'n' },
      { op: 'emit', slot: 'n' },
      { op: 'exit', code: 0 },
    ];
    const { status, out, host } = runHost(items, { cwd: dir });
    assert.equal(status, 0);
    assert.equal(I64(out, 0), 0n, 'empty poll with timeout 0');
    assert.equal(I64(out, 8), 1n, 'poll after write');
    assert.equal(I64(out, 16), BigInt(POLL.IN), 'POLLIN');
    assert.equal(out[24], 0x78, 'read got x');
    assert.equal(I64(out, 25), 1n, 'write end is POLLOUT');
    assert.equal(I64(out, 33), BigInt(POLL.HUP), 'read end is POLLHUP after close');
    assert.equal(I64(out, 41), 0n, 'ppoll timed out');
  } finally {
    cleanup(dir);
  }
});

test('poll blocks until a writer thread writes', () => {
  const items = [
    { op: 'sys', nr: 293, args: [{ addr: 'pfds' }, 0], out: 'w' },
    { op: 'load32', slot: 'rfd', addr: 'pfds', add: 0 },
    { op: 'load32', slot: 'wfd', addr: 'pfds', add: 4 },
    ...threadPrologue(),
    { op: 'put', addr: 'stacktop', value: { slot: 'stack', add: 0x3f000 } },
    { op: 'sys', nr: 56, args: [THREAD_FLAGS, { slot: 'stacktop' }, { addr: 'ptid' }, { addr: 'ctid' }, { addr: 'tls' }], out: 'tid', outAfter: true },
    { op: 'branchZero', to: 'child', else: 'parent' },
    { op: 'label', name: 'child' },
    { op: 'sleep', ms: 30 },
    { op: 'sys', nr: 1, args: [{ slot: 'wfd' }, { str: 'z' }, 1], out: 'n' },
    { op: 'exit', code: 0, group: false },
    { op: 'label', name: 'parent' },
    { op: 'put32', addr: 'buf', add: 0, value: { slot: 'rfd' } },
    { op: 'put16', addr: 'buf', add: 4, value: POLL.IN },
    { op: 'sys', nr: 7, args: [{ buf: 0 }, 1, -1], out: 'n' },
    { op: 'emit', slot: 'n' },
    { op: 'load16', slot: 'rev', addr: 'buf', add: 6 },
    { op: 'emit', slot: 'rev' },
    { op: 'sys', nr: 0, args: [{ slot: 'rfd' }, { buf: 1 }, 1], out: 'n' },
    { op: 'emitMem', addr: 'buf2', count: 1 },
    { op: 'exit', code: 0 },
  ];
  const { status, out, host } = runHost(items);
  assert.equal(status, 0);
  assert.equal(I64(out, 0), 1n, 'poll woke with one descriptor');
  assert.equal(I64(out, 8), BigInt(POLL.IN));
  assert.equal(out[16], 0x7a, 'read the byte the child wrote');
});

test('select and pselect6', () => {
  const dir = scratch();
  try {
    const items = [
      { op: 'sys', nr: 293, args: [{ addr: 'pfds' }, 0], out: 'w' },
      { op: 'load32', slot: 'rfd', addr: 'pfds', add: 0 },
      { op: 'load32', slot: 'wfd', addr: 'pfds', add: 4 },
      { op: 'sys', nr: 1, args: [{ slot: 'wfd' }, { str: 'q' }, 1], out: 'n' },
      // select(readfds={rfd}, 0, 0, 0)
      { op: 'put8', addr: 'buf2', add: 0, value: 1 },
      { op: 'sys', nr: 23, args: [16, { buf: 1 }, 0, 0, 0], out: 'n' },
      { op: 'emit', slot: 'n' },
      { op: 'load8', slot: 'bit', addr: 'buf2', add: 0 },
      { op: 'emit', slot: 'bit' },
      { op: 'sys', nr: 0, args: [{ slot: 'rfd' }, { buf: 0 }, 1], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 1 },
      // pselect6 on an empty pipe with a 20ms timeout -> 0
      { op: 'put8', addr: 'buf2', add: 0, value: 0 },
      { op: 'put', addr: 'ts', add: 0, value: 0 },
      { op: 'put', addr: 'ts', add: 8, value: 20000000 },
      { op: 'sys', nr: 270, args: [16, { buf: 1 }, 0, 0, { addr: 'ts' }, 0], out: 'n' },
      { op: 'emit', slot: 'n' },
      { op: 'exit', code: 0 },
    ];
    const { status, out } = runHost(items, { cwd: dir });
    assert.equal(status, 0);
    assert.equal(I64(out, 0), 1n, 'select found the readable fd');
    assert.equal(I64(out, 8), 1n, 'read fd bit stays set');
    assert.equal(out[16], 0x71, 'select read q');
    assert.equal(I64(out, 17), 0n, 'pselect6 timed out');
  } finally {
    cleanup(dir);
  }
});

// ---------------------------------------------------------------------------
// Memory: mmap/munmap/mremap/mprotect/brk.
// ---------------------------------------------------------------------------

test('mmap, mremap, munmap and brk', () => {
  const { status, out } = run([
    { op: 'sys', nr: 9, args: [0, 8192, 3, 0x22, -1, 0], out: 'a' },
    { op: 'put', at: { slot: 'a' }, value: 0x1122334455667788n },
    { op: 'sys', nr: 25, args: [{ slot: 'a' }, 8192, 16384, 1, 0], out: 'b' },
    { op: 'emit', slot: 'a' },
    { op: 'emit', slot: 'b' },
    { op: 'load', slot: 'v', at: { slot: 'b' } },
    { op: 'emit', slot: 'v' },
    { op: 'sys', nr: 10, args: [{ slot: 'b' }, 16384, 0], out: 'r' },
    { op: 'emit', slot: 'r' },
    { op: 'sys', nr: 11, args: [{ slot: 'b' }, 16384], out: 'r' },
    { op: 'emit', slot: 'r' },
    { op: 'sys', nr: 9, args: [0, 4096, 3, 0x22, -1, 0], out: 'c' },
    { op: 'sys', nr: 25, args: [{ slot: 'c' }, 4096, 8192, 0, 0], out: 'r' },
    { op: 'emit', slot: 'r' },
    { op: 'sys', nr: 12, args: [0], out: 'brk' },
    { op: 'emit', slot: 'brk' },
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 0);
  const a = I64(out, 0);
  const b = I64(out, 8);
  assert.ok(a > 0n && b > 0n);
  assert.notEqual(a, b, 'mremap moved');
  assert.equal(I64(out, 16), 0x1122334455667788n, 'mremap copied the bytes');
  assert.equal(I64(out, 24), 0n, 'mprotect');
  assert.equal(I64(out, 32), 0n, 'munmap');
  assert.equal(I64(out, 40), BigInt(-E.ENOMEM), 'mremap without MAYMOVE cannot grow');
  assert.equal(I64(out, 48), BigInt(LAYOUT.HEAP_LO), 'brk is the fixed heap start');
});

// ---------------------------------------------------------------------------
// Time: clocks, nanosleep, clock_nanosleep and ordering between threads.
// ---------------------------------------------------------------------------

test('clock_gettime, nanosleep, clock_nanosleep', () => {
  const { status, out, host } = runHost([
    { op: 'sys', nr: 228, args: [1, { buf: 0 }], out: 'r' },
    { op: 'emitMem', addr: 'buf', count: 16 },
    { op: 'sleep', ms: 25 },
    { op: 'sys', nr: 228, args: [1, { buf: 0 }], out: 'r' },
    { op: 'emitMem', addr: 'buf', count: 16 },
    { op: 'sys', nr: 228, args: [0, { buf: 1 }], out: 'r' },
    { op: 'emitMem', addr: 'buf2', count: 16 },
    // absolute clock_nanosleep: now + 15ms
    { op: 'sys', nr: 228, args: [1, { buf: 0 }], out: 'r' },
    { op: 'put', addr: 'ts', add: 0, value: { slot: 'unused' } },
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 0);
  const s1 = I64(out, 0);
  const n1 = I64(out, 8);
  const s2 = I64(out, 16);
  const n2 = I64(out, 24);
  assert.ok(n1 >= 0n && n1 < 1000000000n);
  assert.ok(n2 >= 0n && n2 < 1000000000n);
  const t1 = s1 * 1000000000n + n1;
  const t2 = s2 * 1000000000n + n2;
  assert.ok(t2 >= t1 + 15000000n, 'monotonic advanced by the sleep');
  const realtime = I64(out, 32) * 1000000000n + I64(out, 40);
  assert.ok(realtime > 1500000000n * 1000000000n, 'realtime is a real date');
});

test('sleep order between threads', () => {
  const { status, out } = run([
    ...threadPrologue(),
    { op: 'put', addr: 'stacktop', value: { slot: 'stack', add: 0x3f000 } },
    { op: 'sys', nr: 56, args: [THREAD_FLAGS, { slot: 'stacktop' }, { addr: 'ptid' }, { addr: 'ctid' }, { addr: 'tls' }], out: 'tid', outAfter: true },
    { op: 'branchZero', to: 'child', else: 'parent' },
    { op: 'label', name: 'child' },
    { op: 'sleep', ms: 10 },
    { op: 'writeStr', text: 'c' },
    { op: 'exit', code: 0, group: false },
    { op: 'label', name: 'parent' },
    { op: 'sleep', ms: 80 },
    { op: 'writeStr', text: 'p' },
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 0);
  assert.equal(S(out), 'cp', 'the shorter sleep writes first');
});

// ---------------------------------------------------------------------------
// memfd, eventfd, timerfd.
// ---------------------------------------------------------------------------

test('memfd_create and its read/write/truncate/stat', () => {
  const { status, out } = run([
    { op: 'sys', nr: 319, args: [{ str: 'm1' }, 0], out: 'fd' },
    { op: 'sys', nr: 1, args: [{ slot: 'fd' }, { str: 'abc' }, 3], out: 'n' },
    { op: 'sys', nr: 8, args: [{ slot: 'fd' }, 0, 0], out: 'p' },
    { op: 'sys', nr: 0, args: [{ slot: 'fd' }, { buf: 0 }, 3], out: 'n' },
    { op: 'emitMem', addr: 'buf', count: 3 },
    { op: 'sys', nr: 77, args: [{ slot: 'fd' }, 5], out: 'r' },
    { op: 'sys', nr: 5, args: [{ slot: 'fd' }, { buf: 1 }], out: 'r' },
    { op: 'emitMem', addr: 'buf2', add: 48, count: 8 },
    { op: 'sys', nr: 89, args: [{ str: '/proc/self/fd/3' }, { buf: 0 }, 64], out: 'n' },
    { op: 'emitMem', addr: 'buf', count: 64 },
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 0);
  assert.equal(S(out.subarray(0, 3)), 'abc');
  assert.equal(I64(out, 3), 5n, 'ftruncate size');
  assert.ok(S(out.subarray(11)).startsWith('memfd:m1'), 'memfd link');
});

test('eventfd counters, semaphore mode and non-blocking EAGAIN', () => {
  const { status, out } = run([
    { op: 'sys', nr: 290, args: [0, 0x800], out: 'fd' },
    { op: 'sys', nr: 0, args: [{ slot: 'fd' }, { buf: 0 }, 8], out: 'r' },
    { op: 'emit', slot: 'r' }, // -EAGAIN
    { op: 'put', addr: 'buf', add: 0, value: 5 },
    { op: 'sys', nr: 1, args: [{ slot: 'fd' }, { buf: 0 }, 8], out: 'n' },
    { op: 'sys', nr: 0, args: [{ slot: 'fd' }, { buf: 1 }, 8], out: 'n' },
    { op: 'emitMem', addr: 'buf2', count: 8 },
    { op: 'sys', nr: 290, args: [0, 0x801], out: 'sfd' }, // SEMAPHORE|NONBLOCK
    { op: 'put', addr: 'buf', add: 0, value: 3 },
    { op: 'sys', nr: 1, args: [{ slot: 'sfd' }, { buf: 0 }, 8], out: 'n' },
    { op: 'sys', nr: 0, args: [{ slot: 'sfd' }, { buf: 1 }, 8], out: 'n' },
    { op: 'emitMem', addr: 'buf2', count: 8 },
    { op: 'sys', nr: 0, args: [{ slot: 'sfd' }, { buf: 1 }, 8], out: 'n' },
    { op: 'emitMem', addr: 'buf2', count: 8 },
    { op: 'sys', nr: 0, args: [{ slot: 'sfd' }, { buf: 1 }, 8], out: 'n' },
    { op: 'emitMem', addr: 'buf2', count: 8 },
    { op: 'sys', nr: 0, args: [{ slot: 'sfd' }, { buf: 1 }, 8], out: 'r' },
    { op: 'emit', slot: 'r' }, // -EAGAIN
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 0);
  assert.equal(I64(out, 0), BigInt(-E.EAGAIN), 'empty eventfd is EAGAIN');
  assert.equal(I64(out, 8), 5n, 'eventfd read 5');
  assert.equal(I64(out, 16), 1n, 'semaphore read 1');
  assert.equal(I64(out, 24), 1n, 'semaphore read 1 again');
  assert.equal(I64(out, 32), 1n, 'semaphore read 1 a third time');
  assert.equal(I64(out, 40), BigInt(-E.EAGAIN), 'semaphore is empty');
});

test('timerfd one-shot and interval expirations', () => {
  const items = [
    { op: 'sys', nr: 283, args: [1, 0], out: 'fd' },
    { op: 'put', addr: 'its', add: 0, value: 0 },
    { op: 'put', addr: 'its', add: 8, value: 0 },
    { op: 'put', addr: 'its', add: 16, value: 0 },
    { op: 'put', addr: 'its', add: 24, value: 20000000 },
    { op: 'sys', nr: 286, args: [{ slot: 'fd' }, 0, { addr: 'its' }, 0], out: 'r' },
    { op: 'sys', nr: 7, args: [{ buf: 0 }, 1, 0], out: 'p' },
    { op: 'emit', slot: 'p' }, // 0: not yet due
    { op: 'put32', addr: 'buf', add: 0, value: { slot: 'fd' } },
    { op: 'put16', addr: 'buf', add: 4, value: POLL.IN },
    { op: 'sys', nr: 0, args: [{ slot: 'fd' }, { buf: 1 }, 8], out: 'n' },
    { op: 'emitMem', addr: 'buf2', count: 8 },
    // interval: 5ms value, 10ms period; sleep 35ms, read the count
    { op: 'put', addr: 'its', add: 0, value: 0 },
    { op: 'put', addr: 'its', add: 8, value: 10000000 },
    { op: 'put', addr: 'its', add: 16, value: 0 },
    { op: 'put', addr: 'its', add: 24, value: 5000000 },
    { op: 'sys', nr: 286, args: [{ slot: 'fd' }, 0, { addr: 'its' }, 0], out: 'r' },
    { op: 'sleep', ms: 40 },
    { op: 'sys', nr: 0, args: [{ slot: 'fd' }, { buf: 1 }, 8], out: 'n' },
    { op: 'emitMem', addr: 'buf2', count: 8 },
    { op: 'exit', code: 0 },
  ];
  const { status, out, host } = runHost(items);
  assert.equal(status, 0);
  assert.equal(I64(out, 0), 0n, 'timerfd not ready before the deadline');
  assert.equal(I64(out, 8), 1n, 'one expiration');
  assert.ok(I64(out, 16) >= 2n, 'interval produced several expirations: ' + I64(out, 16));
});

// ---------------------------------------------------------------------------
// /dev and the rest of /proc.
// ---------------------------------------------------------------------------

test('/dev/null, /dev/zero, /dev/urandom, /dev/tty', () => {
  const { status, out } = run([
    { op: 'sys', nr: 2, args: [{ str: '/dev/null' }, O.RDWR], out: 'fd' },
    { op: 'sys', nr: 1, args: [{ slot: 'fd' }, { str: 'abc' }, 3], out: 'n' },
    { op: 'emit', slot: 'n' },
    { op: 'sys', nr: 0, args: [{ slot: 'fd' }, { buf: 0 }, 3], out: 'n' },
    { op: 'emit', slot: 'n' },
    { op: 'sys', nr: 2, args: [{ str: '/dev/zero' }, O.RDONLY], out: 'z' },
    { op: 'sys', nr: 0, args: [{ slot: 'z' }, { buf: 0 }, 4], out: 'n' },
    { op: 'emitMem', addr: 'buf', count: 4 },
    { op: 'sys', nr: 2, args: [{ str: '/dev/urandom' }, O.RDONLY], out: 'u' },
    { op: 'sys', nr: 0, args: [{ slot: 'u' }, { buf: 1 }, 8], out: 'n' },
    { op: 'emit', slot: 'n' },
    { op: 'sys', nr: 2, args: [{ str: '/dev/tty' }, O.RDONLY], out: 't' },
    { op: 'emit', slot: 't' },
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 0);
  assert.equal(I64(out, 0), 3n, 'write to /dev/null');
  assert.equal(I64(out, 8), 0n, 'read from /dev/null');
  assert.deepEqual([...out.subarray(16, 20)], [0, 0, 0, 0], '/dev/zero');
  assert.equal(I64(out, 20), 8n, '/dev/urandom read');
  assert.equal(I64(out, 28), BigInt(-E.ENXIO), '/dev/tty is ENXIO');
});

test('/proc/self/fd, maps and statm', () => {
  const { status, out } = run([
    { op: 'sys', nr: 89, args: [{ str: '/proc/self/fd/1' }, { buf: 0 }, 64], out: 'n' },
    { op: 'emitMem', addr: 'buf', count: 64 },
    { op: 'sys', nr: 2, args: [{ str: '/proc/self/fd' }, O.RDONLY | O.DIRECTORY], out: 'dfd' },
    { op: 'sys', nr: 217, args: [{ slot: 'dfd' }, { buf: 1 }, 512], out: 'n' },
    { op: 'emit', slot: 'n' },
    { op: 'emitMem', addr: 'buf2', count: 512 },
    { op: 'sys', nr: 2, args: [{ str: '/proc/self/maps' }, O.RDONLY], out: 'm' },
    { op: 'sys', nr: 0, args: [{ slot: 'm' }, { buf: 0 }, 512], out: 'n' },
    { op: 'emitMem', addr: 'buf', count: 512 },
    { op: 'sys', nr: 2, args: [{ str: '/proc/self/statm' }, O.RDONLY], out: 's' },
    { op: 'sys', nr: 0, args: [{ slot: 's' }, { buf: 1 }, 64], out: 'n' },
    { op: 'emitMem', addr: 'buf2', count: 64 },
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 0);
  assert.equal(S(out.subarray(0, 11)), '/dev/stdout');
  const n = Number(I64(out, 64));
  assert.ok(n > 0);
  const recs = out.subarray(72, 72 + n);
  const names = [];
  for (let p = 0; p + 19 <= recs.length; ) {
    const reclen = recs.readUInt16LE(p + 16);
    if (!reclen) break;
    const z = recs.indexOf(0, p + 19);
    names.push(recs.subarray(p + 19, z).toString());
    p += reclen;
  }
  for (const fd of ['0', '1', '2']) assert.ok(names.includes(fd), 'fd ' + fd + ' listed');
  const mapsOff = 64 + 8 + 512;
  const maps = S(out.subarray(mapsOff, mapsOff + 512));
  assert.ok(maps.includes('[stack]'), 'maps has a stack');
  assert.ok(maps.includes('[heap]'), 'maps has a heap');
  assert.match(S(out.subarray(mapsOff + 512, mapsOff + 576)), /^\d+ \d+/);
});

// ---------------------------------------------------------------------------
// The at-variants, umask, fchdir and open flag errors.
// ---------------------------------------------------------------------------

test('at-variants, umask, fchdir and open flag errors', () => {
  const dir = scratch();
  try {
    const { status, out } = run([
      { op: 'sys', nr: 95, args: [0o077], out: 'oldmask' },
      { op: 'emit', slot: 'oldmask' },
      { op: 'sys', nr: 258, args: [AT.FDCWD, { str: 'd1' }, 0o777], out: 'r' },
      { op: 'sys', nr: 4, args: [{ str: 'd1' }, { buf: 0 }], out: 'r' },
      { op: 'emitMem', addr: 'buf', add: 24, count: 4 },
      { op: 'sys', nr: 266, args: [{ str: 'target' }, AT.FDCWD, { str: 'ln1' }], out: 'r' },
      { op: 'sys', nr: 267, args: [AT.FDCWD, { str: 'ln1' }, { buf: 1 }, 64], out: 'n' },
      { op: 'emitMem', addr: 'buf2', count: 64 },
      { op: 'sys', nr: 268, args: [AT.FDCWD, { str: 'd1' }, 0o700, 0], out: 'r' },
      { op: 'sys', nr: 269, args: [AT.FDCWD, { str: 'd1' }, 0, 0], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'sys', nr: 260, args: [AT.FDCWD, { str: 'd1' }, 7, 8, 0], out: 'r' },
      { op: 'sys', nr: 4, args: [{ str: 'd1' }, { buf: 0 }], out: 'r' },
      { op: 'emitMem', addr: 'buf', add: 28, count: 4 },
      { op: 'emitMem', addr: 'buf', add: 32, count: 4 },
      { op: 'sys', nr: 264, args: [AT.FDCWD, { str: 'd1' }, AT.FDCWD, { str: 'd2' }], out: 'r' },
      { op: 'sys', nr: 2, args: [{ str: 'd2' }, O.RDONLY | O.DIRECTORY], out: 'dfd' },
      { op: 'sys', nr: 81, args: [{ slot: 'dfd' }], out: 'r' },
      { op: 'sys', nr: 79, args: [{ buf: 1 }, 256], out: 'n' },
      { op: 'emitMem', addr: 'buf2', count: 256 },
      { op: 'sys', nr: 2, args: [{ str: 'f1' }, O.RDWR | O.CREAT | O.EXCL, 0o600], out: 'fd' },
      { op: 'sys', nr: 3, args: [{ slot: 'fd' }] },
      { op: 'sys', nr: 2, args: [{ str: 'f1' }, O.RDWR | O.CREAT | O.EXCL, 0o600], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'sys', nr: 2, args: [{ str: 'f1' }, O.RDONLY | O.DIRECTORY], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'sys', nr: 2, args: [{ str: path.join(dir, 'ln1') }, O.RDONLY | O.NOFOLLOW], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'sys', nr: 263, args: [AT.FDCWD, { str: path.join(dir, 'd2', 'f1') }, 0], out: 'r' },
      { op: 'sys', nr: 263, args: [AT.FDCWD, { str: path.join(dir, 'd2') }, AT.REMOVEDIR], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'exit', code: 0 },
    ], { cwd: dir });
    assert.equal(status, 0);
    assert.equal(I64(out, 0), 0o022n, 'umask returned the old mask');
    const mode = out.readUInt32LE(8);
    assert.equal(mode & 0o777, 0o700, 'mkdir honoured umask 077');
    assert.equal(S(out.subarray(12, 18)), 'target', 'readlinkat');
    assert.equal(I64(out, 12 + 64), 0n, 'faccessat');
    assert.equal(out.readUInt32LE(12 + 64 + 8), 7, 'fchownat uid');
    assert.equal(out.readUInt32LE(12 + 64 + 12), 8, 'fchownat gid');
    const cwd = S(out.subarray(12 + 64 + 16, 12 + 64 + 16 + 256));
    assert.ok(cwd.startsWith(dir + '/d2'), 'fchdir + getcwd: ' + JSON.stringify(cwd.slice(0, 80)));
    const base = 12 + 64 + 16 + 256;
    assert.equal(I64(out, base), BigInt(-E.EEXIST), 'O_EXCL on an existing file');
    assert.equal(I64(out, base + 8), BigInt(-E.ENOTDIR), 'O_DIRECTORY on a file');
    assert.equal(I64(out, base + 16), BigInt(-E.ELOOP), 'O_NOFOLLOW on a symlink');
    assert.equal(I64(out, base + 24), 0n, 'unlinkat(REMOVEDIR)');
    assert.equal(fs.existsSync(path.join(dir, 'd2')), false);
  } finally {
    cleanup(dir);
  }
});

// ---------------------------------------------------------------------------
// clone3, statx(AT_EMPTY_PATH), ioctl, fcntl F_DUPFD, uname/sysinfo/limits.
// ---------------------------------------------------------------------------

test('clone3 creates a thread like clone', () => {
  const { status, out } = run([
    ...threadPrologue(),
    { op: 'put', addr: 'stacktop', value: { slot: 'stack', add: 0x3f000 } },
    { op: 'put', addr: 'ca', add: 0, value: THREAD_FLAGS },
    { op: 'put', addr: 'ca', add: 16, value: { addr: 'ctid' } },
    { op: 'put', addr: 'ca', add: 24, value: { addr: 'ptid' } },
    { op: 'put', addr: 'ca', add: 40, value: { slot: 'stack' } },
    { op: 'put', addr: 'ca', add: 48, value: 0x3f000 },
    { op: 'put', addr: 'ca', add: 56, value: { addr: 'tls' } },
    { op: 'sys', nr: 435, args: [{ addr: 'ca' }, 64], out: 'tid', outAfter: true },
    { op: 'branchZero', to: 'child', else: 'parent' },
    { op: 'label', name: 'child' },
    { op: 'writeStr', text: 'C' },
    { op: 'exit', code: 0, group: false },
    { op: 'label', name: 'parent' },
    { op: 'sys', nr: 202, args: [{ addr: 'ctid' }, 0, { slot: 'tid' }, 0, 0, 0], out: 'fw' },
    { op: 'writeStr', text: 'J' },
    { op: 'emit', slot: 'tid' },
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 0);
  assert.equal(S(out).slice(0, 2), 'CJ', 'child then join: ' + JSON.stringify(S(out)));
  assert.equal(I64(out, 2), 2n, 'clone3 tid');
});

test('statx(AT_EMPTY_PATH), ioctl FIONREAD/FIONBIO, fcntl F_DUPFD', () => {
  const dir = scratch();
  const file = path.join(dir, 'io');
  try {
    const { status, out } = run([
      { op: 'sys', nr: 2, args: [{ str: file }, O.RDWR | O.CREAT, 0o644], out: 'fd' },
      { op: 'sys', nr: 1, args: [{ slot: 'fd' }, { str: '12345' }, 5], out: 'n' },
      { op: 'sys', nr: 332, args: [{ slot: 'fd' }, { str: '' }, AT.EMPTY_PATH, 0, { buf: 0 }], out: 'r' },
      { op: 'emitMem', addr: 'buf', add: 40, count: 8 },
      { op: 'sys', nr: 72, args: [{ slot: 'fd' }, 0, 20], out: 'dupfd' },
      { op: 'emit', slot: 'dupfd' },
      { op: 'sys', nr: 16, args: [{ slot: 'fd' }, 0x541b, { buf: 1 }], out: 'r' },
      { op: 'emitMem', addr: 'buf2', count: 4 },
      { op: 'sys', nr: 293, args: [{ addr: 'pfds' }, 0], out: 'w' },
      { op: 'load32', slot: 'rfd', addr: 'pfds', add: 0 },
      { op: 'sys', nr: 16, args: [{ slot: 'rfd' }, 0x541b, { buf: 1 }], out: 'r' },
      { op: 'emitMem', addr: 'buf2', count: 4 },
      { op: 'put32', addr: 'buf2', add: 0, value: 1 },
      { op: 'sys', nr: 16, args: [{ slot: 'rfd' }, 0x5421, { buf: 1 }], out: 'r' },
      { op: 'sys', nr: 0, args: [{ slot: 'rfd' }, { buf: 0 }, 4], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'sys', nr: 16, args: [{ slot: 'fd' }, 0x5401, { buf: 1 }], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'exit', code: 0 },
    ], { cwd: dir });
    assert.equal(status, 0);
    assert.equal(I64(out, 0), 5n, 'statx AT_EMPTY_PATH size');
    assert.equal(I64(out, 8), 20n, 'F_DUPFD chose fd 20');
    assert.equal(out.readUInt32LE(16), 0, 'FIONREAD after the position moved');
    assert.equal(out.readUInt32LE(20), 0, 'FIONREAD on an empty pipe');
    assert.equal(I64(out, 24), BigInt(-E.EAGAIN), 'FIONBIO made the read non-blocking');
    assert.equal(I64(out, 32), BigInt(-E.ENOTTY), 'TCGETS is ENOTTY');
  } finally {
    cleanup(dir);
  }
});

test('uname, sysinfo, rlimits, getrusage, times, ids, getrandom', () => {
  const { status, out } = run([
    { op: 'sys', nr: 63, args: [{ buf: 0 }], out: 'r' },
    { op: 'emitMem', addr: 'buf', count: 390 },
    { op: 'sys', nr: 99, args: [{ buf: 1 }], out: 'r' },
    { op: 'emitMem', addr: 'buf2', add: 104, count: 4 }, // mem_unit
    { op: 'emitMem', addr: 'buf2', add: 32, count: 8 }, // totalram
    { op: 'sys', nr: 97, args: [3, { buf: 0 }], out: 'r' },
    { op: 'emitMem', addr: 'buf', count: 16 },
    { op: 'sys', nr: 98, args: [0, { buf: 1 }], out: 'r' },
    { op: 'emitMem', addr: 'buf2', count: 8 },
    { op: 'sys', nr: 100, args: [{ buf: 0 }], out: 'ticks' },
    { op: 'emit', slot: 'ticks' },
    { op: 'sys', nr: 39, args: [], out: 'v' }, { op: 'emit', slot: 'v' },
    { op: 'sys', nr: 110, args: [], out: 'v' }, { op: 'emit', slot: 'v' },
    { op: 'sys', nr: 102, args: [], out: 'v' }, { op: 'emit', slot: 'v' },
    { op: 'sys', nr: 186, args: [], out: 'v' }, { op: 'emit', slot: 'v' },
    { op: 'sys', nr: 318, args: [{ buf: 1 }, 16, 0], out: 'n' },
    { op: 'emit', slot: 'n' },
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 0);
  const uname = S(out.subarray(0, 390));
  assert.equal(uname.slice(0, 5), 'Linux', 'uname sysname');
  assert.equal(uname.slice(65, 68), 'web', 'uname nodename');
  assert.equal(uname.slice(130, 140), '6.0.0-yweb', 'uname release');
  assert.equal(uname.slice(195, 197), '#1', 'uname version');
  assert.equal(uname.slice(260, 266), 'wasm32', 'uname machine');
  assert.equal(out.readUInt32LE(390), 1, 'sysinfo mem_unit');
  assert.ok(I64(out, 394) > 0n, 'sysinfo totalram');
  assert.equal(I64(out, 402), BigInt(LAYOUT.STACK_HI), 'RLIMIT_STACK is stack_hi');
  assert.equal(I64(out, 418), 0n, 'getrusage is zeros');
  assert.ok(I64(out, 426) >= 0n, 'times returns clock ticks');
  const base = 434;
  assert.equal(I64(out, base), 1n, 'getpid');
  assert.equal(I64(out, base + 8), 0n, 'getppid');
  assert.equal(I64(out, base + 16), 1000n, 'getuid');
  assert.equal(I64(out, base + 24), 1n, 'gettid of the main thread');
  assert.equal(I64(out, base + 32), 16n, 'getrandom');
});

// ---------------------------------------------------------------------------
// Refusals and signals.
// ---------------------------------------------------------------------------

test('refused syscalls answer the errno S9 names', () => {
  const calls = [
    [57, -E.ENOSYS], [58, -E.ENOSYS], [59, -E.ENOSYS], [61, -E.ECHILD],
    [41, -E.EAFNOSUPPORT], [53, -E.EAFNOSUPPORT], [42, -E.ENOTSOCK],
    [101, -E.EPERM], [291, -E.ENOSYS], [294, -E.ENOSYS], [9999, -E.ENOSYS],
  ].map(([nr, want]) => ({ nr, want }));
  const items = [];
  for (const c of calls) {
    items.push({ op: 'sys', nr: c.nr, args: [0, 0, 0, 0, 0, 0], out: 'r' });
    items.push({ op: 'emit', slot: 'r' });
  }
  items.push({ op: 'exit', code: 0 });
  const { status, out } = run(items);
  assert.equal(status, 0);
  calls.forEach((c, i) => {
    assert.equal(I64(out, i * 8), BigInt(c.want), 'syscall ' + c.nr);
  });
});

test('kill and tgkill: fatal signals end with 128+sig, others are ignored', () => {
  const { status } = run([
    { op: 'sys', nr: 62, args: [1, 0], out: 'r' },
    { op: 'emit', slot: 'r' },
    { op: 'sys', nr: 62, args: [1, 10], out: 'r' }, // SIGUSR1: accepted, not delivered
    { op: 'sys', nr: 234, args: [1, 1, 9], out: 'r' }, // tgkill SIGKILL
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 137, 'SIGKILL status');
});

// ---------------------------------------------------------------------------
// The throwing seam: modules without set_why use YWhy.
// ---------------------------------------------------------------------------

test('the throwing seam runs blocking and exiting modules', () => {
  const { status, out } = run([
    ...threadPrologue(),
    { op: 'put', addr: 'stacktop', value: { slot: 'stack', add: 0x3f000 } },
    { op: 'sys', nr: 56, args: [THREAD_FLAGS, { slot: 'stacktop' }, { addr: 'ptid' }, { addr: 'ctid' }, { addr: 'tls' }], out: 'tid', outAfter: true },
    { op: 'branchZero', to: 'child', else: 'parent' },
    { op: 'label', name: 'child' },
    { op: 'writeStr', text: 'C' },
    { op: 'exit', code: 0, group: false },
    { op: 'label', name: 'parent' },
    { op: 'sys', nr: 24, args: [], out: 'y' }, // sched_yield: YWhy
    { op: 'sys', nr: 202, args: [{ addr: 'ctid' }, 0, { slot: 'tid' }, 0, 0, 0], out: 'fw' },
    { op: 'writeStr', text: 'J' },
    { op: 'exit', code: 4 },
  ], { setWhy: false });
  assert.equal(status, 4, 'exit status through YWhy');
  assert.equal(S(out), 'CJ');
});

test('dup shares a file description and survives closing the original', () => {
  const dir = scratch();
  const file = path.join(dir, 'dup');
  try {
    const { status, out } = run([
      { op: 'sys', nr: 2, args: [{ str: file }, O.RDWR | O.CREAT | O.TRUNC, 0o600], out: 'fd' },
      { op: 'sys', nr: 1, args: [{ slot: 'fd' }, { str: 'abcdef' }, 6], out: 'n' },
      { op: 'sys', nr: 8, args: [{ slot: 'fd' }, 0, 0] },
      { op: 'sys', nr: 32, args: [{ slot: 'fd' }], out: 'd' },
      { op: 'sys', nr: 0, args: [{ slot: 'd' }, { buf: 0 }, 3], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 3 },
      { op: 'sys', nr: 0, args: [{ slot: 'fd' }, { buf: 0 }, 3], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 3 },
      { op: 'sys', nr: 3, args: [{ slot: 'fd' }] },
      { op: 'sys', nr: 8, args: [{ slot: 'd' }, 0, 0] },
      { op: 'sys', nr: 0, args: [{ slot: 'd' }, { buf: 0 }, 6], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 6 },
      { op: 'sys', nr: 3, args: [{ slot: 'd' }] },
      { op: 'exit', code: 0 },
    ], { cwd: dir });
    assert.equal(status, 0);
    assert.equal(S(out), 'abcdefabcdef', 'shared offset, then a rewind through the dup');
  } finally {
    cleanup(dir);
  }
});


test('event-loop pacing: a promise host call blocks and resumes', async () => {
  const items = [
    { op: 'put', addr: 'buf', add: 0, value: 41 },
    { op: 'sys', nr: 22785, args: [{ str: 'app.later' }, 9], out: 'h' },
    { op: 'sys', nr: 22786, args: [{ slot: 'h' }, { buf: 0 }, 1], out: 'r' },
    { op: 'emit', slot: 'r' },
    { op: 'exit', code: 0 },
  ];
  const mk = () => {
    const out = [];
    const host = new Host(buildScript(items), {
      argv: ['prog'],
      env: [],
      stdout: (b) => out.push(Buffer.from(b)),
      stderr: () => {},
      random: new Uint8Array(16),
    });
    host.register('app.later', (a) => new Promise((resolve) => setTimeout(() => resolve(a[0] + 1n), 15)));
    return { host, out };
  };
  const a = mk();
  const t0 = Date.now();
  const status = await a.host.runAsync();
  const elapsed = Date.now() - t0;
  assert.equal(status, 0);
  assert.equal(I64(Buffer.concat(a.out), 0), 42n, 'the promise result became the syscall result');
  assert.ok(elapsed >= 10, 'the event loop really slept: ' + elapsed);

  // The synchronous loop cannot settle a promise and says so.
  const b = mk();
  const syncStatus = b.host.run();
  assert.equal(syncStatus, 0);
  assert.equal(I64(Buffer.concat(b.out), 0), BigInt(-E.ENOSYS));
});


test('clock_nanosleep relative and absolute', () => {
  const dir = scratch();
  try {
    const { status, host } = runHost([
      { op: 'put', addr: 'ts', add: 0, value: 0 },
      { op: 'put', addr: 'ts', add: 8, value: 15000000 },
      { op: 'sys', nr: 230, args: [1, 0, { addr: 'ts' }, 0], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'put', addr: 'ts', add: 0, value: 0 },
      { op: 'put', addr: 'ts', add: 8, value: 0 },
      { op: 'sys', nr: 230, args: [1, 1, { addr: 'ts' }, 0], out: 'r' }, // absolute past
      { op: 'emit', slot: 'r' },
      { op: 'exit', code: 0 },
    ], { cwd: dir });
    assert.equal(status, 0);
    assert.ok(host.now() >= 10, 'relative clock_nanosleep waited');
  } finally {
    cleanup(dir);
  }
});

test('readv blocks on a pipe and writev fills it from a thread', () => {
  const { status, out } = run([
    { op: 'sys', nr: 293, args: [{ addr: 'pfds' }, 0], out: 'w' },
    { op: 'load32', slot: 'rfd', addr: 'pfds', add: 0 },
    { op: 'load32', slot: 'wfd', addr: 'pfds', add: 4 },
    ...threadPrologue(),
    { op: 'put', addr: 'stacktop', value: { slot: 'stack', add: 0x3f000 } },
    { op: 'sys', nr: 56, args: [THREAD_FLAGS, { slot: 'stacktop' }, { addr: 'ptid' }, { addr: 'ctid' }, { addr: 'tls' }], out: 'tid', outAfter: true },
    { op: 'branchZero', to: 'child', else: 'parent' },
    { op: 'label', name: 'child' },
    { op: 'sleep', ms: 20 },
    { op: 'put', addr: 'iov', add: 0, value: { str: 'ab' } },
    { op: 'put', addr: 'iov', add: 8, value: 2 },
    { op: 'put', addr: 'iov', add: 16, value: { str: 'cd' } },
    { op: 'put', addr: 'iov', add: 24, value: 2 },
    { op: 'sys', nr: 20, args: [{ slot: 'wfd' }, { addr: 'iov' }, 2], out: 'n' },
    { op: 'exit', code: 0, group: false },
    { op: 'label', name: 'parent' },
    { op: 'put', addr: 'buf3', add: 0, value: { buf: 0 } },
    { op: 'put', addr: 'buf3', add: 8, value: 3 },
    { op: 'put', addr: 'buf3', add: 16, value: { buf: 1 } },
    { op: 'put', addr: 'buf3', add: 24, value: 3 },
    { op: 'sys', nr: 19, args: [{ slot: 'rfd' }, { addr: 'buf3' }, 2], out: 'n' },
    { op: 'emit', slot: 'n' },
    { op: 'emitMem', addr: 'buf', count: 3 },
    { op: 'emitMem', addr: 'buf2', count: 1 },
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 0);
  assert.equal(I64(out, 0), 4n, 'readv got 4 bytes');
  assert.equal(S(out.subarray(8, 12)), 'abcd', 'the vectors were filled');
});

test('select blocks until the writer thread writes', () => {
  const { status, out } = run([
    { op: 'sys', nr: 293, args: [{ addr: 'pfds' }, 0], out: 'w' },
    { op: 'load32', slot: 'rfd', addr: 'pfds', add: 0 },
    { op: 'load32', slot: 'wfd', addr: 'pfds', add: 4 },
    ...threadPrologue(),
    { op: 'put', addr: 'stacktop', value: { slot: 'stack', add: 0x3f000 } },
    { op: 'sys', nr: 56, args: [THREAD_FLAGS, { slot: 'stacktop' }, { addr: 'ptid' }, { addr: 'ctid' }, { addr: 'tls' }], out: 'tid', outAfter: true },
    { op: 'branchZero', to: 'child', else: 'parent' },
    { op: 'label', name: 'child' },
    { op: 'sleep', ms: 20 },
    { op: 'sys', nr: 1, args: [{ slot: 'wfd' }, { str: 's' }, 1], out: 'n' },
    { op: 'exit', code: 0, group: false },
    { op: 'label', name: 'parent' },
    { op: 'put8', addr: 'buf2', add: 0, value: 1 },
    { op: 'sys', nr: 23, args: [16, { buf: 1 }, 0, 0, 0], out: 'n' },
    { op: 'emit', slot: 'n' },
    { op: 'sys', nr: 0, args: [{ slot: 'rfd' }, { buf: 0 }, 1], out: 'n' },
    { op: 'emitMem', addr: 'buf', count: 1 },
    { op: 'exit', code: 0 },
  ]);
  assert.equal(status, 0);
  assert.equal(I64(out, 0), 1n, 'select reported one fd');
  assert.equal(out[8], 0x73, 'and the byte is there');
});

test('renameat2 NOREPLACE and EXCHANGE', () => {
  const dir = scratch();
  try {
    const a = path.join(dir, 'a');
    const b = path.join(dir, 'b');
    fs.writeFileSync(a, 'A');
    fs.writeFileSync(b, 'B');
    const { status, out } = run([
      { op: 'sys', nr: 316, args: [AT.FDCWD, { str: a }, AT.FDCWD, { str: b }, 2], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'sys', nr: 2, args: [{ str: a }, O.RDONLY], out: 'fa' },
      { op: 'sys', nr: 0, args: [{ slot: 'fa' }, { buf: 0 }, 1], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 1 },
      { op: 'sys', nr: 2, args: [{ str: b }, O.RDONLY], out: 'fb' },
      { op: 'sys', nr: 0, args: [{ slot: 'fb' }, { buf: 1 }, 1], out: 'n' },
      { op: 'emitMem', addr: 'buf2', count: 1 },
      { op: 'sys', nr: 316, args: [AT.FDCWD, { str: a }, AT.FDCWD, { str: b }, 1], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'exit', code: 0 },
    ], { cwd: dir });
    assert.equal(status, 0);
    assert.equal(I64(out, 0), 0n, 'RENAME_EXCHANGE');
    assert.equal(String.fromCharCode(out[8]), 'B', 'a now holds B');
    assert.equal(String.fromCharCode(out[9]), 'A', 'b now holds A');
    assert.equal(I64(out, 10), BigInt(-E.EEXIST), 'RENAME_NOREPLACE refuses an existing target');
  } finally {
    cleanup(dir);
  }
});



test('openat/newfstatat/unlinkat with a directory fd', () => {
  const dir = scratch();
  try {
    fs.mkdirSync(path.join(dir, 'sub'));
    const { status, out } = run([
      { op: 'sys', nr: 2, args: [{ str: path.join(dir, 'sub') }, O.RDONLY | O.DIRECTORY], out: 'dfd' },
      { op: 'sys', nr: 257, args: [{ slot: 'dfd' }, { str: 'f' }, O.RDWR | O.CREAT, 0o644], out: 'fd' },
      { op: 'sys', nr: 1, args: [{ slot: 'fd' }, { str: 'xyz' }, 3], out: 'n' },
      { op: 'sys', nr: 262, args: [{ slot: 'dfd' }, { str: 'f' }, { buf: 0 }, 0], out: 'r' },
      { op: 'emitMem', addr: 'buf', add: 48, count: 8 },
      { op: 'sys', nr: 263, args: [{ slot: 'dfd' }, { str: 'f' }, 0], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'sys', nr: 3, args: [{ slot: 'dfd' }] },
      { op: 'exit', code: 0 },
    ], { cwd: dir });
    assert.equal(status, 0);
    assert.equal(I64(out, 0), 3n, 'newfstatat through the dirfd');
    assert.equal(I64(out, 8), 0n, 'unlinkat through the dirfd');
  } finally {
    cleanup(dir);
  }
});

test('O_APPEND and F_SETFL O_APPEND', () => {
  const dir = scratch();
  const file = path.join(dir, 'app');
  try {
    fs.writeFileSync(file, 'X');
    const { status, out } = run([
      { op: 'sys', nr: 2, args: [{ str: file }, O.WRONLY | O.APPEND], out: 'fd' },
      { op: 'sys', nr: 1, args: [{ slot: 'fd' }, { str: 'a' }, 1], out: 'n' },
      { op: 'sys', nr: 1, args: [{ slot: 'fd' }, { str: 'b' }, 1], out: 'n' },
      { op: 'sys', nr: 72, args: [{ slot: 'fd' }, 4, O.APPEND], out: 'r' },
      { op: 'sys', nr: 1, args: [{ slot: 'fd' }, { str: 'c' }, 1], out: 'n' },
      { op: 'sys', nr: 3, args: [{ slot: 'fd' }] },
      { op: 'sys', nr: 2, args: [{ str: file }, O.RDONLY], out: 'rfd' },
      { op: 'sys', nr: 0, args: [{ slot: 'rfd' }, { buf: 0 }, 16], out: 'n' },
      { op: 'emitMem', addr: 'buf', count: 4 },
      { op: 'exit', code: 0 },
    ], { cwd: dir });
    assert.equal(status, 0);
    assert.equal(S(out.subarray(0, 4)), 'Xabc');
  } finally {
    cleanup(dir);
  }
});

test('misc: fsync/flock/limits/signals/robust list/fchmod/getcwd ERANGE', () => {
  const dir = scratch();
  const file = path.join(dir, 'misc');
  try {
    const { status, out } = run([
      { op: 'sys', nr: 2, args: [{ str: file }, O.RDWR | O.CREAT, 0o644], out: 'fd' },
      { op: 'sys', nr: 74, args: [{ slot: 'fd' }], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'sys', nr: 73, args: [{ slot: 'fd' }, 2], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'sys', nr: 91, args: [{ slot: 'fd' }, 0o600], out: 'r' },
      { op: 'sys', nr: 5, args: [{ slot: 'fd' }, { buf: 0 }], out: 'r' },
      { op: 'emitMem', addr: 'buf', add: 24, count: 4 },
      { op: 'sys', nr: 160, args: [3, { buf: 1 }], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'sys', nr: 302, args: [1, 3, 0, { buf: 0 }], out: 'r' },
      { op: 'emitMem', addr: 'buf', count: 8 },
      { op: 'sys', nr: 13, args: [11, 0, 0, 8], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'sys', nr: 273, args: [{ addr: 'buf2' }, 24], out: 'r' },
      { op: 'sys', nr: 274, args: [0, { buf: 1 }, { buf: 0 }], out: 'r' },
      { op: 'emitMem', addr: 'buf2', add: 0, count: 8 },
      { op: 'emitMem', addr: 'buf', add: 0, count: 8 },
      { op: 'sys', nr: 79, args: [{ buf: 0 }, 2], out: 'r' },
      { op: 'emit', slot: 'r' },
      { op: 'exit', code: 0 },
    ], { cwd: dir });
    assert.equal(status, 0);
    assert.equal(I64(out, 0), 0n, 'fsync');
    assert.equal(I64(out, 8), 0n, 'flock');
    assert.equal(out.readUInt32LE(16) & 0o777, 0o600, 'fchmod');
    assert.equal(I64(out, 20), 0n, 'setrlimit');
    assert.ok(I64(out, 28) > 0n, 'prlimit64 old stack limit');
    assert.equal(I64(out, 36), 0n, 'rt_sigaction');
    assert.equal(I64(out, 44), 0n, 'get_robust_list head');
    assert.equal(I64(out, 52), 24n, 'get_robust_list wrote the length');
    assert.equal(I64(out, 60), BigInt(-E.ERANGE), 'getcwd with a 2-byte buffer');
  } finally {
    cleanup(dir);
  }
});

test('select(0, ..., timeout) sleeps like a portable sleep', () => {
  const dir = scratch();
  try {
    const { status, host } = runHost([
      { op: 'put', addr: 'ts', add: 0, value: 0 },
      { op: 'put', addr: 'ts', add: 8, value: 20000000 },
      { op: 'sys', nr: 23, args: [0, 0, 0, 0, { addr: 'ts' }], out: 'r' },
      { op: 'exit', code: 0 },
    ], { cwd: dir });
    assert.equal(status, 0);
    assert.ok(host.now() >= 15, 'select(0) waited: ' + host.now());
  } finally {
    cleanup(dir);
  }
});



