// src/web/gui.js -- the nine gui host functions, and the
// two displays behind them: the page's canvas and Node's virtual display.
//
// The Y side is src/y/std/gui.web.y.  It resolves these names through
// y_os_host_sym and passes every argument as an i64:
//
//   gui.open       w, h, title_ptr, title_len          -> id (0: no display)
//   gui.size       id                                  -> w | (h << 32)
//   gui.present    id, pix_ptr, pix_w, pix_h, x0, y0, x1, y1 -> 0
//   gui.poll       id, buf_ptr, cap                    -> events written
//   gui.wait       id, ms                              -> 1 while events are pending
//   gui.title      id, ptr, len                        -> 0
//   gui.resize     id, w, h                            -> 0 fixed, -1 fit
//   gui.close      id                                  -> 0
//   gui.read_back  id, dst_ptr, cap                    -> bytes copied
//
// The cap of gui.poll is a count of events (the overlay passes gui's EVQ,
// 128), each five i64s: kind, a, b, c, d -- exactly gui's Event layout.
//
// This file has no node: import and touches no DOM at module scope, so both
// hosts load it: page.js gives it a CanvasDisplay, yhost.js a VirtualDisplay.

export const EV_KEY = 1;
export const EV_CHAR = 2;
export const EV_MOVE = 3;
export const EV_BUTTON = 4;
export const EV_WHEEL = 5;
export const EV_RESIZE = 6;
export const EV_FOCUS = 7;
export const EV_CLOSE = 8;
export const EV_EXPOSE = 9;

const MOD_SHIFT = 1;
const MOD_CTRL = 2;
const MOD_ALT = 4;

const BTN_LEFT = 1;
const BTN_MIDDLE = 2;
const BTN_RIGHT = 4;

const NAMES = [
  'gui.open', 'gui.size', 'gui.present', 'gui.poll', 'gui.wait',
  'gui.title', 'gui.resize', 'gui.close', 'gui.read_back',
];

// Appendix D: DOM KeyboardEvent.code -> gui's Windows virtual-key number.
export const VK_BY_CODE = {
  Backspace: 8, Tab: 9, Enter: 13, NumpadEnter: 13,
  ShiftLeft: 16, ShiftRight: 16, ControlLeft: 17, ControlRight: 17,
  AltLeft: 18, AltRight: 18, Escape: 27, Space: 32,
  PageUp: 33, PageDown: 34, End: 35, Home: 36,
  ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40,
  Insert: 45, Delete: 46,
  Semicolon: 186, Equal: 187, Comma: 188, Minus: 189,
  Period: 190, Slash: 191, Backquote: 192,
  BracketLeft: 219, Backslash: 220, BracketRight: 221, Quote: 222,
};
for (let i = 0; i < 26; i++) VK_BY_CODE['Key' + String.fromCharCode(65 + i)] = 65 + i;
for (let i = 0; i < 10; i++) {
  VK_BY_CODE['Digit' + i] = 48 + i;
  VK_BY_CODE['Numpad' + i] = 96 + i;
}
for (let i = 1; i <= 12; i++) VK_BY_CODE['F' + i] = 111 + i;

function toInt(v) {
  if (typeof v === 'bigint') return Number(v);
  return Number(v) | 0;
}

const EINVAL = -22;
const EFAULT = -14;

function modsOf(e) {
  let m = 0;
  if (e.shiftKey) m |= MOD_SHIFT;
  if (e.ctrlKey) m |= MOD_CTRL;
  if (e.altKey) m |= MOD_ALT;
  return m;
}

// The text a keydown types, as gui's x_char produces it for the same key:
// Ctrl+letter becomes the control code, Meta suppresses ordinary text, and the
// editing keys keep their ASCII codes.  0 means "no EV_CHAR".
export function charForEvent(e) {
  const code = e.code || '';
  if (code === 'Enter' || code === 'NumpadEnter') return 13;
  if (code === 'Backspace') return 8;
  if (code === 'Tab') return 9;
  if (code === 'Escape') return 27;
  if (e.ctrlKey && /^Key[A-Z]$/.test(code)) return code.charCodeAt(3) & 0x1f;
  if (e.ctrlKey || e.metaKey) return 0;
  const key = e.key;
  if (typeof key === 'string' && key.length > 0) {
    const cps = Array.from(key);
    if (cps.length === 1) return cps[0].codePointAt(0);
  }
  return 0;
}

function isControlKey(code) {
  if (/^F([1-9]|1[0-2])$/.test(code)) return true;
  return code === 'ArrowLeft' || code === 'ArrowUp' || code === 'ArrowRight' || code === 'ArrowDown'
    || code === 'Space' || code === 'Tab' || code === 'Backspace';
}

function domButtonsMask(buttons) {
  return ((buttons & 1) ? BTN_LEFT : 0)
    | ((buttons & 4) ? BTN_MIDDLE : 0)
    | ((buttons & 2) ? BTN_RIGHT : 0);
}

// -- the display-independent half -------------------------------------------

/** The nine host functions over a display (CanvasDisplay or VirtualDisplay). */
export class Gui {
  constructor(host, display) {
    this.host = host;
    this.display = display || null;
    this.windows = new Map();
    this.nextId = 1;
    this.lastFrame = null;
    this.lastWidth = 0;
    this.lastHeight = 0;
    for (const name of NAMES) {
      host.register(name, (args, mem) => this.dispatch(name.slice(4), args, mem));
    }
  }

  dispatch(name, args, mem) {
    switch (name) {
      case 'open': return this.open(args, mem);
      case 'size': return this.size(args);
      case 'present': return this.present(args, mem);
      case 'poll': return this.poll(args, mem);
      case 'wait': return this.wait(args);
      case 'title': return this.title(args, mem);
      case 'resize': return this.resize(args);
      case 'close': return this.close(args);
      case 'read_back': return this.readBack(args, mem);
      default: return BigInt(EINVAL);
    }
  }

  get(id) {
    return this.windows.get(id) || null;
  }

  open(args, mem) {
    if (!this.display) return 0n;
    const w = toInt(args[0]);
    const h = toInt(args[1]);
    if (!(w > 0 && h > 0)) return 0n;
    if (w > 16384 || h > 16384) return 0n;
    let title = '';
    const len = toInt(args[3]);
    if (len > 0) {
      const s = mem.str(toInt(args[2]), len);
      if (s === null) return BigInt(EFAULT);
      title = s;
    }
    const win = {
      id: this.nextId++,
      width: w,
      height: h,
      title,
      alive: true,
      frame: null,
      events: [],
    };
    let actual = { width: w, height: h };
    try {
      actual = this.display.open(win, { width: w, height: h, title }) || actual;
    } catch (e) {
      this.nextId--;
      return 0n;
    }
    win.width = Math.max(1, toInt(actual.width) || w);
    win.height = Math.max(1, toInt(actual.height) || h);
    win.frame = new Uint8Array(win.width * win.height * 4);
    this.windows.set(win.id, win);
    this.rememberFrame(win);
    // Fit mode: the page, not the request, chose the client size.  Deliver it
    // as the EV_RESIZE the window system would have sent before the first
    // frame, so a program that polls before drawing starts at the right size.
    if (win.width !== w || win.height !== h) {
      this.push(win, EV_RESIZE, win.width, win.height, 0, 0);
    }
    return BigInt(win.id);
  }

  size(args) {
    const win = this.get(toInt(args[0]));
    if (!win) return BigInt(EINVAL);
    return (BigInt(win.width) & 0xffffffffn) | ((BigInt(win.height) & 0xffffffffn) << 32n);
  }

  present(args, mem) {
    const win = this.get(toInt(args[0]));
    if (!win) return BigInt(EINVAL);
    const ptr = toInt(args[1]);
    const pixW = toInt(args[2]);
    const pixH = toInt(args[3]);
    let x0 = toInt(args[4]);
    let y0 = toInt(args[5]);
    let x1 = toInt(args[6]);
    let y1 = toInt(args[7]);
    if (!(pixW > 0 && pixH > 0)) return BigInt(EINVAL);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > win.width) x1 = win.width;
    if (y1 > win.height) y1 = win.height;
    if (x0 >= x1 || y0 >= y1) return 0n;
    const stride = pixW * 4;
    const frame = win.frame;
    for (let y = y0; y < y1; y++) {
      const src = this.host.memoryBytes(ptr + y * stride + x0 * 4, (x1 - x0) * 4);
      if (src === null) return BigInt(EFAULT);
      frame.set(src, (y * win.width + x0) * 4);
    }
    this.rememberFrame(win);
    if (this.display) {
      try { this.display.present(win, x0, y0, x1, y1); } catch (e) { /* the canvas is gone */ }
    }
    return 0n;
  }

  poll(args, mem) {
    const win = this.get(toInt(args[0]));
    if (!win) return BigInt(EINVAL);
    const cap = toInt(args[2]);
    if (cap < 0) return BigInt(EINVAL);
    this.pump(win);
    if (win.events.length === 0 || cap === 0) return 0n;
    const n = Math.min(cap, win.events.length);
    const view = this.host.memoryDataView(toInt(args[1]), n * 5 * 8);
    if (view === null) return BigInt(EFAULT);
    for (let i = 0; i < n; i++) {
      const ev = win.events[i];
      const at = i * 40;
      view.setBigInt64(at, BigInt(ev[0]), true);
      view.setBigInt64(at + 8, BigInt(ev[1]), true);
      view.setBigInt64(at + 16, BigInt(ev[2]), true);
      view.setBigInt64(at + 24, BigInt(ev[3]), true);
      view.setBigInt64(at + 32, BigInt(ev[4]), true);
    }
    win.events.splice(0, n);
    return BigInt(n);
  }

  wait(args) {
    const win = this.get(toInt(args[0]));
    if (!win) return BigInt(EINVAL);
    this.pump(win);
    if (win.events.length > 0) return 1n;
    const ms = toInt(args[1]);
    if (!(ms > 0) || !this.display || typeof this.display.wait !== 'function') return 0n;
    let r;
    try {
      r = this.display.wait(win, ms, this);
    } catch (e) {
      return 0n;
    }
    if (r && typeof r.then === 'function') {
      return r.then((n) => {
        this.pump(win);
        return BigInt(n > 0 || win.events.length > 0 ? 1 : 0);
      });
    }
    this.pump(win);
    return BigInt(r > 0 || win.events.length > 0 ? 1 : 0);
  }

  title(args, mem) {
    const win = this.get(toInt(args[0]));
    if (!win) return BigInt(EINVAL);
    const len = toInt(args[2]);
    let text = '';
    if (len > 0) {
      const s = mem.str(toInt(args[1]), len);
      if (s === null) return BigInt(EFAULT);
      text = s;
    }
    win.title = text;
    if (this.display && typeof this.display.title === 'function') {
      try { this.display.title(win, text); } catch (e) { /* optional */ }
    }
    return 0n;
  }

  resize(args) {
    const win = this.get(toInt(args[0]));
    if (!win) return BigInt(EINVAL);
    const mode = this.display && this.display.mode ? this.display.mode : 'fixed';
    if (mode === 'fit') return -1n;
    const w = toInt(args[1]);
    const h = toInt(args[2]);
    if (!(w > 0 && h > 0)) return BigInt(EINVAL);
    this.resizeWindow(win, w, h);
    this.push(win, EV_RESIZE, w, h, 0, 0);
    if (this.display && typeof this.display.resize === 'function') {
      try { this.display.resize(win, w, h); } catch (e) { /* optional */ }
    }
    return 0n;
  }

  close(args) {
    const id = toInt(args[0]);
    const win = this.get(id);
    if (!win) return BigInt(EINVAL);
    win.alive = false;
    this.windows.delete(id);
    if (this.display && typeof this.display.close === 'function') {
      try { this.display.close(win); } catch (e) { /* optional */ }
    }
    return 0n;
  }

  readBack(args, mem) {
    const win = this.get(toInt(args[0]));
    if (!win) return BigInt(EINVAL);
    const cap = toInt(args[2]);
    if (!(cap > 0) || !win.frame) return 0n;
    const n = Math.min(cap, win.frame.length);
    const dst = this.host.memoryBytes(toInt(args[1]), n);
    if (dst === null) return BigInt(EFAULT);
    dst.set(win.frame.subarray(0, n));
    return BigInt(n);
  }

  // -- used by the displays -------------------------------------------------

  resizeWindow(win, w, h) {
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    if (win.width !== w || win.height !== h) {
      win.width = w;
      win.height = h;
      win.frame = new Uint8Array(w * h * 4);
      this.rememberFrame(win);
    }
  }

  // The display observed a new size (fit mode's ResizeObserver, or a DOM
  // resize); queue the event gui's set_size would have produced.
  displayResize(win, w, h) {
    if (!win || !this.windows.has(win.id)) return;
    w = Math.max(1, toInt(w));
    h = Math.max(1, toInt(h));
    if (win.width === w && win.height === h) return;
    this.resizeWindow(win, w, h);
    this.push(win, EV_RESIZE, w, h, 0, 0);
  }

  push(win, kind, a, b, c, d) {
    if (!win || !this.windows.has(win.id)) return;
    // gui's own queue holds 128 events (EVQ); a program that never polls
    // drops the excess rather than growing without bound.
    if (win.events.length >= 128) return;
    win.events.push([kind, a, b, c, d]);
    if (this.display && typeof this.display.onEvent === 'function') {
      try { this.display.onEvent(win); } catch (e) { /* optional */ }
    }
  }

  pump(win) {
    if (!this.display || !win || typeof this.display.eventsDue !== 'function') return;
    let due;
    try {
      due = this.display.eventsDue(win, this.host.now());
    } catch (e) {
      due = [];
    }
    for (const ev of due) {
      if (ev[0] === EV_RESIZE) this.resizeWindow(win, ev[1], ev[2]);
      this.push(win, ev[0], ev[1], ev[2], ev[3], ev[4]);
    }
  }

  rememberFrame(win) {
    this.lastFrame = win.frame;
    this.lastWidth = win.width;
    this.lastHeight = win.height;
  }

  /** The last presented frame as a binary PPM (P6), or null. */
  dumpPPM() {
    const frame = this.lastFrame;
    const w = this.lastWidth;
    const h = this.lastHeight;
    if (!frame || !(w > 0 && h > 0)) return null;
    const head = 'P6\n' + w + ' ' + h + '\n255\n';
    const out = new Uint8Array(head.length + w * h * 3);
    for (let i = 0; i < head.length; i++) out[i] = head.charCodeAt(i) & 0xff;
    let at = head.length;
    for (let i = 0, n = w * h; i < n; i++) {
      const p = i * 4;
      out[at++] = frame[p + 2]; // R
      out[at++] = frame[p + 1]; // G
      out[at++] = frame[p];     // B
    }
    return out;
  }
}

/** Resolve the nine names on a host and return the Gui (or null for no display). */
export function installGui(host, display) {
  return new Gui(host, display || null);
}

// -- the page's canvas ------------------------------------------------------

/** The browser display: #ycanvas shows the window, and DOM input becomes events. */
export class CanvasDisplay {
  constructor(opts = {}) {
    this.canvas = opts.canvas || null;
    this.stage = opts.stage || (this.canvas ? this.canvas.parentElement : null);
    this.config = opts.config || {};
    this.onOpen = typeof opts.onOpen === 'function' ? opts.onOpen : null;
    this.onZoom = typeof opts.onZoom === 'function' ? opts.onZoom : null;
    this.notifiedZoom = 0;
    this.mode = String(this.config.canvas || 'fixed') === 'fit' ? 'fit' : 'fixed';
    this.zoomSetting = String(this.config.zoom || 'auto');
    this.zoom = 1;
    this.gui = null;
    this.win = null;
    this.wheelAcc = 0;
    this.observer = null;
    this.waiters = [];
    this.ctx = this.canvas && typeof this.canvas.getContext === 'function'
      ? this.canvas.getContext('2d') : null;
    if (this.canvas) {
      this.bindInput();
      this.applyLayout();
    }
    if (typeof ResizeObserver === 'function' && this.stage) {
      this.observer = new ResizeObserver(() => this.relayout());
      this.observer.observe(this.stage);
    }
    // A headless page whose green-thread loop keeps posting MessageChannel
    // slices can go a long time without a rendering update, and Chrome then
    // defers ResizeObserver to a frame it never reaches.  In fit mode a cheap
    // timer keeps the page's size authoritative; it is a no-op when nothing
    // moved, and the observer remains the primary path.
    if (this.mode === 'fit' && typeof setInterval === 'function') {
      this.fitTimer = setInterval(() => this.relayout(), 100);
    }
    if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
      window.addEventListener('pagehide', () => this.pagehide());
    }
  }

  bind(gui) {
    this.gui = gui;
  }

  // -- layout ---------------------------------------------------------------

  windowSize() {
    if (this.win) return { width: this.win.width, height: this.win.height };
    return { width: this.canvas ? this.canvas.width || 640 : 640, height: this.canvas ? this.canvas.height || 400 : 400 };
  }

  computeZoom() {
    const setting = this.zoomSetting;
    if (setting === 'auto') {
      if (this.mode === 'fit') return 1;
      const size = this.windowSize();
      const sw = this.stage ? this.stage.clientWidth : 0;
      const sh = this.stage ? this.stage.clientHeight : 0;
      if (!(sw > 0 && sh > 0)) return 1;
      const z = Math.min(Math.floor(sw / size.width), Math.floor(sh / size.height));
      return Math.max(1, Math.min(8, z || 1));
    }
    const n = Math.floor(Number(setting));
    return Math.max(1, Math.min(8, Number.isFinite(n) ? n : 1));
  }

  setZoom(value) {
    if (value !== undefined && value !== null) this.zoomSetting = String(value);
    this.zoom = this.computeZoom();
    this.applyLayout();
    if (this.mode === 'fit') this.relayout();
    this.notifyZoom();
    return this.zoom;
  }

  notifyZoom() {
    if (!this.onZoom || this.notifiedZoom === this.zoom) return;
    this.notifiedZoom = this.zoom;
    try { this.onZoom(this.zoom); } catch (e) { /* the label is optional */ }
  }

  setSmooth(smooth) {
    this.smooth = smooth === true || String(smooth) === 'true';
    if (this.canvas) this.canvas.style.imageRendering = this.smooth ? 'auto' : 'pixelated';
  }

  applyLayout() {
    if (!this.canvas) return;
    const smooth = this.config.smooth === true || String(this.config.smooth) === 'true';
    this.canvas.style.imageRendering = smooth ? 'auto' : 'pixelated';
    if (this.mode === 'fit') {
      this.canvas.classList.add('fit');
      // The backing store is floor(stage / zoom), so the CSS size must be
      // backing * zoom: an integer scale with no half pixels at the edge.
      const w = this.canvas.width || 640;
      const h = this.canvas.height || 400;
      this.canvas.style.width = (w * this.zoom) + 'px';
      this.canvas.style.height = (h * this.zoom) + 'px';
      this.canvas.style.maxWidth = 'none';
      this.canvas.style.maxHeight = 'none';
    } else {
      this.canvas.classList.remove('fit');
      const size = this.windowSize();
      this.canvas.style.width = (size.width * this.zoom) + 'px';
      this.canvas.style.height = (size.height * this.zoom) + 'px';
      this.canvas.style.maxWidth = 'none';
      this.canvas.style.maxHeight = 'none';
    }
  }

  // The stage changed size: in fit mode the backing store is floor(css/zoom);
  // in fixed mode only the CSS scale (auto zoom) can change.
  relayout() {
    if (!this.canvas || !this.stage) return;
    if (this.mode === 'fixed') {
      const z = this.computeZoom();
      if (z !== this.zoom) {
        this.zoom = z;
        this.applyLayout();
        this.notifyZoom();
      }
      return;
    }
    const cw = this.stage.clientWidth;
    const ch = this.stage.clientHeight;
    if (!(cw > 0 && ch > 0)) return;
    const w = Math.max(1, Math.floor(cw / this.zoom));
    const h = Math.max(1, Math.floor(ch / this.zoom));
    if (this.canvas.width === w && this.canvas.height === h) return;
    this.canvas.width = w;
    this.canvas.height = h;
    this.applyLayout();
    if (this.gui && this.win) this.gui.displayResize(this.win, w, h);
  }

  // -- the display interface ------------------------------------------------

  open(win, req) {
    this.win = win;
    this.wheelAcc = 0;
    if (this.canvas) {
      this.canvas.classList.add('visible');
      if (this.mode === 'fit') {
        const cw = this.stage ? this.stage.clientWidth : 0;
        const ch = this.stage ? this.stage.clientHeight : 0;
        this.zoom = this.computeZoom();
        if (cw > 0 && ch > 0) {
          this.canvas.width = Math.max(1, Math.floor(cw / this.zoom));
          this.canvas.height = Math.max(1, Math.floor(ch / this.zoom));
        } else {
          this.canvas.width = req.width;
          this.canvas.height = req.height;
        }
      } else {
        this.zoom = this.computeZoom();
        this.canvas.width = req.width;
        this.canvas.height = req.height;
      }
      this.applyLayout();
    }
    this.notifyZoom();
    if (this.onOpen) {
      try { this.onOpen(); } catch (e) { /* the page's panel is optional */ }
    }
    return { width: this.canvas ? this.canvas.width : req.width, height: this.canvas ? this.canvas.height : req.height };
  }

  present(win, x0, y0, x1, y1) {
    if (!this.canvas || !this.ctx) return;
    // The canvas belongs to the page in fit mode; present only draws, and a
    // window that has not processed its EV_RESIZE yet simply covers less.
    const rw = x1 - x0;
    const rh = y1 - y0;
    if (rw <= 0 || rh <= 0) return;
    const img = this.ctx.createImageData(rw, rh);
    const dst = img.data;
    const frame = win.frame;
    for (let y = 0; y < rh; y++) {
      let s = ((y0 + y) * win.width + x0) * 4;
      let d = y * rw * 4;
      for (let x = 0; x < rw; x++) {
        dst[d] = frame[s + 2];     // R
        dst[d + 1] = frame[s + 1]; // G
        dst[d + 2] = frame[s];     // B
        dst[d + 3] = 255;          // alpha is always opaque
        s += 4;
        d += 4;
      }
    }
    this.ctx.putImageData(img, x0, y0);
  }

  resize(win, w, h) {
    if (!this.canvas || this.mode === 'fit') return;
    this.canvas.width = w;
    this.canvas.height = h;
    this.applyLayout();
  }

  close(win) {
    if (this.win && this.win.id === win.id) this.win = null;
  }

  title(win, text) {
    if (this.canvas && text) this.canvas.setAttribute('aria-label', text);
  }

  onEvent(win) {
    const waiters = this.waiters || [];
    if (waiters.length === 0) return;
    this.waiters = [];
    for (const w of waiters) w();
  }

  wait(win, ms, gui) {
    if (win.events.length > 0) return Promise.resolve(1);
    if (!(ms > 0)) return 0;
    return new Promise((resolve) => {
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        resolve(win.events.length > 0 ? 1 : 0);
      };
      let timer = null;
      const wake = () => {
        if (timer !== null) clearTimeout(timer);
        finish();
      };
      this.waiters = this.waiters || [];
      this.waiters.push(wake);
      timer = setTimeout(() => {
        this.waiters = (this.waiters || []).filter((w) => w !== wake);
        finish();
      }, ms);
    });
  }

  eventsDue() {
    return [];
  }

  pagehide() {
    if (this.gui && this.win) this.gui.push(this.win, EV_CLOSE, 0, 0, 0, 0);
  }

  // -- input ----------------------------------------------------------------

  push(kind, a, b, c, d) {
    if (this.gui && this.win) this.gui.push(this.win, kind, a, b, c, d);
  }

  coords(e) {
    const c = this.canvas;
    if (!c) return { x: 0, y: 0 };
    const r = c.getBoundingClientRect();
    const w = c.width || 1;
    const h = c.height || 1;
    // A pixel centre maps to .5 exactly; the tiny bias keeps a 49.999999 from
    // flooring to the previous pixel.
    const x = Math.floor(((e.clientX - r.left) * w) / (r.width || 1) + 1e-3);
    const y = Math.floor(((e.clientY - r.top) * h) / (r.height || 1) + 1e-3);
    return { x: Math.max(0, Math.min(w - 1, x)), y: Math.max(0, Math.min(h - 1, y)) };
  }

  bindInput() {
    const c = this.canvas;
    c.addEventListener('keydown', (e) => this.onKey(e, true));
    c.addEventListener('keyup', (e) => this.onKey(e, false));
    c.addEventListener('pointerdown', (e) => this.onPointer(e, 'down'));
    c.addEventListener('pointerup', (e) => this.onPointer(e, 'up'));
    c.addEventListener('pointermove', (e) => this.onPointer(e, 'move'));
    c.addEventListener('pointercancel', (e) => this.onPointer(e, 'up'));
    c.addEventListener('wheel', (e) => this.onWheel(e), { passive: false });
    c.addEventListener('contextmenu', (e) => e.preventDefault());
    c.addEventListener('focus', () => this.push(EV_FOCUS, 1, 0, 0, 0));
    c.addEventListener('blur', () => this.push(EV_FOCUS, 0, 0, 0, 0));
    c.addEventListener('compositionend', (e) => this.onText(e && e.data));
    c.addEventListener('paste', (e) => {
      let text = '';
      try {
        if (e.clipboardData) text = e.clipboardData.getData('text/plain') || '';
      } catch (err) {
        text = '';
      }
      if (text) {
        e.preventDefault();
        this.onText(text);
      }
    });
  }

  onKey(e, down) {
    if (!this.gui || !this.win) return;
    const code = e.code || '';
    const mods = modsOf(e);
    const focused = e.target === this.canvas || document.activeElement === this.canvas;
    if (down && focused && (isControlKey(code) || (e.ctrlKey && /^Key[A-Z]$/.test(code)))) {
      e.preventDefault();
    }
    const vk = VK_BY_CODE[code] || 0;
    if (vk) this.push(EV_KEY, vk, down ? 1 : 0, mods, down && e.repeat ? 1 : 0);
    if (down) {
      const cp = charForEvent(e);
      if (cp) this.push(EV_CHAR, cp, 0, mods, 0);
    }
  }

  onPointer(e, what) {
    if (!this.gui || !this.win) return;
    const p = this.coords(e);
    if (what === 'move') {
      this.push(EV_MOVE, p.x, p.y, domButtonsMask(e.buttons || 0), 0);
      return;
    }
    if (what === 'down') {
      try { this.canvas.focus(); } catch (err) { /* focus is best effort */ }
      try { this.canvas.setPointerCapture(e.pointerId); } catch (err) { /* pointer capture is optional */ }
    }
    const button = e.button === 0 ? 1 : e.button === 1 ? 2 : e.button === 2 ? 3 : 0;
    if (button === 0) return;
    this.push(EV_BUTTON, p.x, p.y, button, what === 'down' ? 1 : 0);
  }

  onWheel(e) {
    if (!this.gui || !this.win) return;
    const p = this.coords(e);
    const mode = e.deltaMode === undefined ? 0 : e.deltaMode;
    const delta = Number(e.deltaY) || 0;
    let notches;
    if (mode === 1) notches = -delta / 3;
    else if (mode === 2) notches = -delta;
    else notches = -delta / 100;
    this.wheelAcc += notches;
    const whole = this.wheelAcc > 0 ? Math.floor(this.wheelAcc) : Math.ceil(this.wheelAcc);
    if (whole === 0) return;
    this.wheelAcc -= whole;
    // One gui event carries the notches this DOM event produced; the sign is
    // positive away from the user (scroll up), as X's button 4 is.
    this.push(EV_WHEEL, p.x, p.y, whole, 0);
    e.preventDefault();
  }

  onText(text) {
    if (!this.gui || !this.win || typeof text !== 'string' || text === '') return;
    for (const ch of Array.from(text)) {
      const cp = ch.codePointAt(0);
      if (cp !== undefined) this.push(EV_CHAR, cp, 0, 0, 0);
    }
  }
}

// -- Node's virtual display -------------------------------------------------

function eventTarget(obj) {
  const id = obj.id !== undefined ? obj.id : obj.window !== undefined ? obj.window : obj.win;
  return id === undefined || id === null ? 0 : Number(id);
}

function eventTime(obj) {
  const t = obj.t !== undefined ? obj.t : obj.at !== undefined ? obj.at : obj.time;
  const n = Number(t);
  return Number.isFinite(n) ? n : 0;
}

function eventKey(obj) {
  const k = obj.kind !== undefined ? obj.kind : obj.type;
  if (typeof k === 'string') {
    const s = k.toLowerCase();
    if (s === 'key' || s === 'ev_key') return EV_KEY;
    if (s === 'char' || s === 'ev_char') return EV_CHAR;
    if (s === 'move' || s === 'motion' || s === 'ev_move') return EV_MOVE;
    if (s === 'button' || s === 'ev_button') return EV_BUTTON;
    if (s === 'wheel' || s === 'ev_wheel') return EV_WHEEL;
    if (s === 'resize' || s === 'ev_resize') return EV_RESIZE;
    if (s === 'focus' || s === 'ev_focus') return EV_FOCUS;
    if (s === 'close' || s === 'ev_close') return EV_CLOSE;
    if (s === 'expose' || s === 'ev_expose') return EV_EXPOSE;
    return Number(s);
  }
  return Number(k) || 0;
}

function vkOf(v) {
  if (typeof v === 'string') {
    if (VK_BY_CODE[v] !== undefined) return VK_BY_CODE[v];
    if (Array.from(v).length === 1) return v.toUpperCase().charCodeAt(0);
    return Number(v) || 0;
  }
  return Number(v) || 0;
}

function charOf(v) {
  if (typeof v === 'string') {
    const cps = Array.from(v);
    return cps.length > 0 ? cps[0].codePointAt(0) : 0;
  }
  return Number(v) || 0;
}

function firstDefined() {
  for (let i = 0; i < arguments.length; i++) {
    const v = arguments[i];
    if (v !== undefined && v !== null) return v;
  }
  return undefined;
}

/** One JSON line -> [kind, a, b, c, d], or null for an unknown kind. */
export function parseVirtualEvent(obj) {
  const kind = eventKey(obj);
  const mods = Number(firstDefined(obj.mods, obj.modifiers, 0)) || 0;
  switch (kind) {
    case EV_KEY:
      return [EV_KEY, vkOf(firstDefined(obj.vk, obj.key, obj.code, 0)),
        Number(firstDefined(obj.down, obj.pressed, 1)) ? 1 : 0,
        mods,
        Number(firstDefined(obj.repeat, obj.rep, 0)) ? 1 : 0];
    case EV_CHAR:
      return [EV_CHAR, charOf(firstDefined(obj.cp, obj.ch, obj.char, obj.a, 0)), 0, mods, 0];
    case EV_MOVE:
      return [EV_MOVE, Number(firstDefined(obj.x, obj.a, 0)) || 0, Number(firstDefined(obj.y, obj.b, 0)) || 0,
        Number(firstDefined(obj.buttons, obj.btns, obj.c, 0)) || 0, 0];
    case EV_BUTTON:
      return [EV_BUTTON, Number(firstDefined(obj.x, obj.a, 0)) || 0, Number(firstDefined(obj.y, obj.b, 0)) || 0,
        Number(firstDefined(obj.button, obj.btn, obj.c, 1)) || 1,
        Number(firstDefined(obj.down, obj.pressed, obj.d, 1)) ? 1 : 0];
    case EV_WHEEL: {
      let c;
      if (obj.deltaY !== undefined && obj.notches === undefined && obj.c === undefined && obj.delta === undefined) {
        c = -Number(obj.deltaY) / 100;
      } else {
        const notch = firstDefined(obj.notches, obj.c, obj.delta, obj.dy, obj.deltaY);
        c = notch === undefined ? 1 : Number(notch);
      }
      c = Math.trunc(Number.isFinite(c) ? c : 0);
      if (c === 0) c = (Number(firstDefined(obj.deltaY, -1)) < 0 ? 1 : -1);
      return [EV_WHEEL, Number(firstDefined(obj.x, obj.a, 0)) || 0, Number(firstDefined(obj.y, obj.b, 0)) || 0, c, 0];
    }
    case EV_RESIZE:
      return [EV_RESIZE, Number(firstDefined(obj.w, obj.width, obj.a, 0)) || 0,
        Number(firstDefined(obj.h, obj.height, obj.b, 0)) || 0, 0, 0];
    case EV_FOCUS:
      return [EV_FOCUS, Number(firstDefined(obj.gain, obj.focus, obj.a, obj.down, 1)) ? 1 : 0, 0, 0, 0];
    case EV_CLOSE:
      return [EV_CLOSE, 0, 0, 0, 0];
    case EV_EXPOSE:
      return [EV_EXPOSE, Number(firstDefined(obj.a, 0)) || 0, Number(firstDefined(obj.b, 0)) || 0,
        Number(firstDefined(obj.c, obj.w, 0)) || 0, Number(firstDefined(obj.d, obj.h, 0)) || 0];
    default:
      if (Number.isFinite(kind) && kind > 0) {
        return [kind, Number(firstDefined(obj.a, 0)) || 0, Number(firstDefined(obj.b, 0)) || 0,
          Number(firstDefined(obj.c, 0)) || 0, Number(firstDefined(obj.d, 0)) || 0];
      }
      return null;
  }
}

/** Parse the JSON-lines --events file: one event per line, blank lines and # skipped. */
export function parseVirtualEvents(text) {
  const out = [];
  if (!text) return out;
  const lines = String(text).split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line === '' || line.startsWith('#')) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch (e) {
      throw new Error('events line ' + (i + 1) + ': ' + (e && e.message ? e.message : String(e)));
    }
    const ev = parseVirtualEvent(obj);
    if (ev === null) throw new Error('events line ' + (i + 1) + ': unknown kind');
    out.push({ t: eventTime(obj), id: eventTarget(obj), ev, order: out.length, delivered: false });
  }
  out.sort((a, b) => (a.t - b.t) || (a.order - b.order));
  return out;
}

/** Node's --display=WxH: a frame buffer and time-driven events. */
export class VirtualDisplay {
  constructor(opts = {}) {
    this.mode = 'fixed';
    this.width = Math.max(1, Number(opts.width) || 640);
    this.height = Math.max(1, Number(opts.height) || 400);
    this.events = parseVirtualEvents(opts.eventsText || '');
    this.defaultId = 0;
  }

  setEvents(text) {
    this.events = parseVirtualEvents(text);
  }

  delivers(ev, win) {
    if (ev.id) return ev.id === win.id;
    return win.id === this.defaultId;
  }

  open(win, req) {
    if (!this.defaultId) this.defaultId = win.id;
    return { width: req.width, height: req.height };
  }

  present() {}

  resize() {}

  close() {}

  title() {}

  eventsDue(win, now) {
    const due = [];
    for (const ev of this.events) {
      if (ev.delivered || ev.t > now || !this.delivers(ev, win)) continue;
      ev.delivered = true;
      due.push(ev.ev);
    }
    return due;
  }

  nextTime(win) {
    let next = Infinity;
    for (const ev of this.events) {
      if (ev.delivered || !this.delivers(ev, win)) continue;
      if (ev.t < next) next = ev.t;
    }
    return next;
  }

  // Synchronous: Node's green threads park, and the wall clock moves with
  // performance.now() (Node has no pause_hidden freeze here).
  wait(win, ms, gui) {
    const deadline = gui.host.now() + ms;
    for (;;) {
      gui.pump(win);
      if (win.events.length > 0) return 1;
      const now = gui.host.now();
      const next = this.nextTime(win);
      if (next === Infinity || next > deadline) {
        gui.host.sleepUntil(deadline);
        gui.pump(win);
        return win.events.length > 0 ? 1 : 0;
      }
      gui.host.sleepUntil(Math.max(now, next));
    }
  }
}
