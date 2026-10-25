// src/web/audio.js — the audio platform behind Y_SYS.AUDIO_*.
//
// The Y side is src/y/arch/web.s: y_os_audio_devs/open/write/close issue the
// private syscalls 22787-22790 (Appendix C), and core.js hands each one to the
// Audio object this module installs on the host.  Nothing here imports node:;
// the browser backend uses AudioContext and the Node backend writes a WAV
// through the fs object yhost.js passes in.
//
// A stream is signed 16-bit little-endian, the channels interleaved, at the
// rate and channel count the program declared (1, 2 or 6).  In the browser the
// samples become Float32 channels, are resampled linearly when the declared
// rate differs from the context's, and are played by an inline AudioWorklet;
// when addModule fails (a CSP without blob:) a ScriptProcessorNode takes over.
// The worklet reports the frames it has consumed every 20 ms, and a write
// blocks its green thread while more than 250 ms is queued, until less than
// 150 ms is.  Under Node nothing blocks: the samples are appended to a WAV
// whose header is patched when the process ends.

export const EIO = -5;
export const EBADF = -9;
export const EFAULT = -14;
export const EBUSY = -16;
export const EINVAL = -22;
export const ENOSYS = -38;

const MAX_RATE = 1000000;
const BLOCK_MS = 250;
const RESUME_MS = 150;
const DROP_MS = 100;
const REPORT_MS = 20;

// ---------------------------------------------------------------------------
// The inline worklet.  It owns the play-out queue and counts rendered frames;
// currentFrame is not used because a stream can be created long after the
// context started.
// ---------------------------------------------------------------------------

const WORKLET_SOURCE = `
class YAudioProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.blocks = [];
    this.readFrame = 0;
    this.consumed = 0;
    this.peak = 0;
    this.reportedAt = -1;
    this.port.onmessage = (event) => {
      const msg = event.data || {};
      if (msg.type === 'data' && msg.channels && msg.channels.length > 0) {
        const list = [];
        for (let c = 0; c < msg.channels.length; c++) list.push(msg.channels[c]);
        this.blocks.push(list);
      } else if (msg.type === 'drop') {
        this.drop(msg.keep || 0);
      }
    };
  }
  queued() {
    let n = 0;
    for (let i = 0; i < this.blocks.length; i++) {
      n += this.blocks[i][0].length - (i === 0 ? this.readFrame : 0);
    }
    return n;
  }
  drop(keep) {
    const before = this.queued();
    let drop = before - keep;
    while (drop > 0 && this.blocks.length > 0) {
      const block = this.blocks[0];
      const avail = block[0].length - this.readFrame;
      if (avail <= drop) {
        drop -= avail;
        this.blocks.shift();
        this.readFrame = 0;
      } else {
        this.readFrame += drop;
        drop = 0;
      }
    }
    this.port.postMessage({ type: 'dropped', frames: before - this.queued() });
  }
  process(inputs, outputs) {
    const out = outputs[0] || [];
    const frames = out.length > 0 ? out[0].length : 128;
    for (let c = 0; c < out.length; c++) out[c].fill(0);
    let wrote = 0;
    let need = frames;
    while (need > 0 && this.blocks.length > 0) {
      const block = this.blocks[0];
      const avail = block[0].length - this.readFrame;
      if (avail <= 0) {
        this.blocks.shift();
        this.readFrame = 0;
        continue;
      }
      const take = Math.min(need, avail);
      for (let c = 0; c < out.length; c++) {
        const src = block[c < block.length ? c : 0];
        out[c].set(src.subarray(this.readFrame, this.readFrame + take), wrote);
        for (let i = this.readFrame; i < this.readFrame + take; i++) {
          const v = src[i] < 0 ? -src[i] : src[i];
          if (v > this.peak) this.peak = v;
        }
      }
      this.readFrame += take;
      wrote += take;
      need -= take;
      if (this.readFrame >= block[0].length) {
        this.blocks.shift();
        this.readFrame = 0;
      }
    }
    this.consumed += frames;
    if (this.reportedAt < 0) this.reportedAt = currentTime;
    if (currentTime - this.reportedAt >= 20 / 1000) {
      this.reportedAt = currentTime;
      this.port.postMessage({ type: 'consumed', frames: this.consumed, peak: this.peak });
      this.peak = 0;
    }
    return true;
  }
}
registerProcessor('y-audio', YAudioProcessor);
`;

const WORKLET_NAME = 'y-audio';

// ---------------------------------------------------------------------------
// WAV: the Node sink.  One file, one declared rate/channel count; the header
// is written once and patched at exit so the RIFF and data lengths are right
// however the program ended.
// ---------------------------------------------------------------------------

function wavHeader(rate, channels, dataLen) {
  const b = new Uint8Array(44);
  const dv = new DataView(b.buffer);
  const ascii = (off, s) => {
    for (let i = 0; i < s.length; i++) b[off + i] = s.charCodeAt(i) & 0xff;
  };
  ascii(0, 'RIFF');
  dv.setUint32(4, 36 + dataLen, true);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  dv.setUint32(16, 16, true);           // fmt chunk size
  dv.setUint16(20, 1, true);            // PCM
  dv.setUint16(22, channels, true);
  dv.setUint32(24, rate, true);
  dv.setUint32(28, rate * channels * 2, true);
  dv.setUint16(32, channels * 2, true);
  dv.setUint16(34, 16, true);
  ascii(36, 'data');
  dv.setUint32(40, dataLen, true);
  return b;
}

export class WavSink {
  constructor(fs, file) {
    this.fs = fs;
    this.file = file;
    this.fd = -1;
    this.rate = 0;
    this.channels = 0;
    this.dataBytes = 0;
    this.failed = false;
  }

  devs() {
    return this.file ? 1 : 0;
  }

  open(rate, channels) {
    if (this.fd < 0) {
      try {
        this.fd = this.fs.openSync(this.file, 'w');
        this.rate = rate;
        this.channels = channels;
        this.fs.writeSync(this.fd, wavHeader(rate, channels, 0));
      } catch (e) {
        this.failed = true;
        try {
          if (this.fd >= 0) this.fs.closeSync(this.fd);
        } catch (ignored) { /* the open failed */ }
        this.fd = -1;
        return EIO;
      }
    } else if (rate !== this.rate || channels !== this.channels) {
      // A WAV has one fmt chunk; mixing rates or channel counts in it would
      // make the file lie.  The caller can reopen with the same declaration.
      return EBUSY;
    }
    return { kind: 'wav' };
  }

  write(stream, bytes) {
    if (this.fd < 0 || this.failed) return EIO;
    try {
      let off = 0;
      while (off < bytes.length) {
        off += this.fs.writeSync(this.fd, bytes, off, bytes.length - off);
      }
      this.dataBytes += bytes.length;
      return 0;
    } catch (e) {
      this.failed = true;
      return EIO;
    }
  }

  close(stream) {
    // The file stays open so a later open() can append to the same WAV.  The
    // header is patched now (so a program that reads its own recording sees
    // the right lengths) and again in finish() when the process ends.
    this.patch();
  }

  patch() {
    if (this.fd < 0 || this.failed) return;
    try {
      const head = wavHeader(this.rate || 44100, this.channels || 2, this.dataBytes);
      this.fs.writeSync(this.fd, head, 0, head.length, 0);
    } catch (e) {
      this.failed = true;
    }
  }

  finish() {
    if (this.failed) return;
    try {
      if (this.fd < 0 && this.file) {
        // --audio with no open: still leave a valid, empty WAV behind.
        this.fd = this.fs.openSync(this.file, 'w');
        this.rate = 44100;
        this.channels = 2;
        this.fs.writeSync(this.fd, wavHeader(this.rate, this.channels, 0));
      }
      if (this.fd >= 0) {
        this.patch();
        this.fs.closeSync(this.fd);
        this.fd = -1;
      }
    } catch (e) {
      this.failed = true;
    }
  }
}

// ---------------------------------------------------------------------------
// The browser sink: AudioContext + AudioWorklet (or ScriptProcessorNode).
// ---------------------------------------------------------------------------

function audioContextCtor() {
  if (typeof globalThis === 'undefined') return null;
  return globalThis.AudioContext || globalThis.webkitAudioContext || null;
}

function s16ToChannels(bytes, channels) {
  const frames = Math.floor(bytes.length / (2 * channels));
  const out = [];
  for (let c = 0; c < channels; c++) out.push(new Float32Array(frames));
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.length);
  let p = 0;
  for (let f = 0; f < frames; f++) {
    for (let c = 0; c < channels; c++) {
      out[c][f] = dv.getInt16(p, true) / 32768;
      p += 2;
    }
  }
  return out;
}

// Linear resampling with one-sample state across writes, so a stream split
// into many small writes is continuous.
function resampleChannels(input, inRate, outRate, state) {
  const ratio = inRate / outRate;
  const n = input[0].length;
  const start = state.phase;
  const outLen = Math.max(0, Math.ceil((n - start) / ratio));
  const out = [];
  let pos = start;
  for (let c = 0; c < input.length; c++) {
    const src = input[c];
    const dst = new Float32Array(outLen);
    const prev = state.last[c];
    for (let j = 0; j < outLen; j++) {
      const i = Math.floor(pos);
      const frac = pos - i;
      const a = i < 0 ? prev : i < n ? src[i] : src[n - 1];
      const b = i + 1 < n ? src[i + 1] : a;
      dst[j] = a + (b - a) * frac;
      pos += ratio;
    }
    state.last[c] = n > 0 ? src[n - 1] : prev;
    out.push(dst);
  }
  state.phase = pos - n;
  if (!Number.isFinite(state.phase) || state.phase < 0) state.phase = 0;
  return out;
}

function peakOf(channels) {
  let peak = 0;
  for (const ch of channels) {
    for (let i = 0; i < ch.length; i++) {
      const v = ch[i] < 0 ? -ch[i] : ch[i];
      if (v > peak) peak = v;
    }
  }
  return peak;
}

export class BrowserSink {
  constructor(host, opts = {}) {
    this.host = host;
    this.Ctor = audioContextCtor();
    this.ctx = null;
    this.gain = null;
    this.workletReady = false;
    this.workletUrl = null;
    this.mode = '';
    this.streams = [];
    this.waiters = [];
    this.gestureSeen = false;
    this.muted = !!opts.muted;
    this.hidden = false;
    this.reports = 0;
    this.postedFrames = 0;
    this.peak = 0;
    this.postedPeak = 0;
    this.failures = 0;
  }

  devs() {
    return this.Ctor ? 1 : 0;
  }

  get context() {
    return this.ctx;
  }

  ensureContext() {
    if (this.ctx) return this.ctx;
    if (!this.Ctor) return null;
    try {
      const ctx = new this.Ctor({ latencyHint: 'interactive' });
      this.ctx = ctx;
      this.gain = ctx.createGain();
      this.gain.gain.value = this.muted ? 0 : 1;
      this.gain.connect(ctx.destination);
      // S12: a context made before the first gesture starts suspended.  With
      // --autoplay-policy=no-user-gesture-required it is already running.
      if (this.gestureSeen && ctx.state === 'suspended' && typeof ctx.resume === 'function') {
        ctx.resume().catch(() => {});
      }
      return ctx;
    } catch (e) {
      this.failures += 1;
      this.ctx = null;
      return null;
    }
  }

  running() {
    return !!(this.ctx && this.ctx.state === 'running');
  }

  open(rate, channels) {
    const ctx = this.ensureContext();
    if (!ctx) return ENOSYS;
    const stream = {
      id: this.streams.length + 1,
      rate,
      channels,
      ctxRate: ctx.sampleRate,
      node: null,
      ready: false,
      kind: '',
      pre: [],
      scriptQueue: [],
      postedFrames: 0,
      consumedFrames: 0,
      peak: 0,
      phase: 0,
      last: new Array(channels).fill(0),
      closed: false,
      failed: false,
    };
    this.streams.push(stream);
    this.setup(stream);
    return stream;
  }

  async setup(stream) {
    try {
      const ctx = this.ctx;
      if (!this.workletReady) {
        if (!this.workletUrl && typeof URL !== 'undefined' && typeof Blob !== 'undefined') {
          this.workletUrl = URL.createObjectURL(new Blob([WORKLET_SOURCE], { type: 'text/javascript' }));
        }
        await ctx.audioWorklet.addModule(this.workletUrl);
        this.workletReady = true;
      }
      if (stream.closed) return;
      const node = new AudioWorkletNode(ctx, WORKLET_NAME, {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [stream.channels],
      });
      node.port.onmessage = (event) => this.onMessage(stream, event.data);
      node.connect(this.gain || ctx.destination);
      stream.node = node;
      stream.kind = 'worklet';
      this.mode = 'worklet';
    } catch (e) {
      // addModule refused (a CSP without blob:) or the node could not be
      // built: the ScriptProcessorNode path needs no module at all.
      if (stream.closed) return;
      try {
        let node;
        try {
          node = this.ctx.createScriptProcessor(4096, 0, stream.channels);
        } catch (e2) {
          node = this.ctx.createScriptProcessor(4096, stream.channels, stream.channels);
        }
        node.onaudioprocess = (event) => this.onScriptProcess(stream, event);
        node.connect(this.gain || this.ctx.destination);
        stream.node = node;
        stream.kind = 'script';
        this.mode = 'script';
      } catch (e3) {
        stream.failed = true;
        this.failures += 1;
      }
    }
    stream.ready = true;
    if (!stream.failed) this.flush(stream);
    this.wake();
  }

  flush(stream) {
    if (!stream.node) return;
    const pending = stream.pre;
    stream.pre = [];
    for (const block of pending) this.post(stream, block);
  }

  post(stream, channels) {
    if (!stream.node) {
      stream.pre.push(channels);
      return;
    }
    if (stream.kind === 'worklet') {
      try {
        // Transfer the backing buffers: a typed array itself is not a
        // Transferable, so passing the array as the transfer list throws.
        const transfer = [];
        for (const ch of channels) transfer.push(ch.buffer);
        stream.node.port.postMessage({ type: 'data', channels }, transfer);
      } catch (e) {
        this.failures += 1;
      }
    } else {
      stream.scriptQueue.push(channels);
    }
  }

  write(stream, bytes) {
    if (stream.closed || stream.failed) return EIO;
    const channels = s16ToChannels(bytes, stream.channels);
    let block = channels;
    if (stream.rate !== this.ctx.sampleRate) {
      block = resampleChannels(channels, stream.rate, this.ctx.sampleRate, stream);
    }
    if (block.length === 0 || block[0].length === 0) return 0;
    const frames = block[0].length;
    stream.postedFrames += frames;
    this.postedFrames += frames;
    const p = peakOf(block);
    if (p > this.postedPeak) this.postedPeak = p;
    if (p > stream.peak) stream.peak = p;
    this.post(stream, block);
    const queued = this.queuedMs(stream);
    // A suspended context cannot consume, so blocking would deadlock; the
    // first gesture resumes it and drops everything beyond 100 ms (S12).
    if (queued > BLOCK_MS && this.running() && !this.hidden) {
      return { block: true, wait: this.waitFor(stream) };
    }
    return 0;
  }

  queuedMs(stream) {
    const rate = this.ctx ? this.ctx.sampleRate : stream.ctxRate;
    const frames = stream.postedFrames - stream.consumedFrames;
    if (!(frames > 0) || !(rate > 0)) return 0;
    return (frames * 1000) / rate;
  }

  // The wait object core.js's block()/serviceWaits() understand: ready() is
  // polled after every consume report, resume() supplies the write's result.
  waitFor(stream) {
    const self = this;
    const wait = {
      ready: () => stream.closed || stream.failed || !self.running() || self.queuedMs(stream) < RESUME_MS,
      resume: () => 0n,
      _promise: null,
      // The scheduler reads wait.promise again on every pass.  A promise that
      // was resolved while ready() is still false must not be awaited twice
      // (a resolved promise would spin the async loop and starve the audio
      // thread's messages); wake() clears it so the next read re-arms.
      get promise() {
        if (wait._promise === null) {
          wait._promise = new Promise((resolve) => {
            self.waiters.push(() => {
              wait._promise = null;
              resolve();
            });
          });
        }
        return wait._promise;
      },
    };
    return wait;
  }

  onMessage(stream, msg) {
    if (!msg) return;
    if (msg.type === 'consumed') {
      stream.consumedFrames = Number(msg.frames) || 0;
      const peak = Number(msg.peak) || 0;
      if (peak > this.peak) this.peak = peak;
      if (peak > stream.peak) stream.peak = peak;
      this.reports += 1;
      this.wake();
    } else if (msg.type === 'dropped') {
      const n = Number(msg.frames) || 0;
      stream.postedFrames = Math.max(0, stream.postedFrames - n);
      this.postedFrames = Math.max(0, this.postedFrames - n);
    }
  }

  onScriptProcess(stream, event) {
    const out = event.outputBuffer;
    const frames = out.length;
    for (let c = 0; c < out.numberOfChannels; c++) out.getChannelData(c).fill(0);
    let need = frames;
    let wrote = 0;
    while (need > 0 && stream.scriptQueue.length > 0) {
      const block = stream.scriptQueue[0];
      const avail = block[0].length;
      const take = Math.min(need, avail);
      for (let c = 0; c < out.numberOfChannels; c++) {
        const src = block[c < block.length ? c : 0];
        out.getChannelData(c).set(src.subarray(0, take), wrote);
        for (let i = 0; i < take; i++) {
          const v = src[i] < 0 ? -src[i] : src[i];
          if (v > this.peak) this.peak = v;
          if (v > stream.peak) stream.peak = v;
        }
      }
      if (take >= avail) stream.scriptQueue.shift();
      else stream.scriptQueue[0] = block.map((ch) => ch.subarray(take));
      wrote += take;
      need -= take;
    }
    stream.consumedFrames += frames;
    this.reports += 1;
    this.wake();
  }

  wake() {
    const waiters = this.waiters;
    this.waiters = [];
    for (const wake of waiters) wake();
    if (this.host && typeof this.host.notifyFd === 'function') this.host.notifyFd();
  }

  close(stream) {
    stream.closed = true;
    if (stream.node) {
      try {
        if (typeof stream.node.disconnect === 'function') stream.node.disconnect();
      } catch (e) { /* already disconnected */ }
      try {
        if (stream.kind === 'worklet' && stream.node.port) stream.node.port.close();
        if (stream.kind === 'script') stream.node.onaudioprocess = null;
      } catch (e) { /* the node is gone */ }
      stream.node = null;
    }
    stream.pre = [];
    stream.scriptQueue = [];
    this.wake();
  }

  // First pointerdown/keydown (S12): resume and drop what is beyond 100 ms so
  // a backlog is not played late.
  gesture() {
    this.gestureSeen = true;
    if (this.ctx && this.ctx.state === 'suspended' && typeof this.ctx.resume === 'function') {
      this.ctx.resume().catch(() => {});
    }
    this.dropBeyond(DROP_MS);
  }

  dropBeyond(ms) {
    for (const stream of this.streams) {
      if (stream.closed) continue;
      const rate = this.ctx ? this.ctx.sampleRate : stream.ctxRate;
      const keep = Math.max(0, Math.floor((ms * rate) / 1000));
      if (!stream.ready) {
        let total = 0;
        for (const b of stream.pre) total += b[0].length;
        let drop = total - keep;
        while (drop > 0 && stream.pre.length > 0) {
          const b = stream.pre[0];
          const n = b[0].length;
          if (n <= drop) {
            stream.pre.shift();
            drop -= n;
            stream.postedFrames -= n;
            this.postedFrames -= n;
          } else {
            stream.pre[0] = b.map((ch) => ch.subarray(drop));
            stream.postedFrames -= drop;
            this.postedFrames -= drop;
            drop = 0;
          }
        }
        continue;
      }
      if (stream.kind === 'worklet' && stream.node) {
        try {
          stream.node.port.postMessage({ type: 'drop', keep });
        } catch (e) { /* the node is gone */ }
      } else if (stream.kind === 'script') {
        let total = 0;
        for (const b of stream.scriptQueue) total += b[0].length;
        let drop = total - keep;
        while (drop > 0 && stream.scriptQueue.length > 0) {
          const b = stream.scriptQueue[0];
          const n = b[0].length;
          if (n <= drop) {
            stream.scriptQueue.shift();
            drop -= n;
            stream.postedFrames -= n;
            this.postedFrames -= n;
          } else {
            stream.scriptQueue[0] = b.map((ch) => ch.subarray(drop));
            stream.postedFrames -= drop;
            this.postedFrames -= drop;
            drop = 0;
          }
        }
      }
    }
  }

  setHidden(hidden) {
    this.hidden = !!hidden;
    if (!this.ctx) return;
    if (hidden) {
      if (typeof this.ctx.suspend === 'function' && this.ctx.state === 'running') this.ctx.suspend().catch(() => {});
    } else if (typeof this.ctx.resume === 'function' && this.ctx.state === 'suspended') {
      // Try both after a gesture and after a context the autoplay policy let
      // run before the tab was hidden; a refusal is the browser's call.
      this.ctx.resume().catch(() => {});
    }
  }

  setMuted(muted) {
    this.muted = !!muted;
    if (this.gain) this.gain.gain.value = this.muted ? 0 : 1;
  }

  closeAll() {
    for (const stream of this.streams) this.close(stream);
  }

  stats() {
    let consumed = 0;
    let streams = 0;
    for (const s of this.streams) {
      consumed += s.consumedFrames;
      if (!s.closed) streams += 1;
    }
    return {
      available: this.devs() > 0,
      state: this.ctx ? this.ctx.state : 'none',
      sampleRate: this.ctx ? this.ctx.sampleRate : 0,
      mode: this.mode,
      gesture: this.gestureSeen,
      reports: this.reports,
      postedFrames: this.postedFrames,
      consumedFrames: consumed,
      peak: this.peak,
      postedPeak: this.postedPeak,
      streams,
      failures: this.failures,
      muted: this.muted,
    };
  }
}

// ---------------------------------------------------------------------------
// The null sink: no AudioContext (Node without --audio) and no WAV path.
// ---------------------------------------------------------------------------

export class NullSink {
  devs() { return 0; }
  open() { return ENOSYS; }
  write() { return ENOSYS; }
  close() { return 0; }
  finish() {}
}

// ---------------------------------------------------------------------------
// The object core.js's dispatch talks to.  It owns the handle table, validates
// the arguments and memory range, and gives a blocking write the host's block()
// seam.
// ---------------------------------------------------------------------------

export class Audio {
  constructor(host, sink, opts = {}) {
    this.host = host;
    this.sink = sink;
    this.handles = new Map();
    this.nextHandle = 1;
    this.muted = !!opts.muted;
    if (this.muted && typeof sink.setMuted === 'function') sink.setMuted(true);
  }

  devs() {
    try {
      return this.sink.devs() ? 1 : 0;
    } catch (e) {
      return 0;
    }
  }

  open(rate, channels) {
    const r = Number(rate);
    const c = Number(channels);
    if (!Number.isSafeInteger(r) || r <= 0 || r > MAX_RATE) return EINVAL;
    if (c !== 1 && c !== 2 && c !== 6) return EINVAL;
    let stream;
    try {
      stream = this.sink.open(r, c);
    } catch (e) {
      return EIO;
    }
    if (typeof stream === 'number') return stream;
    if (!stream || stream.failed) return EIO;
    const handle = this.nextHandle++;
    this.handles.set(handle, stream);
    stream.handle = handle;
    return handle;
  }

  write(handle, ptr, len) {
    const stream = this.handles.get(handle);
    if (!stream) return EBADF;
    const n = Number(len);
    if (!Number.isSafeInteger(n) || n < 0) return EINVAL;
    if (n === 0) return 0;
    const bytes = this.host.memoryBytes(Number(ptr), n);
    if (bytes === null) return EFAULT;
    let r;
    try {
      r = this.sink.write(stream, bytes);
    } catch (e) {
      return EIO;
    }
    if (typeof r === 'number') {
      if (r < 0) return r;
      return n;
    }
    if (r && r.block) {
      // The green thread parks here; the scheduler stores n in rax when the
      // worklet has drained enough (the wait's resume is the write's result).
      const wait = r.wait;
      wait.resume = () => BigInt(n);
      if (this.host && typeof this.host.block === 'function') return this.host.block(wait);
      return n;
    }
    return n;
  }

  close(handle) {
    const stream = this.handles.get(handle);
    if (!stream) return 0;
    this.handles.delete(handle);
    try {
      this.sink.close(stream);
    } catch (e) { /* the sink is gone */ }
    return 0;
  }

  finish() {
    try {
      if (typeof this.sink.finish === 'function') this.sink.finish();
    } catch (e) { /* nothing can be done after the program has ended */ }
  }

  setHidden(hidden) {
    if (typeof this.sink.setHidden === 'function') {
      try {
        this.sink.setHidden(!!hidden);
      } catch (e) { /* audio is optional */ }
    }
  }

  gesture() {
    if (typeof this.sink.gesture === 'function') {
      try {
        this.sink.gesture();
      } catch (e) { /* audio is optional */ }
    }
  }

  setMuted(muted) {
    this.muted = !!muted;
    if (typeof this.sink.setMuted === 'function') this.sink.setMuted(this.muted);
  }

  get context() {
    return this.sink.context || null;
  }

  stats() {
    if (typeof this.sink.stats === 'function') return this.sink.stats();
    return { available: this.devs() > 0, state: 'none', reports: 0, consumedFrames: 0, peak: 0 };
  }
}

/**
 * Install the audio platform on a host.  opts.wav (Node) names the
 * WAV sink; opts.browser selects the AudioContext sink; opts.fs is the Node fs
 * used by the WAV sink.  With neither, devs answers 0 and open -ENOSYS, which
 * is exactly what snd probes for.
 */
export function installAudio(host, opts = {}) {
  let sink;
  if (opts.wav) {
    sink = new WavSink(opts.fs || null, String(opts.wav));
  } else if (opts.browser === true || (opts.browser !== false && audioContextCtor() !== null)) {
    sink = new BrowserSink(host, opts);
  } else {
    sink = new NullSink();
  }
  return new Audio(host, sink, opts);
}
