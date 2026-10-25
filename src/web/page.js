// src/web/page.js — the browser platform and page for a Y web module.
//
// It reads the page config, loads NAME.wasm and an optional files.bin, builds
// memfs.js over store.js, and runs the same core.js host the Node CLI uses.
// The page is the application: a program that opens a gui window gets the
// whole viewport, and a program without one gets the console (stdin/stdout/
// stderr); [web] console = "show" or "hide" overrides that.  ?ytest=1 turns
// the page into a test device: on exit document.title and <pre id=ytest>
// become "YDONE status=<n> out=<base64 stdout>".
//
// No requestAnimationFrame: the scheduler is paced by the host's
// MessageChannel slice.  The site writer links this page and its imports into
// one inline module in index.html, so a site is index.html + NAME.wasm.

import { Host } from './core.js';
import { MemFs } from './memfs.js';
import { Store } from './store.js';
import { CanvasDisplay, installGui } from './gui.js';
import { installAudio } from './audio.js';
import { installWeb } from './web.js';

// -- the web.* host functions (W8/S10) ---------------------------------------
//
// The page is platform "browser": param reads location.search, eval runs the
// code as an expression first (so "1 + 1" is 2) and as a function body second
// (so "return 7" is 7), open_url is one window.open, and fetch is the page's
// own fetch: a status outside 2xx or a network error is none in Y.

function browserEval(js) {
  try {
    return new Function('return (' + js + '\n)')();
  } catch (e) {
    if (!(e && e.name === 'SyntaxError')) throw e;
    return new Function(js)();
  }
}

function browserParam(name) {
  try {
    return new URLSearchParams(location.search).get(name);
  } catch (e) {
    return null;
  }
}

function browserOpenUrl(url) {
  const w = window.open(url, '_blank');
  if (!w) return false;
  try { w.opener = null; } catch (e) { /* cross-origin */ }
  return true;
}

async function browserFetchBytes(url) {
  try {
    const res = await fetch(url, { cache: 'no-cache' });
    if (!res.ok) return null;
    return new Uint8Array(await res.arrayBuffer());
  } catch (e) {
    return null;
  }
}

const DEFAULTS = {
  title: '',
  id: '',
  start: 'auto',
  canvas: 'fixed',
  zoom: '1',
  smooth: 'false',
  console: 'auto',
  persist: 'home',
  files: [],
  args: [],
  url_args: 'true',
  env: {},
  stack: '8M',
  pause_hidden: 'true',
  single: 'false',
  template: '',
  module: '',
  module_base64: '',
  files_bin: '',
  files_base64: '',
  bundle: '',
  name: '',
  fuel: '',
};

// The feature check's 30-byte module: one void function whose body is
// "return_call 0" plus an empty custom section.  WebAssembly.validate compiles
// it, so a browser without the tail-call proposal rejects it before we fetch
// anything.
const RETURN_CALL_MODULE = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
  0x01, 0x04, 0x01, 0x60, 0x00, 0x00,             // type: () -> ()
  0x03, 0x02, 0x01, 0x00,                         // function 0 has type 0
  0x0a, 0x06, 0x01, 0x04, 0x00, 0x12, 0x00, 0x0b, // code: return_call 0
  0x00, 0x02, 0x00, 0x00,                         // empty custom section
]);

const I64_IDENTITY_MODULE = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  0x01, 0x06, 0x01, 0x60, 0x01, 0x7e, 0x01, 0x7e, // (i64) -> i64
  0x03, 0x02, 0x01, 0x00,
  0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,       // export "f"
  0x0a, 0x06, 0x01, 0x04, 0x00, 0x20, 0x00, 0x0b, // local.get 0
]);

const TAIL_CALL_ERROR =
  'This browser lacks WebAssembly tail calls (Chromium 112+, Firefox 121+, Safari 18.2+).';

function bytesOf(value) {
  return value instanceof Uint8Array ? value : new TextEncoder().encode(String(value));
}

function toBase64(bytes) {
  let binary = '';
  const chunk = 0x8000;
  for (let off = 0; off < bytes.length; off += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(off, Math.min(bytes.length, off + chunk)));
  }
  return btoa(binary);
}

function fromBase64(text) {
  const binary = atob(String(text));
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

function readConfig() {
  const el = document.getElementById('yweb-config');
  let cfg = {};
  if (el) {
    try {
      cfg = JSON.parse(el.textContent || '{}');
    } catch (e) {
      cfg = {};
    }
  }
  const out = { ...DEFAULTS };
  for (const key of Object.keys(DEFAULTS)) {
    if (cfg[key] !== undefined) out[key] = cfg[key];
  }
  out.args = Array.isArray(out.args) ? out.args.map(String) : out.args ? [String(out.args)] : [];
  out.files = Array.isArray(out.files) ? out.files.map(String) : out.files ? [String(out.files)] : [];
  out.env = out.env && typeof out.env === 'object' && !Array.isArray(out.env) ? out.env : {};
  for (const key of ['start', 'canvas', 'zoom', 'console', 'persist', 'url_args', 'pause_hidden', 'smooth', 'single']) {
    out[key] = String(out[key]);
  }
  return out;
}

class ConsoleStdin {
  constructor() {
    this.chunks = [];
    this.pos = 0;
    this.eof = false;
    this.waiters = [];
  }

  _wake() {
    const waiters = this.waiters;
    this.waiters = [];
    for (const wake of waiters) wake();
  }

  waitPromise() {
    if (this.hasData() || this.eof) return Promise.resolve();
    return new Promise((resolve) => this.waiters.push(resolve));
  }

  push(text) {
    if (text === null || text === undefined) return;
    this.chunks.push(bytesOf(text));
    this._wake();
  }

  close() {
    this.eof = true;
    this._wake();
  }

  hasData() {
    return this.pos < this._length();
  }

  _length() {
    let n = 0;
    for (const c of this.chunks) n += c.length;
    return n;
  }

  read(n) {
    if (!this.hasData()) return { block: { kind: 'stdin-console', stdin: this } };
    const out = new Uint8Array(Math.min(n, this._length() - this.pos));
    let off = 0;
    while (off < out.length && this.chunks.length > 0) {
      const first = this.chunks[0];
      const take = Math.min(first.length, out.length - off);
      out.set(first.subarray(0, take), off);
      off += take;
      if (take === first.length) this.chunks.shift();
      else this.chunks[0] = first.subarray(take);
    }
    return out;
  }
}

function checkFeatures() {
  try {
    if (typeof BigInt !== 'function') {
      return { ok: false, message: 'This browser lacks BigInt.\n' + TAIL_CALL_ERROR };
    }
    const okCall = WebAssembly.validate(RETURN_CALL_MODULE);
    if (!okCall) return { ok: false, message: TAIL_CALL_ERROR };
    // validate() may only parse on an older engine; constructing the module
    // proves the engine compiled the tail call.
    try {
      new WebAssembly.Module(RETURN_CALL_MODULE);
    } catch (e) {
      return { ok: false, message: TAIL_CALL_ERROR };
    }
    const mod = new WebAssembly.Module(I64_IDENTITY_MODULE);
    const inst = new WebAssembly.Instance(mod);
    if (inst.exports.f(1234567890123n) !== 1234567890123n) {
      return { ok: false, message: 'This browser does not integrate BigInt with WebAssembly.\n' + TAIL_CALL_ERROR };
    }
    return { ok: true, message: '' };
  } catch (e) {
    return { ok: false, message: TAIL_CALL_ERROR + (e && e.message ? '\n' + e.message : '') };
  }
}

async function boot() {
  const cfg = readConfig();
  const params = new URLSearchParams(location.search);
  const ytest = params.get('ytest') === '1';
  const perf = params.get('perf') === '1';
  const body = document.body;
  const placeholder = (value) => typeof value === 'string' && (value.includes('{{') || value.trim() === '');

  // Title and module can be substituted in the HTML or given by the driver in
  // the config JSON (S13's page contract).  ?module= is the test fallback.
  let moduleName = String(cfg.module || '');
  if (placeholder(moduleName)) moduleName = String(body.dataset.module || '');
  if (placeholder(moduleName)) moduleName = String(params.get('module') || '');
  const title = !placeholder(cfg.title)
    ? String(cfg.title)
    : (!placeholder(cfg.name) ? String(cfg.name) : (moduleName ? moduleName.replace(/\.wasm$/, '') : document.title));
  document.title = title;

  // URL overrides (S13).  ?arg= is accepted only when url_args is true.
  const urlArgs = cfg.url_args === 'true' || cfg.url_args === '1' ? params.getAll('arg') : [];
  if (params.get('zoom') !== null) cfg.zoom = params.get('zoom');
  if (params.get('console') !== null) cfg.console = params.get('console');
  if (params.get('fuel') !== null) cfg.fuel = params.get('fuel');
  const trace = params.get('trace') === '1';
  const pauseHidden = cfg.pause_hidden !== 'false';
  const persistHome = cfg.persist !== 'none';
  const storeId = String(cfg.id || title || 'default');

  const consoleOut = document.getElementById('console-out');
  const consolePanel = document.getElementById('console');
  const banner = document.getElementById('banner');
  const overlay = document.getElementById('start-overlay');
  const startButton = document.getElementById('start-button');
  const featureError = document.getElementById('feature-error');
  const statusLine = document.getElementById('status-line');
  let stdin = new ConsoleStdin();
  let sawGesture = false;
  let guiSeen = false;
  let consoleVisible = false;
  let consoleTimer = 0;

  // Feature check before anything is fetched (S13).
  const feature = checkFeatures();
  if (!feature.ok) {
    if (featureError) {
      featureError.hidden = false;
      featureError.textContent = feature.message;
    }
    if (overlay) overlay.hidden = true;
    if (statusLine) statusLine.textContent = 'unsupported browser';
    document.documentElement.dataset.yweb = 'feature-error';
    return;
  }
  document.documentElement.dataset.yweb = 'ready';

  // The canvas is the web gui's display.  It exists before
  // the first host so gui.open can size it and so applyZoom has a target.
  const canvasEl = document.getElementById('ycanvas');
  const stageEl = document.getElementById('stage');
  let canvasDisplay = null;
  if (canvasEl) {
    canvasDisplay = new CanvasDisplay({
      canvas: canvasEl,
      stage: stageEl,
      config: cfg,
      onOpen: guiOpened,
      onZoom: (n) => {
        document.documentElement.style.setProperty('--yzoom', String(n));
      },
    });
  }

  let outBytes = 0;
  let outTextBytes = [];
  let errTextBytes = [];
  let outDec = new TextDecoder();
  let errDec = new TextDecoder();
  let host = null;
  let store = null;
  let memfs = null;
  let running = false;
  let moduleBytes = null;
  let filesBytes = null;

  function appendConsole(text, cls) {
    if (!consoleOut || text === '') return;
    const span = document.createElement('span');
    if (cls) span.className = cls;
    span.textContent = text;
    consoleOut.appendChild(span);
    // Bound the DOM; the raw stdout stays in outChunks for ?ytest=.
    if (consoleOut.textContent.length > 800000) {
      consoleOut.textContent = consoleOut.textContent.slice(-400000);
    }
    consoleOut.scrollTop = consoleOut.scrollHeight;
  }

  function streamStdout(bytes) {
    const copy = Uint8Array.from(bytes);
    if (cfg.console === 'auto' && !guiSeen && !consoleVisible) showTextConsole();
    outBytes += copy.length;
    // ?ytest= has its own buffer; keep both for the panel and the title.
    if (outBytes <= 8 * 1024 * 1024) {
      outTextBytes.push(copy);
    }
    appendConsole(outDec.decode(copy, { stream: true }), null);
  }

  function streamStderr(bytes) {
    const copy = Uint8Array.from(bytes);
    if (cfg.console === 'auto' && !guiSeen && !consoleVisible) showTextConsole();
    if (errTextBytes.length < 1024 * 1024) errTextBytes.push(copy);
    const text = errDec.decode(copy, { stream: true });
    appendConsole(text, 'err');
    for (const line of text.split('\n')) if (line !== '') console.error('[ywerr] ' + line);
  }

  // stdin: the panel's input line, or ?stdin= in test mode.
  const stdinPrefill = params.get('stdin');
  function resetStdin() {
    stdin = new ConsoleStdin();
    if (stdinPrefill !== null) {
      stdin.push(stdinPrefill);
      stdin.close();
    }
  }
  resetStdin();

  function readStdin(n) {
    if (stdin.hasData()) return stdin.read(n);
    if (stdin.eof) return new Uint8Array(0);
    return { block: { kind: 'stdin-console', stdin } };
  }

  async function fetchOptional(name) {
    if (!name) return null;
    try {
      const res = await fetch(name, { cache: 'no-cache' });
      if (!res.ok) return null;
      return new Uint8Array(await res.arrayBuffer());
    } catch (e) {
      return null;
    }
  }

  async function loadInputs() {
    if (moduleBytes === null) {
      if (cfg.module_base64) {
        moduleBytes = fromBase64(cfg.module_base64);
      } else {
        if (placeholder(moduleName)) throw new Error('the page has no module name');
        const res = await fetch(moduleName, { cache: 'no-cache' });
        if (!res.ok) throw new Error('cannot load ' + moduleName + ' (' + res.status + ')');
        moduleBytes = new Uint8Array(await res.arrayBuffer());
      }
    }
    if (filesBytes === null) {
      if (cfg.files_base64) filesBytes = fromBase64(cfg.files_base64);
      else if (cfg.bundle) filesBytes = await fetchOptional(String(cfg.bundle));
      else if (cfg.files_bin) filesBytes = await fetchOptional(String(cfg.files_bin));
      else if (cfg.files && cfg.files.length > 0) filesBytes = await fetchOptional('files.bin');
    }
  }

  async function makeHost() {
    store = new Store({ id: storeId });
    if (persistHome) await store.open();
    let records = new Map();
    if (persistHome && store.available) records = await store.load();
    memfs = new MemFs({ files: filesBytes, records });
    if (persistHome) {
      store.attach(memfs);
      memfs.store = store;
    }
    if (persistHome && !store.available && banner) {
      banner.hidden = false;
      banner.textContent = 'Saves will not persist: IndexedDB is unavailable.';
    }
    const env = [
      'HOME=/home/web', 'USER=web', 'LOGNAME=web', 'PATH=/bin',
      'PWD=/app', 'LANG=C.UTF-8', 'TZ=UTC',
    ];
    for (const key of Object.keys(cfg.env)) env.push(key + '=' + String(cfg.env[key]));
    const fuelRaw = cfg.fuel === '' ? 1000000 : Number(cfg.fuel);
    const fuel = Number.isFinite(fuelRaw) && fuelRaw > 0 ? Math.floor(fuelRaw) : 1000000;
    const argv = [title || 'a.out', ...cfg.args.map(String), ...urlArgs];
    host = new Host(moduleBytes, {
      argv,
      env,
      cwd: '/app',
      fs: memfs,
      stdin: readStdin,
      stdout: streamStdout,
      stderr: streamStderr,
      fuel,
      trace,
    });
    if (perf) {
      host.sched.perf = true;
      globalThis.__ywebPerf = () => {
        const xs = host.sched.sliceMs.slice().sort((a, b) => a - b);
        if (xs.length === 0) return { n: 0, p50: 0, p95: 0, max: 0 };
        const q = (f) => xs[Math.min(xs.length - 1, Math.floor(f * xs.length))];
        return { n: xs.length, p50: q(0.5), p95: q(0.95), max: xs[xs.length - 1] };
      };
    }
    // W7/S12: the AudioContext is created lazily by the first audio.open; the
    // platform also owns the gesture hook, the mute gain and pause_hidden.
    host.audio = installAudio(host, { browser: true });
    if (sawGesture) host.audio.gesture();
    globalThis.__ywebAudio = () => (host && host.audio ? host.audio.stats() : null);
    // W8/S10: the nine web.* names over the page's own location, eval,
    // window.open and fetch.
    host.web = installWeb(host, {
      platform: 'browser',
      param: browserParam,
      eval: browserEval,
      log: (text) => console.log(text),
      openUrl: browserOpenUrl,
      fetchBytes: browserFetchBytes,
    });
    if (persistHome) host.vfs.store = store;
    if (canvasDisplay) {
      host.gui = installGui(host, canvasDisplay);
      canvasDisplay.bind(host.gui);
    }
    host.onGuiOpen = guiOpened;
    globalThis.__ywebHost = host;
    globalThis.__yweb = { host, store, memfs, status: null };
  }

  function applyZoom(value) {
    // The canvas display owns the effective zoom: "auto" is the largest
    // integer that fits the stage (or 1 in fit mode), and it sets the CSS size.
    let n = 1;
    if (canvasDisplay) n = canvasDisplay.setZoom(value);
    else {
      const zoom = String(value);
      n = zoom === 'auto' ? 1 : Math.max(1, Math.min(8, Number(zoom) || 1));
    }
    document.documentElement.style.setProperty('--yzoom', String(n));
    const canvas = document.getElementById('ycanvas');
    if (canvas) canvas.style.imageRendering = cfg.smooth === 'true' ? 'auto' : 'pixelated';
  }

  // A page has no shell: the application fills it.  The one piece of
  // furniture a non-gui program needs is its console.  "auto" shows it on the
  // first byte of output, or after a short grace period for a program that
  // only waits on stdin; a gui window cancels both and takes the page.
  function hideConsole() {
    consoleVisible = false;
    if (consolePanel) {
      consolePanel.hidden = true;
      consolePanel.classList.remove('overlay');
    }
    body.classList.remove('text-mode');
  }

  function showTextConsole() {
    if (cfg.console !== 'auto' || guiSeen || !consolePanel) return;
    consoleVisible = true;
    consolePanel.hidden = false;
    consolePanel.classList.remove('overlay');
    body.classList.add('text-mode');
  }

  function showOverlayConsole() {
    if (!consolePanel) return;
    consoleVisible = true;
    consolePanel.hidden = false;
    consolePanel.classList.add('overlay');
    body.classList.remove('text-mode');
  }

  function applyConsole(value) {
    if (!consolePanel) return;
    const mode = String(value);
    if (mode === 'hide') hideConsole();
    else if (mode === 'show') showOverlayConsole();
    else hideConsole();
  }

  // W6's gui.js calls this on the first gui.open: the canvas becomes visible,
  // and "auto" takes the console away now that the app has a window.
  function guiOpened() {
    const canvas = document.getElementById('ycanvas');
    if (canvas) canvas.classList.add('visible');
    if (consoleTimer) { clearTimeout(consoleTimer); consoleTimer = 0; }
    guiSeen = true;
    if (cfg.console !== 'show') hideConsole();
  }
  globalThis.__ywebGuiOpened = guiOpened;

  function showBanner(text, kind) {
    if (!banner) return;
    banner.hidden = false;
    banner.className = kind || '';
    banner.textContent = text;
    let again = document.getElementById('run-again');
    if (!again) {
      again = document.createElement('button');
      again.id = 'run-again';
      again.textContent = 'Run again';
      again.addEventListener('click', () => { restart(); });
      banner.appendChild(document.createTextNode(' '));
      banner.appendChild(again);
    }
  }

  async function finish(status) {
    running = false;
    if (consoleTimer) { clearTimeout(consoleTimer); consoleTimer = 0; }
    if (persistHome && store) {
      try { await store.flush(); } catch (e) { /* a closed private store */ }
    }
    const trapped = !!(host && host.trapped);
    const message = host && host.sched && host.sched.message ? host.sched.message : '';
    if (trapped || message) {
      const detail = message || (host && host.trapSignal ? 'signal ' + host.trapSignal : 'status ' + status);
      showBanner('Trap: ' + detail, 'trap');
    } else if (consoleVisible || ytest) {
      showBanner('Program exited (status ' + status + ')', 'exit');
    }
    if (statusLine) statusLine.textContent = 'status ' + status;
    document.documentElement.dataset.yweb = (trapped || message) ? 'trap' : 'exit';
    if (globalThis.__yweb) globalThis.__yweb.status = status;
    if (ytest) {
      const out = [];
      for (const b of outTextBytes) out.push(b);
      let total = 0;
      for (const b of out) total += b.length;
      const all = new Uint8Array(total);
      let off = 0;
      for (const b of out) { all.set(b, off); off += b.length; }
      let titleText = 'YDONE status=' + status + ' out=' + toBase64(all);
      if (perf && host && host.sched && host.sched.sliceMs.length > 0) {
        const xs = host.sched.sliceMs.slice().sort((a, b) => a - b);
        const q = (f) => xs[Math.min(xs.length - 1, Math.floor(f * xs.length))];
        const line = ' perf n=' + xs.length + ' p50=' + q(0.5).toFixed(3)
          + ' p95=' + q(0.95).toFixed(3) + ' max=' + xs[xs.length - 1].toFixed(3);
        titleText += line;
        let pp = document.getElementById('perf');
        if (!pp) {
          pp = document.createElement('pre');
          pp.id = 'perf';
          document.body.appendChild(pp);
        }
        pp.textContent = line;
      }
      document.title = titleText;
      let pre = document.getElementById('ytest');
      if (!pre) {
        pre = document.createElement('pre');
        pre.id = 'ytest';
        document.body.appendChild(pre);
      }
      pre.textContent = titleText;
      document.documentElement.dataset.yweb = 'done';
      globalThis.__ywebDone = { status, out: toBase64(all) };
    }
  }

  async function start() {
    if (running) return;
    if (overlay) overlay.hidden = true;
    if (banner) banner.hidden = true;
    if (featureError) featureError.hidden = true;
    running = true;
    appendConsole('', null);
    if (statusLine) statusLine.textContent = 'running';
    try {
      await loadInputs();
      applyConsole(cfg.console);
      await makeHost();
      if (cfg.console === 'auto') {
        consoleTimer = setTimeout(() => { if (!guiSeen) showTextConsole(); }, 300);
      };
      // The click is the gesture audio needs; W6's canvas takes focus too.
      const canvas = document.getElementById('ycanvas');
      if (canvas && typeof canvas.focus === 'function') { try { canvas.focus(); } catch (e) {} }
      // Audio's gesture hook is the capture listener below: only a real
      // pointerdown/keydown resumes the context, not an automatic start.
      document.documentElement.dataset.yweb = 'running';
      const status = await host.runAsync();
      await finish(status);
    } catch (e) {
      running = false;
      const message = e && e.message ? e.message : String(e);
      if (statusLine) statusLine.textContent = 'error';
      showBanner('Error: ' + message, 'trap');
      document.documentElement.dataset.yweb = 'error';
      if (ytest) {
        const titleText = 'YDONE status=134 out=';
        document.title = titleText;
        let pre = document.getElementById('ytest');
        if (!pre) { pre = document.createElement('pre'); pre.id = 'ytest'; document.body.appendChild(pre); }
        pre.textContent = titleText;
        globalThis.__ywebDone = { status: 134, out: '' };
      }
    }
  }

  async function restart() {
    if (running) return;
    // A new Store + MemFs reloads /home/web; moduleBytes stay cached.
    outBytes = 0;
    outTextBytes = [];
    errTextBytes = [];
    outDec = new TextDecoder();
    errDec = new TextDecoder();
    resetStdin();
    if (consoleOut) consoleOut.textContent = '';
    if (banner) banner.hidden = true;
    await start();
  }

  const stdinForm = document.getElementById('stdin-form');
  const stdinLine = document.getElementById('stdin-line');
  if (stdinForm) {
    stdinForm.addEventListener('submit', (ev) => {
      ev.preventDefault();
      if (!stdinLine) return;
      stdin.push(stdinLine.value + '\n');
      stdinLine.value = '';
      if (host) host.notifyFd();
    });
  }
  const eofButton = document.getElementById('stdin-eof');
  if (eofButton) eofButton.addEventListener('click', () => {
    stdin.close();
    if (host) host.notifyFd();
  });

  // W7/S12: the first pointerdown or keydown anywhere resumes the AudioContext
  // and drops any queue beyond 100 ms.  Capture runs before the canvas's own
  // handlers, so the resume is requested before audio starts piling up.
  const noteGesture = () => {
    sawGesture = true;
    if (host && host.audio) host.audio.gesture();
  };
  if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
    window.addEventListener('pointerdown', noteGesture, true);
    window.addEventListener('keydown', noteGesture, true);
  }

  // pause_hidden: freeze CLOCK_MONOTONIC and the scheduler, suspend audio, and
  // flush /home/web before the tab goes away.  The last part runs even when
  // pause_hidden is false.
  document.addEventListener('visibilitychange', () => {
    const hidden = document.visibilityState === 'hidden';
    if (pauseHidden && host) host.setHidden(hidden);
    if (hidden && persistHome && store) store.flush().catch(() => {});
  });
  globalThis.__ywebSetHidden = (hidden) => {
    if (pauseHidden && host) host.setHidden(!!hidden);
  };

  applyZoom(cfg.zoom);
  applyConsole(cfg.console);

  const wantClick = cfg.start === 'click' && !ytest;
  if (wantClick && overlay) {
    overlay.hidden = false;
    if (startButton) startButton.addEventListener('click', () => { start(); });
  } else {
    await start();
  }
}

boot().catch((e) => {
  const message = e && e.message ? e.message : String(e);
  const err = document.getElementById('feature-error');
  if (err) { err.hidden = false; err.textContent = 'Error: ' + message; }
  document.documentElement.dataset.yweb = 'error';
});
