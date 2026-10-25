// src/web/test/wasmgen.js — hand-built wasm modules for testing the Node host.
//
// The compiler's wasm backend is in flux, so the host's syscalls are tested
// against modules generated here.  A module is a real ABI-1 web module: it
// imports y.sys/y.trap, exports memory/resume/ctx_save/ctx_load/set_fuel/why
// (and set_why), carries the yweb section, and implements the S8 contract:
// every syscall stores $pc = token(after), calls y.sys, stores rax, and returns
// from resume when $why is non-zero.  A resume after a block starts at the
// case after the syscall, with rax supplied by the host (S8 step 5).
//
// A script is a list of items; each item is one case, so jumps and thread
// entry points are case numbers.  Items:
//
//   {op:'sys', nr, args:[expr...], out:'slot'}   a syscall
//   {op:'exit', code, group:true|false}
//   {op:'writeStr', text, fd}                    write a data string
//   {op:'emit', slot}                            write the 8 bytes of a slot
//   {op:'emitStr', text}
//   {op:'set', slot, value}
//   {op:'storeRax', slot}                        store the current rax
//   {op:'label', name}
//   {op:'jump', to:'label'}
//   {op:'branchZero', to:'label', else:'label'}  on rax (a clone child sees 0)
//   {op:'jumpIf', slot, eq, to:'label'}
//   {op:'sleep', ms}
//   {op:'spin', n}                               burn fuel, then yield PREEMPT
//   {op:'put', addr, add, value}                 store an i64 in memory
//   {op:'put32', addr, add, value}               store an i32
//   {op:'put16', addr, add, value}               store an i16
//   {op:'put8', addr, add, value}                store an i8
//   {op:'load', slot, addr, add}                 load an i64 into a slot
//   {op:'load32', slot, addr, add}               load an i32 (zero extended)
//   {op:'load16', slot, addr, add}               load an i16 (zero extended)
//   {op:'load8', slot, addr, add}                load an i8 (zero extended)
//   {op:'emitMem', addr, add, count}             write memory bytes to fd 1
//   {op:'nop'}
//
// An expression is a number/bigint, {slot:'name'}, {addr:'name', add:n},
// {str:'text'}, {buf:0|1, add:n}, or {slotAddr:'name', add:n}.

import { CLONE } from '../abi.js';

const UTF8 = new TextEncoder();

export function uleb(n) {
  let v = Number(n);
  if (v < 0) throw new RangeError('uleb of a negative number');
  const out = [];
  do {
    let b = v & 0x7f;
    v = Math.floor(v / 128);
    if (v !== 0) b |= 0x80;
    out.push(b);
  } while (v !== 0);
  return out;
}

export function sleb(n) {
  let v = BigInt(n);
  const out = [];
  for (;;) {
    let b = Number(v & 0x7fn);
    v >>= 7n;
    const done = (v === 0n && (b & 0x40) === 0) || (v === -1n && (b & 0x40) !== 0);
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
  const b = [...UTF8.encode(String(s))];
  return [...uleb(b.length), ...b];
}

function section(id, payload) {
  return [id, ...uleb(payload.length), ...payload];
}

function body(instrs) {
  // locals: 1 x i32, 3 x i64
  const locals = [...uleb(2), ...uleb(1), 0x7f, ...uleb(3), 0x7e];
  const b = [...locals, ...instrs, 0x0b];
  return [...uleb(b.length), ...b];
}

const STACK_HI = 0x10000;
const DATA_LO = 0x10000;
const SLOT_BASE = 0x12000;
const BUF_BASE = 0x14000;
const BUF2_BASE = 0x16000;
const BUF3_BASE = 0x17000;
const TS_ADDR = 0x13f00;
const ITS_ADDR = 0x13f40;
const CA_ADDR = 0x13f80;
const IOV_ADDR = 0x13fc0;
const DATA_END = 0x18000;
const HEAP_LO = 0x100000;
const MEMORY_PAGES = 18;
const TOKEN_BASE = 2 ** 40;

export const LAYOUT = {
  STACK_HI, DATA_LO, SLOT_BASE, BUF_BASE, BUF2_BASE, BUF3_BASE, TS_ADDR, ITS_ADDR, CA_ADDR, IOV_ADDR, DATA_END, HEAP_LO,
  MEMORY_PAGES, TOKEN_BASE,
};

// Thread flags a Y spawn passes (arch/threads.s).
export const THREAD_FLAGS =
  CLONE.VM | CLONE.FS | CLONE.FILES | CLONE.SIGHAND | CLONE.THREAD |
  CLONE.SYSVSEM | CLONE.SETTLS | CLONE.PARENT_SETTID | CLONE.CHILD_SETTID |
  CLONE.CHILD_CLEARTID;

class Emitter {
  constructor() {
    this.bytes = [];
    this.labels = [];
    this.ifCount = 0;
  }

  emit(...b) {
    for (const x of b) this.bytes.push(x & 0xff);
  }

  open(kind, label) {
    this.emit(kind, 0x40);
    this.labels.push(label === undefined || label === null ? '#if' + this.ifCount++ : label);
  }

  block(label) {
    this.open(0x02, label);
  }

  loop(label) {
    this.open(0x03, label);
  }

  if_(label) {
    this.open(0x04, label);
  }

  else_() {
    this.emit(0x05);
  }

  end() {
    this.emit(0x0b);
    this.labels.pop();
  }

  depth(label) {
    const i = this.labels.lastIndexOf(label);
    if (i < 0) throw new Error('branch target not open: ' + label);
    return this.labels.length - 1 - i;
  }

  br(label) {
    this.emit(0x0c, ...uleb(this.depth(label)));
  }

  brIf(label) {
    this.emit(0x0d, ...uleb(this.depth(label)));
  }

  i32(n) {
    this.emit(0x41, ...sleb(n));
  }

  i64(n) {
    this.emit(0x42, ...sleb(n));
  }

  localGet(i) {
    this.emit(0x20, ...uleb(i));
  }

  localSet(i) {
    this.emit(0x21, ...uleb(i));
  }

  localTee(i) {
    this.emit(0x22, ...uleb(i));
  }

  globalGet(i) {
    this.emit(0x23, ...uleb(i));
  }

  globalSet(i) {
    this.emit(0x24, ...uleb(i));
  }

  call(i) {
    this.emit(0x10, ...uleb(i));
  }

  i64Load(addr) {
    this.i32(addr);
    this.emit(0x29, 0x03, 0x00);
  }

  i64Store(addr) {
    this.i32(addr);
    this.emit(0x37, 0x03, 0x00);
  }
}

function normalizeItems(items) {
  const out = items.map((it) => ({ ...it }));
  const labels = new Map();
  for (let i = 0; i < out.length; i++) {
    if (out[i].op === 'label') labels.set(out[i].name, i);
  }
  return { items: out, labels };
}

function collectStrings(items) {
  const order = [];
  const seen = new Map();
  const add = (s) => {
    if (!seen.has(s)) {
      seen.set(s, order.length);
      order.push(s);
    }
  };
  for (const it of items) {
    if (it.op === 'writeStr' || it.op === 'emitStr') add(it.text);
    for (const a of it.args || []) {
      if (a && typeof a === 'object' && typeof a.str === 'string') add(a.str);
    }
    if (it.value && typeof it.value === 'object' && typeof it.value.str === 'string') {
      add(it.value.str);
    }
  }
  return order;
}

export function buildScript(itemsIn, opts = {}) {
  const setWhy = opts.setWhy !== false;
  const { items, labels } = normalizeItems(itemsIn);
  if (items.length === 0) items.push({ op: 'exit', code: 0 });
  if (items[items.length - 1].op !== 'exit' && items[items.length - 1].op !== 'jump') {
    items.push({ op: 'exit', code: 0 });
  }
  const N = items.length;

  // Slots: every name mentioned anywhere gets 8 bytes at SLOT_BASE.
  const slots = new Map();
  const slotAddr = (name) => {
    if (!slots.has(name)) slots.set(name, SLOT_BASE + slots.size * 8);
    return slots.get(name);
  };
  const scanExpr = (a) => {
    if (!a || typeof a !== 'object') return;
    if (a.slot) slotAddr(a.slot);
    if (a.addr && !['buf', 'buf2', 'buf3', 'ts', 'ts2', 'its', 'ca', 'iov'].includes(a.addr)) slotAddr(a.addr);
    if (a.slotAddr) slotAddr(a.slotAddr);
  };
  for (const it of items) {
    if (it.out) slotAddr(it.out);
    if (it.slot) slotAddr(it.slot);
    if (it.eqSlot) slotAddr(it.eqSlot);
    if (it.addr && typeof it.addr === 'string' && !['buf', 'buf2', 'buf3', 'ts', 'ts2', 'its', 'ca', 'iov'].includes(it.addr)) {
      slotAddr(it.addr);
    }
    for (const a of it.args || []) scanExpr(a);
  }
  if (slots.size > (BUF_BASE - SLOT_BASE) / 8) throw new Error('too many slots');

  // Data strings, NUL-terminated, packed from DATA_LO.
  const strings = collectStrings(items);
  const stringAddr = new Map();
  let dataPos = DATA_LO;
  const dataBytes = [];
  for (const s of strings) {
    stringAddr.set(s, dataPos);
    const b = UTF8.encode(s);
    for (const x of b) dataBytes.push(x);
    dataBytes.push(0);
    dataPos += b.length + 1;
  }
  if (dataPos > SLOT_BASE) throw new Error('test data overlaps the slots');

  const token = (kase) => TOKEN_BASE + kase;

  const e = new Emitter();
  // case = pc & 0xfffff (chunk 0)
  e.localGet(0);
  e.emit(0xa7);
  e.i32(0xfffff);
  e.emit(0x71);
  e.localSet(1);

  e.loop('L');
  e.block('trap');
  for (let i = N - 1; i >= 0; i--) e.block('b' + i);
  e.localGet(1);
  const depths = [];
  for (let i = 0; i < N; i++) depths.push(e.depth('b' + i));
  e.emit(0x0e, ...uleb(N), ...depths.flatMap((d) => uleb(d)), ...uleb(e.depth('trap')));

  const jumpTo = (target) => {
    const to = typeof target === 'number' ? target : labels.get(target);
    if (to === undefined) throw new Error('unknown label: ' + target);
    if (to > currentCase && e.labels.includes('b' + to)) {
      e.br('b' + to);
    } else {
      e.i32(to);
      e.localSet(1);
      e.br('L');
    }
  };

  let currentCase = 0;
  const expr = (a) => {
    if (typeof a === 'bigint' || typeof a === 'number') {
      e.i64(a);
      return;
    }
    if (!a || typeof a !== 'object') throw new Error('bad argument expression');
    if (a.str !== undefined) {
      e.i64(stringAddr.get(a.str));
      return;
    }
    if (a.buf !== undefined) {
      const base = a.buf === 1 ? BUF2_BASE : a.buf === 2 ? BUF3_BASE : BUF_BASE;
      e.i64(base + (a.add || 0));
      return;
    }
    if (a.slot) {
      const at = slotAddr(a.slot);
      e.i32(at);
      e.emit(0x29, 0x03, 0x00);
      if (a.add) {
        e.i64(a.add);
        e.emit(0x7c);
      }
      return;
    }
    if (a.addr || a.slotAddr) {
      const name = a.addr || a.slotAddr;
      e.i64(addrOf(name, a.add));
      return;
    }
    throw new Error('bad argument expression: ' + JSON.stringify(a));
  };

  const FIXED = {
    buf: BUF_BASE, buf2: BUF2_BASE, buf3: BUF3_BASE,
    ts: TS_ADDR, ts2: TS_ADDR + 16, its: ITS_ADDR, ca: CA_ADDR, iov: IOV_ADDR,
  };
  const addrOf = (a, add) => {
    if (typeof a === 'number') return a + (add || 0);
    if (FIXED[a] !== undefined) return FIXED[a] + (add || 0);
    return slotAddr(a) + (add || 0);
  };

  const pushAddr = (it) => {
    if (it.at !== undefined) {
      expr(it.at);
      e.emit(0xa7); // i32.wrap_i64
    } else {
      e.i32(addrOf(it.addr, it.add));
    }
  };

  // A blocking syscall returns from resume before the out store would run, so
  // the result is stored at the START of the next case (where the host's wake
  // result has reached $rax).  clone uses outAfter: the child must not store
  // its rax=0 over the parent's tid.
  const pendingStore = new Map();
  const storeRax = (slot) => {
    e.i32(slotAddr(slot));
    e.globalGet(3);
    e.emit(0x37, 0x03, 0x00);
  };

  const emitSys = (nr, args, out, kase, outAfter = false) => {
    e.i64(token(kase + 1));
    e.globalSet(0); // $pc = after
    e.i64(nr); // the syscall number is the first of the seven i64s
    for (let i = 0; i < 6; i++) expr(args[i] === undefined ? 0 : args[i]);
    e.call(0); // y.sys
    e.globalSet(3); // $rax
    e.globalGet(1); // $why
    e.if_();
    e.emit(0x0f); // return
    e.end();
    if (out && outAfter) storeRax(out);
    else if (out) pendingStore.set(kase + 1, out);
  };

  for (let i = 0; i < N; i++) {
    e.end(); // close b_i
    currentCase = i;
    if (pendingStore.has(i)) {
      storeRax(pendingStore.get(i));
      pendingStore.delete(i);
    }
    const it = items[i];
    switch (it.op) {
      case 'label':
      case 'nop':
        break;
      case 'set':
        e.i32(slotAddr(it.slot));
        e.i64(it.value);
        e.emit(0x37, 0x03, 0x00);
        break;
      case 'sys':
        emitSys(it.nr, it.args || [], it.out, i, !!it.outAfter);
        break;
      case 'storeRax':
        storeRax(it.slot);
        break;
      case 'exit':
        emitSys(it.group === false ? 60 : 231, [it.code || 0], null, i);
        e.emit(0x00); // unreachable
        break;
      case 'writeStr': {
        const at = stringAddr.get(it.text);
        emitSys(1, [it.fd === undefined ? 1 : it.fd, at, UTF8.encode(it.text).length], null, i);
        break;
      }
      case 'emitStr': {
        const at = stringAddr.get(it.text);
        emitSys(1, [1, at, UTF8.encode(it.text).length], null, i);
        break;
      }
      case 'emit':
        emitSys(1, [1, slotAddr(it.slot), it.count || 8], null, i);
        break;
      case 'put':
        pushAddr(it);
        expr(it.value);
        e.emit(0x37, 0x03, 0x00);
        break;
      case 'put32':
        pushAddr(it);
        expr(it.value);
        e.emit(0xa7); // i32.wrap_i64
        e.emit(0x36, 0x02, 0x00);
        break;
      case 'put16':
        pushAddr(it);
        expr(it.value);
        e.emit(0xa7);
        e.emit(0x3b, 0x01, 0x00);
        break;
      case 'put8':
        pushAddr(it);
        expr(it.value);
        e.emit(0xa7);
        e.emit(0x3a, 0x00, 0x00);
        break;
      case 'load':
        e.i32(slotAddr(it.slot));
        pushAddr(it);
        e.emit(0x29, 0x03, 0x00);
        e.emit(0x37, 0x03, 0x00);
        break;
      case 'load32':
        e.i32(slotAddr(it.slot));
        pushAddr(it);
        e.emit(0x28, 0x02, 0x00);
        e.emit(0xad); // i64.extend_i32_u
        e.emit(0x37, 0x03, 0x00);
        break;
      case 'load16':
        e.i32(slotAddr(it.slot));
        pushAddr(it);
        e.emit(0x2f, 0x01, 0x00);
        e.emit(0xad);
        e.emit(0x37, 0x03, 0x00);
        break;
      case 'load8':
        e.i32(slotAddr(it.slot));
        pushAddr(it);
        e.emit(0x2d, 0x00, 0x00);
        e.emit(0xad);
        e.emit(0x37, 0x03, 0x00);
        break;
      case 'emitMem': {
        const ptr = it.at !== undefined ? it.at : addrOf(it.addr, it.add);
        emitSys(1, [1, ptr, it.count || 8], null, i);
        break;
      }
      case 'jump':
        jumpTo(it.to);
        break;
      case 'branchZero':
        e.globalGet(3);
        e.emit(0x50); // i64.eqz
        e.if_();
        jumpTo(it.to);
        e.end();
        if (it.else !== undefined) jumpTo(it.else);
        break;
      case 'jumpIf':
        e.i32(slotAddr(it.slot));
        e.emit(0x29, 0x03, 0x00);
        e.i64(it.eq);
        e.emit(0x51); // i64.eq
        e.if_();
        jumpTo(it.to);
        e.end();
        break;
      case 'sleep': {
        const ms = Number(it.ms) || 0;
        const sec = Math.floor(ms / 1000);
        const nsec = Math.floor((ms % 1000) * 1e6);
        e.i32(TS_ADDR);
        e.i64(sec);
        e.emit(0x37, 0x03, 0x00);
        e.i32(TS_ADDR + 8);
        e.i64(nsec);
        e.emit(0x37, 0x03, 0x00);
        emitSys(35, [TS_ADDR, 0], null, i);
        break;
      }
      case 'spin': {
        const n = Number(it.n) || 1;
        e.i64(n);
        e.localSet(3);
        e.block('spinEnd');
        e.loop('spinLoop');
        e.globalGet(2); // fuel
        e.i32(1);
        e.emit(0x6b); // i32.sub
        e.globalSet(2);
        e.globalGet(2);
        e.i32(0);
        e.emit(0x4c); // i32.le_s
        e.if_();
        e.i32(2); // PREEMPT
        e.globalSet(1);
        e.i64(token(i + 1));
        e.globalSet(0);
        e.emit(0x0f); // return
        e.end();
        e.localGet(3);
        e.i64(1);
        e.emit(0x7d); // i64.sub
        e.localTee(3);
        e.emit(0x50); // i64.eqz
        e.brIf('spinEnd');
        e.br('spinLoop');
        e.end();
        e.end();
        break;
      }
      default:
        throw new Error('unknown script op: ' + it.op);
    }
  }
  e.end(); // close trap
  e.i32(11);
  e.call(1); // y.trap(SIGSEGV)
  e.emit(0x00);
  e.end(); // close L

  const resumeBody = e.bytes;

  // ctx_save(ptr): zero 512 bytes, then rax/pc/r1/r11/fs.
  const save = new Emitter();
  for (let off = 0; off < 512; off += 8) {
    save.localGet(0);
    save.i64(0);
    save.emit(0x37, 0x03, ...uleb(off));
  }
  save.localGet(0);
  save.globalGet(3); // rax
  save.emit(0x37, 0x03, 0x00);
  save.localGet(0);
  save.globalGet(0); // pc
  save.emit(0x37, 0x03, 0x08); // rcx
  save.localGet(0);
  save.globalGet(0);
  save.emit(0x37, 0x03, ...uleb(264)); // pc
  save.localGet(0);
  save.globalGet(4); // fs
  save.emit(0x37, 0x03, ...uleb(256));

  const load = new Emitter();
  load.localGet(0);
  load.emit(0x29, 0x03, 0x00);
  load.globalSet(3); // rax
  load.localGet(0);
  load.emit(0x29, 0x03, ...uleb(264));
  load.globalSet(0); // pc
  load.localGet(0);
  load.emit(0x29, 0x03, ...uleb(256));
  load.globalSet(4); // fs

  const fuel = new Emitter();
  fuel.localGet(0);
  fuel.globalSet(2);

  const why = new Emitter();
  why.globalGet(1);

  const setWhyBody = new Emitter();
  setWhyBody.localGet(0);
  setWhyBody.globalSet(1);

  const types = [
    [0x60, 7, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 1, 0x7e],
    [0x60, 1, 0x7f, 0],
    [0x60, 1, 0x7e, 0],
    [0x60, 1, 0x7f, 0],
    [0x60, 1, 0x7f, 0],
    [0x60, 1, 0x7f, 0],
    [0x60, 0, 1, 0x7f],
    [0x60, 1, 0x7f, 0],
  ];
  const typeSec = section(1, vec(types));

  const importSec = section(2, [
    ...uleb(2),
    ...str('y'), ...str('sys'), 0x00, ...uleb(0),
    ...str('y'), ...str('trap'), 0x00, ...uleb(1),
  ]);

  const funcTypes = [2, 3, 4, 5, 6];
  if (setWhy) funcTypes.push(7);
  const funcSec = section(3, [...uleb(funcTypes.length), ...funcTypes.flatMap((t) => uleb(t))]);

  const memSec = section(5, [...uleb(1), 0x00, ...uleb(MEMORY_PAGES)]);

  const globals = [
    [0x7e, 0x01, 0x42, 0x00, 0x0b], // pc i64 = 0
    [0x7f, 0x01, 0x41, 0x00, 0x0b], // why i32 = 0
    [0x7f, 0x01, 0x41, 0x00, 0x0b], // fuel i32 = 0
    [0x7e, 0x01, 0x42, 0x00, 0x0b], // rax i64 = 0
    [0x7e, 0x01, 0x42, 0x00, 0x0b], // fs i64 = 0
  ];
  const globalSec = section(6, [...uleb(globals.length), ...globals.flat()]);

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
  for (const x of exportsList) exportPayload = exportPayload.concat(str(x[0]), [x[1]], uleb(x[2]));
  const exportSec = section(7, exportPayload);

  const bodies = [resumeBody, save.bytes, load.bytes, fuel.bytes, why.bytes];
  if (setWhy) bodies.push(setWhyBody.bytes);
  const codeSec = section(10, [...uleb(bodies.length), ...bodies.map((b) => body(b)).flat()]);

  let dataSec = [];
  if (dataBytes.length > 0) {
    dataSec = section(11, [
      ...uleb(1),
      0x00,
      0x41, ...sleb(DATA_LO),
      0x0b,
      ...uleb(dataBytes.length),
      ...dataBytes,
    ]);
  }

  const names = [[2, 'resume'], [3, 'ctx_save'], [4, 'ctx_load'], [5, 'set_fuel'], [6, 'why']];
  if (setWhy) names.push([7, 'set_why']);
  let nameSub = [...uleb(names.length)];
  for (const nm of names) nameSub = nameSub.concat(uleb(nm[0]), str(nm[1]));
  const nameSec = section(0, [...str('name'), 2, ...uleb(nameSub.length), ...nameSub]);

  const yweb = [
    'abi=1',
    'stack_lo=0',
    'stack_hi=' + STACK_HI,
    'data_lo=' + DATA_LO,
    'data_end=' + DATA_END,
    'heap_lo=' + HEAP_LO,
    'entry=' + token(0),
    'chunks=1',
    'threads=1',
    'gui=0',
    'audio=0',
  ].join('\n');
  const ywebSec = section(0, [...str('yweb'), ...UTF8.encode(yweb)]);

  const header = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
  return new Uint8Array(
    header.concat(typeSec, importSec, funcSec, memSec, globalSec, exportSec, codeSec, dataSec, nameSec, ywebSec)
  );
}
