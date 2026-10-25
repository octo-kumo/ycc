// src/web/test/browser.test.mjs — the browser host checks W5 asks for.
//
// Run: node src/web/test/browser.test.mjs
//
// It builds a site with the local compiler, serves it over HTTP, launches the
// Playwright Chromium in headless mode (or $WEB_BROWSER) and drives it through
// the DevTools protocol: ?ytest=1 output, stdin, /home/web persistence across
// two navigations in one profile, pause_hidden, the start overlay and the
// feature-check message.  No Playwright package is needed.

import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '../../..');
const FIXTURES = path.join(HERE, 'fixtures');
const CHROME = process.env.WEB_BROWSER ||
  path.join(process.env.HOME || '', '.cache/ms-playwright/chromium-1248/chrome-linux64/chrome');

const results = [];
function check(name, condition, detail) {
  results.push({ name, ok: !!condition, detail: detail || '' });
  console.log((condition ? 'ok - ' : 'NOT OK - ') + name + (condition || !detail ? '' : ': ' + detail));
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// The page is generated: the compiler inlines the host and stylesheet into
// one index.html.  Build one base page, then rewrite its config per scenario.
function buildBaseSite(site) {
  const ycc = process.env.YCC || path.join(ROOT, 'ycc');
  execFileSync(ycc, ['--target=web', '--web=title=Base', '--web-page', '-o', site,
    path.join(FIXTURES, 'w100_console.y')], { stdio: 'pipe', cwd: ROOT });
  fs.copyFileSync(path.join(site, 'index.html'), path.join(site, 'index.base.html'));
}

function writePage(site, cfg, title) {
  let html = fs.readFileSync(path.join(site, 'index.base.html'), 'utf8');
  html = html.replace(/<script type="application\/json" id="yweb-config">[\s\S]*?<\/script>/,
    '<script type="application/json" id="yweb-config">' + JSON.stringify(cfg) + '</script>');
  html = html.replace(/<title>[^<]*<\/title>/, '<title>' + title + '</title>');
  fs.writeFileSync(path.join(site, 'index.html'), html);
}

function makeFilesBin(entries) {
  const header = Buffer.from(String.fromCharCode(89,87,70,83,49,10), 'latin1');
  const parts = [header];
  const count = Buffer.alloc(4);
  count.writeUInt32LE(entries.length, 0);
  parts.push(count);
  for (const ent of entries) {
    const pathBytes = Buffer.from(ent.path, 'utf8');
    const data = Buffer.isBuffer(ent.data) ? ent.data : Buffer.from(ent.data, 'utf8');
    const head = Buffer.alloc(4 + pathBytes.length + 4 + 8);
    head.writeUInt32LE(pathBytes.length, 0);
    pathBytes.copy(head, 4);
    head.writeUInt32LE(ent.mode === undefined ? 0o100644 : ent.mode, 4 + pathBytes.length);
    head.writeBigUInt64LE(BigInt(data.length), 4 + pathBytes.length + 4);
    parts.push(head, data);
  }
  return Buffer.concat(parts);
}

function buildModule(fixture, out, extra = []) {
  const ycc = process.env.YCC || path.join(ROOT, 'ycc');
  execFileSync(ycc, ['--target=web', ...extra, path.join(FIXTURES, fixture), '-o', out], {
    stdio: 'pipe',
    cwd: ROOT,
  });
}

function makeSite(site, modules, optional = {}) {
  fs.mkdirSync(site, { recursive: true });
  buildBaseSite(site);
  for (const [name, fixture] of Object.entries(modules)) buildModule(fixture, path.join(site, name));
  // A fixture whose half of the compiler may not be in this std pack yet is
  // {}: name -> {fixture, probe}.  The probe is a literal only that half's
  // unit contains ("gui.open" for W6's gui.web.y, "web.platform" for W8's
  // std/web), so the checks still run on a compiler that lacks it.
  const why = [];
  for (const [name, spec] of Object.entries(optional)) {
    const fixture = typeof spec === 'string' ? spec : spec.fixture;
    const probe = typeof spec === 'string' ? 'gui.open' : (spec.probe || '');
    const out = path.join(site, name);
    try {
      buildModule(fixture, out);
      const bytes = fs.readFileSync(out);
      if (probe !== '' && !bytes.includes(Buffer.from(probe))) {
        fs.rmSync(out, { force: true });
        why.push(fixture + ': the compiler has no ' + probe + ' in its std pack yet');
      }
    } catch (e) {
      const err = (e && e.stderr ? String(e.stderr) : '') || (e && e.message ? e.message : String(e));
      why.push(fixture + ': ' + err.trim().split('\n').slice(0, 2).join(' '));
    }
  }
  return why.join('; ');
}

function serve(site) {
  const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.wasm': 'application/wasm',
    '.css': 'text/css', '.json': 'application/json', '.bin': 'application/octet-stream' };
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    const rel = decodeURIComponent(url.pathname).replace(/^\/+/, '') || 'index.html';
    const file = path.join(site, rel);
    if (!file.startsWith(site) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
      res.writeHead(404); res.end('not found'); return;
    }
    res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port })));
}

class Cdp {
  constructor(child, ws) {
    this.child = child;
    this.ws = ws;
    this.nextId = 1;
    this.pending = new Map();
    ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) p.reject(new Error(JSON.stringify(msg.error)));
        else p.resolve(msg.result);
      }
    };
  }

  call(method, params = {}, sessionId) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }));
    });
  }

  async open() {
    const target = await this.call('Target.createTarget', { url: 'about:blank' });
    const attached = await this.call('Target.attachToTarget', { targetId: target.targetId, flatten: true });
    this.session = attached.sessionId;
    await this.call('Runtime.enable', {}, this.session);
    await this.call('Page.enable', {}, this.session);
    return this.session;
  }

  async navigate(url) {
    await this.call('Page.navigate', { url }, this.session);
  }

  async eval(expression) {
    const r = await this.call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, this.session);
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text || 'evaluate failed');
    return r.result.value;
  }

  async state() {
    return this.eval('JSON.parse(JSON.stringify({title:document.title,state:document.documentElement.dataset.yweb||"",status:document.getElementById("status-line")?.textContent||"",err:document.getElementById("feature-error")?.textContent||"",pre:document.getElementById("ytest")?.textContent||"",panel:document.getElementById("console-out")?.textContent||"",banner:document.getElementById("banner")?.textContent||""}))');
  }

  // The canvas's own bytes: the w110 checksum is computed exactly like gui's
  // checksum_of (FNV-1a over 0xRRGGBB, ignoring alpha), plus corner pixels and
  // the CSS scale.
  async canvasInfo() {
    return this.eval('(function(){' +
      'var c=document.getElementById("ycanvas");' +
      'var ctx=c.getContext("2d");' +
      'var d=ctx.getImageData(0,0,c.width,c.height).data;' +
      'var h=2166136261; var alpha=255;' +
      'for (var i=0;i<d.length;i+=4){' +
      '  var v=(d[i]<<16)|(d[i+1]<<8)|d[i+2];' +
      '  h=Math.imul((h^v)>>>0,16777619)>>>0;' +
      '  if(d[i+3]<alpha) alpha=d[i+3];' +
      '}' +
      'var px=function(x,y){var o=(y*c.width+x)*4;return [d[o],d[o+1],d[o+2],d[o+3]];};' +
      'var r=c.getBoundingClientRect();' +
      'var s=document.getElementById("stage");' +
      'return {w:c.width,h:c.height,cssW:r.width,cssH:r.height,' +
      '  stageW:s?s.clientWidth:0,stageH:s?s.clientHeight:0,' +
      '  rendering:getComputedStyle(c).imageRendering,checksum:h,alpha:alpha,' +
      '  p00:px(0,0),pr:px(c.width-1,0),pb:px(0,c.height-1),pbr:px(c.width-1,c.height-1)};' +
      '})()');
  }

  // The w111 script: the same keys, clicks, wheel and close that ytest gui
  // plays against Xvfb, dispatched as real DOM events on the canvas.  The
  // prevent-list probes come after pagehide, so their events queue behind
  // EV_CLOSE and cannot disturb the echoed sequence.
  async dispatchInput() {
    return this.eval('(function(){' +
      'var c=document.getElementById("ycanvas");' +
      'c.style.border="0";' +
      'var r=c.getBoundingClientRect();' +
      'function key(code,k,opt){' +
      '  opt=opt||{};' +
      '  var o={code:code,key:k,shiftKey:!!opt.shiftKey,ctrlKey:!!opt.ctrlKey,' +
      '    altKey:!!opt.altKey,metaKey:!!opt.metaKey,bubbles:true,cancelable:true};' +
      '  var ok=c.dispatchEvent(new KeyboardEvent("keydown",o));' +
      '  c.dispatchEvent(new KeyboardEvent("keyup",o));' +
      '  return ok;' +
      '}' +
      'function at(x,y){var rr=c.getBoundingClientRect();' +
      '  return {clientX:Math.ceil(rr.left)+x,clientY:Math.ceil(rr.top)+y};}' +
      'function ptr(type,button,buttons){' +
      '  var p=at(40,50);' +
      '  return c.dispatchEvent(new PointerEvent(type,{pointerId:1,pointerType:"mouse",' +
      '    isPrimary:true,button:button,buttons:buttons,clientX:p.clientX,clientY:p.clientY,' +
      '    bubbles:true,cancelable:true}));' +
      '}' +
      'function wheel(dy){' +
      '  var p=at(40,50);' +
      '  return c.dispatchEvent(new WheelEvent("wheel",{deltaY:dy,deltaMode:0,' +
      '    clientX:p.clientX,clientY:p.clientY,bubbles:true,cancelable:true}));' +
      '}' +
      'var res={};' +
      'res.plainA=key("KeyA","a");' +
      'key("ShiftLeft","Shift",{shiftKey:true});' +
      'key("KeyB","B",{shiftKey:true});' +
      'key("ControlLeft","Control",{ctrlKey:true});' +
      'res.ctrlC=key("KeyC","c",{ctrlKey:true});' +
      'res.arrow=key("ArrowLeft","ArrowLeft");' +
      'key("Enter","Enter");' +
      'key("Escape","Escape");' +
      'res.backspace=key("Backspace","Backspace");' +
      'ptr("pointerdown",0,1); ptr("pointerup",0,0);' +
      'ptr("pointerdown",2,2); ptr("pointerup",2,0);' +
      'wheel(-100); wheel(100);' +
      'var cm=new MouseEvent("contextmenu",{bubbles:true,cancelable:true});' +
      'res.contextMenu=c.dispatchEvent(cm);' +
      'window.dispatchEvent(new Event("pagehide"));' +
      'res.space=key("Space"," ");' +
      'res.tab=key("Tab","Tab");' +
      'res.f1=key("F1","F1");' +
      'return res;' +
      '})()');
  }

  // A navigation tears down the execution context; evaluating during that
  // window throws "Uncaught".  Both waits poll across it instead of failing.
  async stateQuiet() {
    try {
      return await this.state();
    } catch (e) {
      return null;
    }
  }

  async waitDone(timeoutMs = 30000) {
    const deadline = Date.now() + timeoutMs;
    let s = null;
    while (Date.now() < deadline) {
      s = await this.stateQuiet();
      if (s && (s.pre || s.state === 'error' || s.state === 'done')) return s;
      await sleep(50);
    }
    return (s || (await this.stateQuiet())) || await this.state();
  }

  async waitPanel(text, timeoutMs = 15000) {
    const deadline = Date.now() + timeoutMs;
    let s = null;
    while (Date.now() < deadline) {
      s = await this.stateQuiet();
      if (s && s.panel.includes(text)) return s;
      await sleep(25);
    }
    return (s || (await this.stateQuiet())) || await this.state();
  }
}

async function launchChrome(port, profile) {
  const child = spawn(CHROME, [
    '--headless=new', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage',
    '--no-first-run', '--no-default-browser-check',
    '--remote-debugging-port=' + port, '--user-data-dir=' + profile,
    '--autoplay-policy=no-user-gesture-required', '--disable-popup-blocking', 'about:blank',
  ], { stdio: ['ignore', 'ignore', 'ignore'] });
  let version = null;
  for (let i = 0; i < 200; i++) {
    try {
      version = await (await fetch('http://127.0.0.1:' + port + '/json/version')).json();
      break;
    } catch (e) {
      await sleep(50);
    }
  }
  if (!version) {
    child.kill();
    throw new Error('Chromium did not start at ' + CHROME);
  }
  const ws = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  return { child, cdp: new Cdp(child, ws) };
}

function decodeOut(state) {
  const m = /^YDONE status=(\d+) out=(.*)$/.exec(state.pre || '');
  if (!m) return null;
  return { status: Number(m[1]), out: Buffer.from(m[2], 'base64').toString('utf8') };
}


// -- Firefox: WebDriver BiDi, no extra package ------------------------------
class Bidi {
  constructor(ws) {
    this.ws = ws;
    this.nextId = 1;
    this.pending = new Map();
    ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.type === 'error') p.reject(new Error(msg.message || JSON.stringify(msg)));
        else p.resolve(msg.result);
      }
    };
  }
  call(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  async eval(expression, context) {
    const r = await this.call('script.evaluate', {
      expression, target: { context }, awaitPromise: true, resultOwnership: 'none',
    });
    if (r.type === 'exception') throw new Error(r.exceptionDetails?.text || 'BiDi evaluate failed');
    return r.result ? r.result.value : undefined;
  }
}

async function connectBidi(port) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    try {
      const ws = new WebSocket('ws://127.0.0.1:' + port + '/session');
      await new Promise((resolve, reject) => {
        ws.onopen = resolve;
        ws.onerror = () => reject(new Error('websocket refused'));
      });
      const bidi = new Bidi(ws);
      await bidi.call('session.new', { capabilities: {} });
      return { bidi, ws };
    } catch (e) {
      await sleep(100);
    }
  }
  throw new Error('Firefox remote agent did not accept a BiDi session');
}

async function runFirefox(site, base, writeScenario) {
  const firefox = process.env.FIREFOX || '/usr/bin/firefox';
  if (!fs.existsSync(firefox)) {
    console.log('skip firefox: no browser at ' + firefox);
    return;
  }
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'yweb-ffhome-'));
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'yweb-ffprof-'));
  const port = 9800 + Math.floor(Math.random() * 100);
  const child = spawn(firefox, ['--headless', '--no-remote', '--profile', profile,
    '--remote-debugging-port', String(port), 'about:blank'], {
    stdio: ['ignore', 'ignore', 'ignore'],
    env: { ...process.env, HOME: home, MOZ_HEADLESS: '1' },
  });
  try {
    const { bidi, ws } = await connectBidi(port);
    const created = await bidi.call('browsingContext.create', { type: 'tab' });
    const context = created.context;
    const wait = async (expression) => {
      const deadline = Date.now() + 30000;
      while (Date.now() < deadline) {
        const value = await bidi.eval(expression, context);
        if (value) return value;
        await sleep(50);
      }
      return bidi.eval(expression, context);
    };

    writeScenario('w001.wasm', 'firefox console');
    await bidi.call('browsingContext.navigate', { context, url: base + '?ytest=1&stdin=hello%0A', wait: 'complete' });
    let pre = await wait('document.getElementById("ytest")?.textContent || ""');
    let done = /^YDONE status=(\d+) out=(.*)$/.exec(pre);
    check('Firefox: ?ytest=1 writes YDONE', done !== null, JSON.stringify(pre));
    check('Firefox: stdin reaches the program',
      done && Buffer.from(done[2], 'base64').toString('utf8').includes('out before\nhello\n'),
      JSON.stringify(done && Buffer.from(done[2], 'base64').toString('utf8')));

    writeScenario('persist.wasm', 'firefox persist');
    await bidi.call('browsingContext.navigate', { context, url: base + '?ytest=1&arg=write', wait: 'complete' });
    pre = await wait('document.getElementById("ytest")?.textContent || ""');
    await bidi.call('browsingContext.navigate', { context, url: base + '?ytest=1&arg=read', wait: 'complete' });
    pre = await wait('document.getElementById("ytest")?.textContent || ""');
    done = /^YDONE status=(\d+) out=(.*)$/.exec(pre);
    check('Firefox: IndexedDB round trip', done && Buffer.from(done[2], 'base64').toString('utf8') === 'persisted\n',
      JSON.stringify(done && Buffer.from(done[2], 'base64').toString('utf8')));

    writeScenario('hidden.wasm', 'firefox hidden');
    await bidi.call('browsingContext.navigate', { context, url: base + '?ytest=1', wait: 'complete' });
    await wait('document.getElementById("console-out")?.textContent.includes("A ") ? "A" : ""');
    const wallStart = Date.now();
    await bidi.eval('__ywebSetHidden(true)', context);
    await sleep(700);
    await bidi.eval('__ywebSetHidden(false)', context);
    pre = await wait('document.getElementById("ytest")?.textContent || ""');
    const wall = Date.now() - wallStart;
    done = /^YDONE status=(\d+) out=(.*)$/.exec(pre);
    let duration = null;
    if (done) {
      const text = Buffer.from(done[2], 'base64').toString('utf8');
      const m = /D (\d+)/.exec(text);
      if (m) duration = Number(m[1]);
    }
    check('Firefox: pause_hidden freezes CLOCK_MONOTONIC',
      duration !== null && duration > 1000000 && duration < 1600000,
      'monotonic sleep ' + duration + ' us over ' + wall + ' ms');
    try { await bidi.call('session.end'); } catch (e) {}
    ws.close();
  } finally {
    try { child.kill(); } catch (e) {}
    try { fs.rmSync(home, { recursive: true, force: true }); } catch (e) {}
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch (e) {}
  }
}

async function main() {
  if (!fs.existsSync(CHROME)) {
    console.log('skip: no browser at ' + CHROME + ' (set WEB_BROWSER)');
    return 0;
  }
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'yweb-browser-'));
  const site = path.join(tmp, 'site');
  const profile = path.join(tmp, 'profile');
  const guiWhy = makeSite(site, {
    'w001.wasm': 'w100_console.y',
    'persist.wasm': 'w101_persist.y',
    'hidden.wasm': 'w103_pause_hidden.y',
    'app.wasm': 'w104_app.y',
  }, {
    'canvas.wasm': { fixture: 'w110_canvas.y', probe: 'gui.open' },
    'input.wasm': { fixture: 'w111_input.y', probe: 'gui.open' },
    'resize.wasm': { fixture: 'w112_resize.y', probe: 'gui.open' },
  });
  // W8's std/web is its own half of the compiler, skipped on its own too.
  const webWhy = makeSite(site, {}, {
    'web.wasm': { fixture: 'w113_fetch.y', probe: 'web.platform' },
  });
  fs.writeFileSync(path.join(site, 'w113_data.txt'), 'web fetch in a page' + String.fromCharCode(10));
  // W7's audio fixture allocates per write, so it is compiled with the
  // explicit collector opt-in the other audio fixtures use.
  buildModule('w112_audio.y', path.join(site, 'audio.wasm'), ['--gc=auto']);
  fs.writeFileSync(path.join(site, 'files.bin'), makeFilesBin([
    { path: 'hello.txt', data: 'hello app' + String.fromCharCode(10) },
  ]));
  const cfg = (module, extra) => ({ module, title: module, id: 'browser-test', start: 'auto', persist: 'home', console: 'show', ...extra });
  writePage(site, cfg('w001.wasm'), 'console test');
  // The page template's config is per site; scenarios that need a different
  // module rewrite index.html before navigating.
  const writeScenario = (module, title, extra) => writePage(site, cfg(module, extra), title);

  const { server, port } = await serve(site);
  const base = 'http://127.0.0.1:' + port + '/index.html';
  const dbgPort = 9600 + Math.floor(Math.random() * 300);
  const { child, cdp } = await launchChrome(dbgPort, profile);
  await cdp.open();
  try {
    // 1. ?ytest=1, console output, stdin and stderr.
    writeScenario('w001.wasm', 'console test');
    await cdp.navigate(base + '?ytest=1&stdin=hello%0A');
    let s = await cdp.waitDone();
    let done = decodeOut(s);
    check('ytest title/pre are written', done !== null, s.pre || s.state);
    check('stdout reaches the console and the test output', done && done.out.includes('out before\nhello\n'), JSON.stringify(done && done.out));
    check('the console panel shows stdout', s.panel.includes('out before') && s.panel.includes('hello'), JSON.stringify(s.panel.slice(0, 120)));
    check('stderr reaches the panel with the error class',
      (await cdp.eval('document.querySelectorAll("#console-out .err").length')) > 0, '');
    check('the process exited 0', done && done.status === 0, JSON.stringify(done));
    check('the exit banner names the status', /exited \(status 0\)/.test(s.banner), JSON.stringify(s.banner));

    // 1b. ?perf=1 adds the scheduler's slice percentiles to the test output.
    await cdp.navigate(base + '?ytest=1&perf=1&stdin=hello%0A');
    s = await cdp.waitDone();
    check('?perf=1 reports slice p50/p95', /perf n=\d+ p50=[\d.]+ p95=[\d.]+ max=[\d.]+/.test(s.pre), s.pre);

    // 2. /home/web survives two navigations in the same profile.
    writeScenario('persist.wasm', 'persist test');
    await cdp.navigate(base + '?ytest=1&arg=write');
    s = await cdp.waitDone();
    done = decodeOut(s);
    check('persistence: write run exits 0', done && done.status === 0 && done.out.includes('write true'), JSON.stringify(done));
    await cdp.navigate(base + '?ytest=1&arg=read');
    s = await cdp.waitDone();
    done = decodeOut(s);
    check('persistence: the second run reads the file', done && done.out === 'persisted\n', JSON.stringify(done));

    // 3. pause_hidden freezes CLOCK_MONOTONIC (and the scheduler).
    writeScenario('hidden.wasm', 'pause_hidden');
    await cdp.navigate(base + '?ytest=1');
    s = await cdp.waitPanel('A ', 15000);
    check('pause_hidden: the program starts', s.panel.includes('A '), JSON.stringify(s.panel.slice(0, 120)));
    const wallStart = Date.now();
    await cdp.eval('__ywebSetHidden(true)');
    await sleep(700);
    await cdp.eval('__ywebSetHidden(false)');
    s = await cdp.waitDone(20000);
    const wall = Date.now() - wallStart;
    done = decodeOut(s);
    let duration = null;
    if (done) {
      const m = /D (\d+)/.exec(done.out);
      if (m) duration = Number(m[1]);
    }
    check('pause_hidden: the run finishes', done !== null, s.pre || s.state);
    check('pause_hidden: CLOCK_MONOTONIC excludes the hidden 700 ms',
      duration !== null && duration > 1000000 && duration < 1600000,
      'monotonic sleep ' + duration + ' us over ' + wall + ' ms of wall time');
    check('pause_hidden: the page really was paused for most of a second', wall > 1500, String(wall));

    // 4. start=click shows the overlay and the click starts the program.
    writeScenario('w001.wasm', 'click test', { start: 'click' });
    await cdp.navigate(base);
    let overlay = false;
    for (let i = 0; i < 100; i++) {
      await sleep(50);
      overlay = await cdp.eval('document.readyState === "complete" && !document.getElementById("start-overlay").hidden');
      if (overlay) break;
    }
    check('start=click shows the overlay', overlay === true, JSON.stringify(await cdp.state()));
    await cdp.eval('document.getElementById("start-button").click()');
    s = await cdp.waitPanel('out before', 15000);
    check('the start click runs the program', s.panel.includes('out before'), JSON.stringify(s.panel.slice(0, 120)));


    // 5. /app is the files.bin bundle; /proc and /dev are synthetic.
    writeScenario('app.wasm', 'app test', { bundle: 'files.bin', url_args: true, smooth: false, pause_hidden: true });
    await cdp.navigate(base + '?ytest=1');
    s = await cdp.waitDone();
    done = decodeOut(s);
    check('/app reads files.bin', done && done.out.includes('hello app' + String.fromCharCode(10)), JSON.stringify(done));
    check('/proc/self/status and /dev are mounted',
      done && done.out.includes('proc ok') && done.out.includes('devnull true') && done.out.includes('cwd /app'),
      JSON.stringify(done && done.out));

    // 6. ?console and ?zoom override the page settings.
    writeScenario('w001.wasm', 'overrides');
    await cdp.navigate(base + '?ytest=1&console=hide&zoom=2');
    s = await cdp.waitDone();
    check('?console=hide takes the console away',
      (await cdp.eval('document.getElementById("console").hidden')) === true, '');
    check('?zoom=2 sets the zoom variable',
      (await cdp.eval('getComputedStyle(document.documentElement).getPropertyValue("--yzoom").trim()')) === '2', '');

    // 7. the feature check's message when tail calls are unavailable.
    writeScenario('w001.wasm', 'feature test');
    const target = await cdp.call('Target.createTarget', { url: 'about:blank' });
    const attached = await cdp.call('Target.attachToTarget', { targetId: target.targetId, flatten: true });
    const sid = attached.sessionId;
    await cdp.call('Runtime.enable', {}, sid);
    await cdp.call('Page.enable', {}, sid);
    await cdp.call('Page.addScriptToEvaluateOnNewDocument', {
      source: 'WebAssembly.validate = function () { return false; };',
    }, sid);
    await cdp.call('Page.navigate', { url: base + '?ytest=1' }, sid);
    let feature = null;
    for (let i = 0; i < 200; i++) {
      await sleep(50);
      const r = await cdp.call('Runtime.evaluate', {
        expression: 'document.getElementById("feature-error")?.textContent || ""',
        returnByValue: true,
      }, sid);
      if (r.result.value) { feature = r.result.value; break; }
    }
    check('the feature check names the tail-call requirement',
      feature && feature.includes('lacks WebAssembly tail calls'), JSON.stringify(feature));

    // 8. w110_canvas: the presented bytes reach the canvas with B and R
    // swapped and alpha forced, and read_back hashes the same frame.
    if (guiWhy) {
      console.log('skip gui: ' + guiWhy);
    } else {
      const rgb = (p) => p.slice(0, 3).join(',');
      writeScenario('canvas.wasm', 'canvas test', { canvas: 'fixed', zoom: '1', smooth: 'false' });
      await cdp.navigate(base + '?ytest=1');
      s = await cdp.waitDone(30000);
      done = decodeOut(s);
      let info = await cdp.canvasInfo();
      let out = done ? done.out : '';
      let sz = /^size ([0-9]+) ([0-9]+)$/m.exec(out);
      let cs = /^checksum ([0-9]+)$/m.exec(out);
      check("w110_canvas: the canvas matches the program's read_back checksum",
        done && done.status === 0 && sz && cs && info.w === Number(sz[1]) && info.h === Number(sz[2])
          && info.checksum === Number(cs[1]),
        JSON.stringify({ done: done && done.status, size: sz && sz.slice(1), canvas: [info.w, info.h],
          programSum: cs && cs[1], canvasSum: info.checksum, out: out.slice(0, 300) }));
      check('w110_canvas: every presented pixel is opaque', info.alpha === 255, 'min alpha ' + info.alpha);
      check('w110_canvas: red, green and blue reach the right channels',
        rgb(info.p00) === '255,0,0' && rgb(info.pr) === '0,255,0'
          && rgb(info.pb) === '0,0,255' && rgb(info.pbr) === '255,255,255',
        JSON.stringify({ p00: info.p00, pr: info.pr, pb: info.pb, pbr: info.pbr }));
      check('w110_canvas: the program reports verify_present', /^verify true$/m.test(out), out.slice(0, 200));

      // Fixed mode: the backing store stays the window size and the CSS size
      // is window * zoom, still pixelated.
      writeScenario('canvas.wasm', 'canvas zoom', { canvas: 'fixed', zoom: '2', smooth: 'false' });
      await cdp.navigate(base + '?ytest=1');
      s = await cdp.waitDone(30000);
      done = decodeOut(s);
      info = await cdp.canvasInfo();
      out = done ? done.out : '';
      cs = /^checksum ([0-9]+)$/m.exec(out);
      check('w110_canvas: fixed zoom scales the CSS size',
        done && done.status === 0 && info.w === 96 && info.h === 64
          && Math.round(info.cssW) === 192 && Math.round(info.cssH) === 128
          && info.rendering === 'pixelated' && cs && info.checksum === Number(cs[1]),
        JSON.stringify({ canvas: [info.w, info.h], css: [info.cssW, info.cssH], rendering: info.rendering }));

      // Fit mode: the backing store is the stage over the zoom, and smooth
      // replaces pixelated scaling.
      writeScenario('canvas.wasm', 'canvas fit', { canvas: 'fit', zoom: '1', smooth: 'true' });
      await cdp.navigate(base + '?ytest=1');
      s = await cdp.waitDone(30000);
      done = decodeOut(s);
      info = await cdp.canvasInfo();
      out = done ? done.out : '';
      sz = /^size ([0-9]+) ([0-9]+)$/m.exec(out);
      cs = /^checksum ([0-9]+)$/m.exec(out);
      check('w110_canvas: fit mode sizes the canvas from the stage',
        done && done.status === 0 && sz && info.w === Number(sz[1]) && info.h === Number(sz[2])
          && Math.abs(info.cssW - info.stageW) <= 2 && Math.abs(info.cssH - info.stageH) <= 2
          && info.rendering === 'auto' && cs && info.checksum === Number(cs[1]),
        JSON.stringify({ canvas: [info.w, info.h], stage: [info.stageW, info.stageH],
          css: [info.cssW, info.cssH], rendering: info.rendering, size: sz && sz.slice(1),
          programSum: cs && cs[1], canvasSum: info.checksum, out: out.slice(0, 200) }));

      // 9. w111_input: the same scripted input as test/gui/x11_input.y.
      writeScenario('input.wasm', 'input test', { canvas: 'fixed', zoom: '1', smooth: 'false' });
      await cdp.navigate(base + '?ytest=1');
      s = await cdp.waitPanel('ready', 15000);
      check('w111_input: the program opened its canvas window', s.panel.includes('ready'),
        JSON.stringify(s.panel.slice(0, 160)));
      const flags = await cdp.dispatchInput();
      s = await cdp.waitDone(30000);
      done = decodeOut(s);
      const golden = fs.readFileSync(path.join(FIXTURES, 'w111_input.expected'), 'utf8');
      check('w111_input: synthetic events match the native golden',
        done && done.status === 0 && done.out === golden,
        JSON.stringify({ status: done && done.status, got: done && done.out.slice(0, 400),
          want: golden.slice(0, 400), flags }));
      check('w111_input: the preventDefault list and the context menu',
        flags && !flags.arrow && !flags.ctrlC && !flags.backspace && !flags.space
          && !flags.tab && !flags.f1 && flags.plainA && flags.contextMenu === false,
        JSON.stringify(flags));

      // 10. fit mode's ResizeObserver: the stage changes size, the program
      // gets EV_RESIZE with the new client size.
      writeScenario('resize.wasm', 'resize test', { canvas: 'fit', zoom: '1', smooth: 'false' });
      await cdp.navigate(base + '?ytest=1');
      s = await cdp.waitPanel('size ', 15000);
      await cdp.eval('(function(){var s=document.getElementById("stage");' +
        's.style.flex="0 0 240px";s.style.height="240px";return s.clientHeight;})()');
      s = await cdp.waitDone(30000);
      done = decodeOut(s);
      info = await cdp.canvasInfo();
      out = done ? done.out : '';
      const rz = /^resize ([0-9]+) ([0-9]+)$/m.exec(out);
      check('w112_resize: fit mode delivers EV_RESIZE',
        done && done.status === 0 && rz && info.w === Number(rz[1]) && info.h === Number(rz[2])
          && out.includes('final ' + rz[1] + ' ' + rz[2]),
        JSON.stringify({ done: done && done.status, resize: rz && rz.slice(1), canvas: [info.w, info.h],
          out: out.slice(0, 300), state: s.state, banner: s.banner, panel: s.panel.slice(0, 200) }));
    }

    // 11. w112_audio: the AudioContext, the worklet's consumed-frame
    // reports, non-silent samples, the gesture hook and muting
    // (W7/S12).  The launcher passes --autoplay-policy=no-user-gesture-required,
    // so the context may start running before any input; the synthetic
    // pointerdown below exercises the hook either way.
    writeScenario('audio.wasm', 'audio test');
    await cdp.navigate(base + '?ytest=1');
    s = await cdp.waitDone(30000);
    done = decodeOut(s);
    let audio = await cdp.eval('__ywebAudio ? __ywebAudio() : null');
    check('w112_audio: the browser sink is available and the program wrote to it',
      done && done.status === 0 && /^devs true$/m.test(done.out) && /^wrote 480 ms$/m.test(done.out),
      JSON.stringify({ done, audio }));
    check('w112_audio: the AudioContext reaches running', audio && audio.state === 'running', JSON.stringify(audio));
    check('w112_audio: consumed-frame reports arrive',
      audio && audio.reports > 0 && audio.consumedFrames > 0, JSON.stringify(audio));
    check('w112_audio: the page audio is non-silent', audio && audio.peak > 0, JSON.stringify(audio));
    const gestured = await cdp.eval('(function(){window.dispatchEvent(new PointerEvent("pointerdown",{bubbles:true}));return __ywebAudio();})()');
    check('w112_audio: the first gesture hook runs and resumes',
      gestured && gestured.gesture === true && gestured.state === 'running', JSON.stringify(gestured));
    await cdp.eval('__ywebHost.audio.setMuted(true)');
    const muted = await cdp.eval('__ywebAudio().muted');
    check('w112_audio: the page can mute the gain', muted === true, JSON.stringify(muted));

    // 12. w113_fetch: std/web in the page (W8/S10).  The query string, eval,
    // a sibling file's fetch, a 404 and window.open (the launcher disables
    // popup blocking, so the program's own tab really opens).
    if (webWhy) {
      console.log('skip web: ' + webWhy);
    } else {
      writeScenario('web.wasm', 'web test');
      await cdp.navigate(base + '?ytest=1&tag=tag-value');
      s = await cdp.waitDone(30000);
      done = decodeOut(s);
      const wout = done ? done.out : '';
      check('w113_fetch: fetch of a sibling file crosses the page',
        done && done.status === 0 && /^platform browser$/m.test(wout)
          && /^fetch web fetch in a page$/m.test(wout) && /^fetchlen 20$/m.test(wout)
          && /^missing none$/m.test(wout),
        JSON.stringify({ done: done && done.status, out: wout.slice(0, 300) }));
      check('w113_fetch: param, eval and open_url',
        done && done.status === 0 && /^param tag-value$/m.test(wout) && /^eval 42$/m.test(wout)
          && /^open true$/m.test(wout) && /^done$/m.test(wout),
        JSON.stringify(done && done.out));
    }

    try {
      await runFirefox(site, base, writeScenario);
    } catch (e) {
      check('Firefox: browser checks', false, e && e.message ? e.message : String(e));
    }

    const failed = results.filter((r) => !r.ok);
    console.log('# browser: ' + (results.length - failed.length) + '/' + results.length + ' checks passed');
    return failed.length === 0 ? 0 : 1;
  } finally {
    try { child.kill(); } catch (e) {}
    try { server.close(); } catch (e) {}
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) {}
  }
}

main().then((code) => { process.exitCode = code; }).catch((e) => {
  console.error('browser test failed: ' + (e && e.stack ? e.stack : String(e)));
  process.exitCode = 1;
});
