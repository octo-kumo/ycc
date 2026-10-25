// src/web/test/mkfixture.js — a hand-built wasm module for the Node host.
//
// It is not produced by the compiler; it exists so src/web can be tested
// before src/y/wasm_* is ready (as W3 asks).  The module imports y.sys and
// y.trap, exports memory/resume/ctx_*/set_fuel/why (and optionally set_why),
// carries a yweb section, and resume writes "hi\n" through write(1) and then
// exits through exit_group(60).
//
// Usage:
//   node src/web/test/mkfixture.js OUT.wasm [status] [--set-why|--trap=11|--oob]
//
// buildSmokeWasm({ status, setWhy, trapSignal, oob, abi }) is exported for
// yhost.js's selftest.

import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

const UTF8 = new TextEncoder();

function bytesOf(s) {
  return Array.from(UTF8.encode(String(s)));
}

function uleb(n) {
  const out = [];
  let v = n;
  do {
    let b = v & 0x7f;
    v >>>= 7;
    if (v !== 0) b |= 0x80;
    out.push(b);
  } while (v !== 0);
  return out;
}

function sleb(n) {
  const out = [];
  let v = n;
  for (;;) {
    let b = v & 0x7f;
    v >>= 7;
    const done = (v === 0 && (b & 0x40) === 0) || (v === -1 && (b & 0x40) !== 0);
    if (!done) b |= 0x80;
    out.push(b);
    if (done) break;
  }
  return out;
}

function vec(items) {
  return [...uleb(items.length), ...items.flat()];
}

function str(s) {
  const b = bytesOf(s);
  return [...uleb(b.length), ...b];
}

function section(id, payload) {
  return [id, ...uleb(payload.length), ...payload];
}

function body(instrs) {
  const b = [0x00, ...instrs, 0x0b];
  return [...uleb(b.length), ...b];
}

function nameSection(funcs) {
  let sub = [...uleb(funcs.length)];
  for (const f of funcs) sub = sub.concat(uleb(f[0]), str(f[1]));
  return section(0, [...str('name'), 2, ...uleb(sub.length), ...sub]);
}

export function buildSmokeWasm(opts = {}) {
  const abi = opts.abi === undefined ? 1 : opts.abi;
  const status = opts.status === undefined ? 7 : opts.status;
  const exitSyscall = opts.exitSyscall === undefined ? 60 : opts.exitSyscall;
  const setWhy = !!opts.setWhy;
  const oob = !!opts.oob;
  const trapSignal = opts.trapSignal;

  const stackLo = 0;
  const stackHi = 65536;
  const dataLo = 65536;
  const dataEnd = dataLo + 3;
  const heapLo = 131072;
  const chunks = 1;
  const memoryPages = 18;
  const entry = 2 ** 40;

  // type 0: (i64 x7) -> i64; 1: (i32) -> (); 2: (i64) -> ();
  // type 3: (i32) -> (); 4: () -> i32; 5: () -> (); 6: (i32) -> ()
  const types = [
    [0x60, 7, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 1, 0x7e],
    [0x60, 1, 0x7f, 0],
    [0x60, 1, 0x7e, 0],
    [0x60, 1, 0x7f, 0],
    [0x60, 0, 1, 0x7f],
    [0x60, 0, 0],
    [0x60, 1, 0x7f, 0],
  ];
  const typeSec = section(1, vec(types));

  const imports = [
    ...str('y'),
    ...str('sys'),
    0x00,
    ...uleb(0),
    ...str('y'),
    ...str('trap'),
    0x00,
    ...uleb(1),
  ];
  const importSec = section(2, [...uleb(2), ...imports]);

  const funcTypes = [2, 3, 3, 3, 4];
  if (setWhy) funcTypes.push(6);
  const funcSec = section(3, [...uleb(funcTypes.length), ...funcTypes.flatMap((t) => uleb(t))]);

  const memSec = section(5, [...uleb(1), 0x00, ...uleb(memoryPages)]);

  let globalSec = [];
  if (setWhy) globalSec = section(6, [...uleb(1), 0x7f, 0x01, 0x41, 0x00, 0x0b]);

  const exportsList = [
    ['memory', 2, 0],
    ['resume', 0, 2],
    ['ctx_save', 0, 3],
    ['ctx_load', 0, 4],
    ['set_fuel', 0, 5],
    ['why', 0, 6],
  ];
  if (setWhy) exportsList.push(['set_why', 0, 7]);
  let exportPayload = [...uleb(exportsList.length)];
  for (const e of exportsList) exportPayload = exportPayload.concat(str(e[0]), [e[1]], uleb(e[2]));
  const exportSec = section(7, exportPayload);

  // resume
  let resume = [];
  if (oob) {
    resume = [0x41, ...sleb(-1), 0x28, 0x02, 0x00, 0x1a];
  } else if (trapSignal !== undefined) {
    resume = [0x41, ...sleb(trapSignal), 0x10, 0x01, 0x00];
  } else {
    resume = [
      0x42, 1, // write(1, data_lo, 3)
      0x42, 1,
      0x42, ...sleb(dataLo),
      0x42, 3,
      0x42, 0,
      0x42, 0,
      0x42, 0,
      0x10, 0x00,
      0x1a,
      0x42, ...sleb(exitSyscall), // exit(60) or exit_group(231)
      0x42, ...sleb(status),
      0x42, 0,
      0x42, 0,
      0x42, 0,
      0x42, 0,
      0x42, 0,
      0x10, 0x00,
      0x1a,
    ];
    if (!setWhy) resume.push(0x00);
  }

  // ctx_save: zero all 64 8-byte slots of the 512-byte context.
  const save = [];
  for (let off = 0; off < 512; off += 8) {
    save.push(0x20, 0x00, 0x42, 0x00, 0x37, 0x03, ...uleb(off));
  }

  const whyBody = setWhy ? [0x23, 0x00] : [0x41, 0x00];
  const setWhyBody = [0x20, 0x00, 0x24, 0x00];

  const bodies = [resume, save, [], [], whyBody];
  if (setWhy) bodies.push(setWhyBody);
  const codeSec = section(10, [...uleb(bodies.length), ...bodies.map((b) => body(b)).flat()]);

  const dataSec = section(11, [
    ...uleb(1),
    0x00,
    0x41, ...sleb(dataLo),
    0x0b,
    ...uleb(3),
    ...bytesOf('hi\n'),
  ]);

  const names = [[2, 'resume'], [3, 'ctx_save'], [4, 'ctx_load'], [5, 'set_fuel'], [6, 'why']];
  if (setWhy) names.push([7, 'set_why']);
  const nameSec = nameSection(names);

  const yweb = [
    'abi=' + abi,
    'stack_lo=' + stackLo,
    'stack_hi=' + stackHi,
    'data_lo=' + dataLo,
    'data_end=' + dataEnd,
    'heap_lo=' + heapLo,
    'entry=' + entry,
    'chunks=' + chunks,
    'threads=0',
    'gui=0',
    'audio=0',
  ].join('\n');
  const ywebSec = section(0, [...str('yweb'), ...bytesOf(yweb)]);

  const header = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
  return new Uint8Array(
    header
      .concat(typeSec, importSec, funcSec, memSec, globalSec, exportSec, codeSec, dataSec, nameSec, ywebSec)
  );
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
  const out = process.argv[2];
  if (!out) {
    console.error('usage: node src/web/test/mkfixture.js OUT.wasm [status] [--set-why|--trap=11|--oob]');
    process.exitCode = 2;
  } else {
    const opts = { status: 7 };
    for (const a of process.argv.slice(3)) {
      if (/^[0-9]+$/.test(a)) opts.status = Number(a);
      else if (a === '--set-why') opts.setWhy = true;
      else if (a.startsWith('--trap=')) opts.trapSignal = Number(a.slice('--trap='.length));
      else if (a === '--oob') opts.oob = true;
      else {
        console.error('mkfixture: unknown option ' + a);
        process.exitCode = 2;
      }
    }
    if (!process.exitCode) {
      fs.writeFileSync(out, buildSmokeWasm(opts));
      console.log('wrote ' + out);
    }
  }
}
