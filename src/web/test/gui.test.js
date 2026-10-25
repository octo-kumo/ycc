// src/web/test/gui.test.js -- the nine gui host functions and Node's virtual
// display, without a browser.
//
// Run: node --disable-wasm-trap-handler --test src/web/test/gui.test.js
//
// The tests call HOST_SYM/HOST_CALL exactly as std/gui.web.y does, from a
// hand-built ABI-1 module, so the argument order and the event layout are the
// same ones the overlay sees.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildScript } from './wasmgen.js';
import { Host } from '../yhost.js';
import { Y_SYS } from '../abi.js';

function guiHost(opts = {}) {
  const bytes = buildScript([{ op: 'exit', code: 0 }]);
  return new Host(bytes, {
    argv: ['guiprogram'],
    env: [],
    cwd: process.cwd(),
    fuel: 1000000,
    stdout: () => {},
    stderr: () => {},
    random: new Uint8Array(16),
    ...opts,
  });
}

function putCString(host, ptr, text) {
  const b = Buffer.from(text, 'utf8');
  host.writeMemory(ptr, Buffer.concat([b, Buffer.from([0])]));
  return b.length;
}

function guiSym(host, ptr, name) {
  const len = putCString(host, ptr, name);
  return Number(host.sys(BigInt(Y_SYS.HOST_SYM), BigInt(ptr), BigInt(len), 0n, 0n, 0n, 0n));
}

function guiCall(host, handle, argsPtr, values) {
  const buf = Buffer.alloc(values.length * 8);
  values.forEach((v, i) => buf.writeBigInt64LE(BigInt(v), i * 8));
  host.writeMemory(argsPtr, buf);
  return host.sys(BigInt(Y_SYS.HOST_CALL), BigInt(handle), BigInt(argsPtr), BigInt(values.length), 0n, 0n, 0n);
}

function guiSetup(opts = {}) {
  const host = guiHost(opts);
  const base = host.mmap.alloc(0x80000, 16, 'kernel');
  const h = {
    open: guiSym(host, base, 'gui.open'),
    size: guiSym(host, base, 'gui.size'),
    present: guiSym(host, base, 'gui.present'),
    poll: guiSym(host, base, 'gui.poll'),
    wait: guiSym(host, base, 'gui.wait'),
    title: guiSym(host, base, 'gui.title'),
    resize: guiSym(host, base, 'gui.resize'),
    close: guiSym(host, base, 'gui.close'),
    read_back: guiSym(host, base, 'gui.read_back'),
  };
  return { host, base, at: base, args: base + 0x100, pixels: base + 0x1000,
    evbuf: base + 0x40000, readbuf: base + 0x60000, h };
}

function guiOpen(g, w, h, title) {
  const t = g.base + 0x800;
  const len = putCString(g.host, t, title || '');
  return Number(guiCall(g.host, g.h.open, g.args, [w, h, t, len]));
}

function scratch() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'yweb-gui-'));
}

test('gui: the nine host names resolve', () => {
  const host = guiHost();
  const base = host.mmap.alloc(0x1000, 16, 'kernel');
  const names = ['gui.open', 'gui.size', 'gui.present', 'gui.poll', 'gui.wait',
    'gui.title', 'gui.resize', 'gui.close', 'gui.read_back'];
  const handles = names.map((n) => guiSym(host, base, n));
  assert.deepEqual(handles.every((x) => x > 0), true, 'all nine resolve');
  assert.equal(new Set(handles).size, 9, 'each has its own handle');
  assert.equal(host.sys(BigInt(Y_SYS.HOST_SYM), BigInt(base + 100), 8n, 0n, 0n, 0n, 0n), 0n,
    'an unknown name is 0');
});

test('gui: no display means gui.open is 0', () => {
  const g = guiSetup();
  assert.equal(guiOpen(g, 32, 24, 'none'), 0, 'open answers 0 with no display');
  assert.equal(Number(guiCall(g.host, g.h.size, g.args, [1])), -22, 'every other call is EINVAL');
});

test('gui: virtual display presents, reads back and dumps a PPM', () => {
  const g = guiSetup({ display: { width: 48, height: 32 } });
  const id = guiOpen(g, 48, 32, 'virtual');
  assert.ok(id > 0, 'open answers an id');
  const size = guiCall(g.host, g.h.size, g.args, [id]);
  assert.equal(size, BigInt(48) | (BigInt(32) << 32n), 'size is w | h << 32');

  // A BGRA pattern: the alpha byte is deliberately 0; read_back returns the
  // presented BGRA bytes unchanged.
  const src = Buffer.alloc(48 * 32 * 4);
  for (let i = 0; i < 48 * 32; i++) {
    src[i * 4] = i & 0xff;
    src[i * 4 + 1] = (i * 3) & 0xff;
    src[i * 4 + 2] = (i * 7) & 0xff;
    src[i * 4 + 3] = 0;
  }
  src[0] = 0x11;
  src[1] = 0x22;
  src[2] = 0x33;
  g.host.writeMemory(g.pixels, src);
  assert.equal(Number(guiCall(g.host, g.h.present, g.args,
    [id, g.pixels, 48, 32, 0, 0, 48, 32])), 0, 'present answers 0');

  const n = Number(guiCall(g.host, g.h.read_back, g.args, [id, g.readbuf, 48 * 32 * 4]));
  assert.equal(n, 48 * 32 * 4, 'read_back copies the whole frame');
  const back = Buffer.from(g.host.memoryBytes(g.readbuf, n));
  assert.equal(back.equals(src), true, 'read_back is the presented BGRA bytes, unchanged');

  // A partial present changes only its rectangle; the rest of read_back is the
  // earlier frame.  The source is still a whole pix_w by pix_h frame.
  const patched = Buffer.from(src);
  for (let dy = 0; dy < 2; dy++) {
    for (let dx = 0; dx < 2; dx++) {
      const at = ((5 + dy) * 48 + (4 + dx)) * 4;
      patched[at] = 0x11;
      patched[at + 1] = 0x22;
      patched[at + 2] = 0x33;
      patched[at + 3] = 0x44;
    }
  }
  g.host.writeMemory(g.pixels, patched);
  guiCall(g.host, g.h.present, g.args, [id, g.pixels, 48, 32, 4, 5, 6, 7]);
  guiCall(g.host, g.h.read_back, g.args, [id, g.readbuf, 48 * 32 * 4]);
  const after = Buffer.from(g.host.memoryBytes(g.readbuf, 48 * 32 * 4));
  assert.equal(after.readUInt32LE((5 * 48 + 4) * 4), 0x44332211, 'the patch landed');
  assert.equal(after.readUInt32LE((5 * 48 + 6) * 4), src.readUInt32LE((5 * 48 + 6) * 4),
    'outside the patch the old frame stays');

  const ppm = g.host.gui.dumpPPM();
  assert.ok(ppm instanceof Uint8Array, 'a PPM is available');
  const head = Buffer.from(ppm.subarray(0, 12)).toString('latin1');
  assert.equal(head, 'P6\n48 32\n255', 'PPM header');
  assert.equal(ppm[13 + 0], 0x33, 'PPM first pixel R comes from BGRA byte 2');
  assert.equal(ppm[13 + 1], 0x22, 'PPM first pixel G comes from BGRA byte 1');
  assert.equal(ppm[13 + 2], 0x11, 'PPM first pixel B comes from BGRA byte 0');
});

test('gui: resize is fixed-mode, queues EV_RESIZE, and close retires the id', () => {
  const g = guiSetup({ display: { width: 32, height: 24 } });
  const id = guiOpen(g, 32, 24, 'resize');
  assert.equal(Number(guiCall(g.host, g.h.resize, g.args, [id, 60, 40])), 0, 'fixed resize is 0');
  const size = guiCall(g.host, g.h.size, g.args, [id]);
  assert.equal(size, 60n | (40n << 32n), 'the client size changed');
  assert.equal(Number(guiCall(g.host, g.h.poll, g.args, [id, g.evbuf, 128])), 1, 'EV_RESIZE is queued');
  const ev = g.host.memoryDataView(g.evbuf, 40);
  assert.equal(ev.getBigInt64(0, true), 6n, 'EV_RESIZE kind');
  assert.equal(ev.getBigInt64(8, true), 60n, 'resize width');
  assert.equal(ev.getBigInt64(16, true), 40n, 'resize height');
  assert.equal(Number(guiCall(g.host, g.h.close, g.args, [id])), 0, 'close answers 0');
  assert.equal(Number(guiCall(g.host, g.h.size, g.args, [id])), -22, 'a closed id is EINVAL');
  assert.equal(Number(guiCall(g.host, g.h.resize, g.args, [99, 10, 10])), -22, 'an unknown id is EINVAL');
});

test('gui: poll delivers timed events once and wait blocks until t', () => {
  const g = guiSetup({ display: { width: 32, height: 24 } });
  const id = guiOpen(g, 32, 24, 'events');
  const t0 = g.host.now();
  const lines = [
    JSON.stringify({ t: t0 + 200, kind: 'key', vk: 65, down: 1, mods: 2 }),
    JSON.stringify({ t: t0 + 250, kind: 'char', cp: 97 }),
    JSON.stringify({ t: t0 + 300, kind: 'button', x: 5, y: 6, button: 1, down: 1 }),
    JSON.stringify({ t: t0 + 350, kind: 'wheel', x: 7, y: 8, c: 2 }),
    JSON.stringify({ t: t0 + 400, kind: 'resize', w: 60, h: 50 }),
  ].join('\n');
  g.host.display.setEvents(lines);

  assert.equal(Number(guiCall(g.host, g.h.poll, g.args, [id, g.evbuf, 128])), 0,
    'nothing is due before its t');
  const before = g.host.now();
  assert.equal(Number(guiCall(g.host, g.h.wait, g.args, [id, 1000])), 1, 'wait answers 1');
  assert.ok(g.host.now() >= t0 + 190, 'wait slept until the first event: ' + (g.host.now() - before));
  assert.equal(Number(guiCall(g.host, g.h.poll, g.args, [id, g.evbuf, 128])), 1, 'one event is due');
  let dv = g.host.memoryDataView(g.evbuf, 40);
  assert.equal(dv.getBigInt64(0, true), 1n, 'EV_KEY');
  assert.equal(dv.getBigInt64(8, true), 65n, 'vk');
  assert.equal(dv.getBigInt64(16, true), 1n, 'down');
  assert.equal(dv.getBigInt64(24, true), 2n, 'mods');
  assert.equal(dv.getBigInt64(32, true), 0n, 'no repeat');

  // Each wait returns at the next event's t, not at the deadline, and delivers
  // exactly what became due.
  const rest = [];
  for (let i = 0; i < 4; i++) {
    assert.equal(Number(guiCall(g.host, g.h.wait, g.args, [id, 1000])), 1, 'wait answers 1');
    const n = Number(guiCall(g.host, g.h.poll, g.args, [id, g.evbuf, 128]));
    assert.equal(n, 1, 'one more event is due');
    dv = g.host.memoryDataView(g.evbuf, 40);
    rest.push(Array.from({ length: 5 }, (_, k) => dv.getBigInt64(k * 8, true)));
  }
  assert.deepEqual(rest.map((e) => e[0]), [2n, 4n, 5n, 6n], 'char, button, wheel, resize');
  assert.equal(rest[0][1], 97n, 'char code point');
  assert.equal(rest[1][1], 5n, 'button x');
  assert.equal(rest[1][2], 6n, 'button y');
  assert.equal(rest[1][3], 1n, 'button 1');
  assert.equal(rest[2][3], 2n, 'two notches');
  assert.equal(Number(guiCall(g.host, g.h.poll, g.args, [id, g.evbuf, 128])), 0, 'delivered once');
  const size = guiCall(g.host, g.h.size, g.args, [id]);
  assert.equal(size, 60n | (50n << 32n), 'the resize event changed the client size');
});

test('gui: poll cap is an event count, and wait(0) does not block', () => {
  const g = guiSetup({ display: { width: 16, height: 16 } });
  const id = guiOpen(g, 16, 16, 'cap');
  const t = g.host.now() + 1;
  const lines = [];
  for (let i = 0; i < 5; i++) lines.push(JSON.stringify({ t, kind: 'char', cp: 65 + i }));
  g.host.display.setEvents(lines.join('\n'));
  g.host.sleepUntil(t + 1);
  assert.equal(Number(guiCall(g.host, g.h.poll, g.args, [id, g.evbuf, 2])), 2, 'cap 2 means two events');
  assert.equal(Number(guiCall(g.host, g.h.poll, g.args, [id, g.evbuf, 0])), 0, 'cap 0 writes nothing');
  assert.equal(Number(guiCall(g.host, g.h.poll, g.args, [id, g.evbuf, 128])), 3, 'the rest stay queued');
});

test('gui: --display-dump writes the last frame when the program ends', () => {
  const dir = scratch();
  const file = path.join(dir, 'frame.ppm');
  try {
    const bytes = buildScript([{ op: 'exit', code: 0 }]);
    const host = new Host(bytes, {
      argv: ['dump'], env: [], cwd: dir, stdout: () => {}, stderr: () => {},
      random: new Uint8Array(16),
      display: { width: 8, height: 4 },
      displayDump: file,
    });
    const base = host.mmap.alloc(0x10000, 16, 'kernel');
    const args = base + 0x100;
    const pixels = base + 0x1000;
    const openH = guiSym(host, base, 'gui.open');
    const presentH = guiSym(host, base, 'gui.present');
    const t = base + 0x800;
    const len = putCString(host, t, 'dump');
    const id = Number(guiCall(host, openH, args, [8, 4, t, len]));
    const src = Buffer.alloc(8 * 4 * 4);
    for (let i = 0; i < 8 * 4; i++) {
      src[i * 4] = 0x30;
      src[i * 4 + 1] = 0x20;
      src[i * 4 + 2] = 0x10;
      src[i * 4 + 3] = 0xff;
    }
    host.writeMemory(pixels, src);
    guiCall(host, presentH, args, [id, pixels, 8, 4, 0, 0, 8, 4]);
    const status = host.run();
    assert.equal(status, 0, 'the program runs');
    assert.ok(fs.existsSync(file), 'the frame file exists');
    const ppm = fs.readFileSync(file);
    assert.equal(ppm.subarray(0, 11).toString('latin1'), 'P6\n8 4\n255\n', 'PPM header');
    assert.deepEqual([...ppm.subarray(11, 14)], [0x10, 0x20, 0x30], 'RGB from BGRA');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
