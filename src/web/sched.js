// src/web/sched.js — the green-thread scheduler for yhost.js.
//
// One module instance holds N threads; each thread is a wasm context (S3's
// 512-byte layout) and a pc token.  The scheduler picks runnable threads round
// robin and runs one slice: ctx_load, set_fuel(f), resume(pc).  When resume
// returns (or the syscall import throws YWhy) it acts on why():
//
//   PREEMPT      the fuel ran out: requeue
//   YIELD        sched_yield: requeue
//   BLOCK        park on the wait object the syscall built
//   EXIT         end the process with exitStatus
//   THREAD_EXIT  free the thread, clear its ctid and wake a join futex
//
// A blocking syscall's result is not known when it blocks.  The wait object
// carries a ready() test and a resume() thunk; when the scheduler wakes the
// thread it runs resume(), stores the i64 in ctx.R0 and marks the thread for a
// ctx_load.  That is S8's sequence exactly:
//
//   thread blocks -> why=1 -> resume returns -> ctx_save -> parked
//   wake -> ctx[0..8] = result -> ctx_load -> set_fuel -> resume(ctx.pc)
//
// Modules that export set_why (the current compiler does) get the reason
// through the global; older modules get it thrown as YWhy.  Both are the same
// seam, and both snapshot the post-syscall continuation the same way.

import { STATUS, WHY, statusForSignal } from './abi.js';

const nowMs = () => (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();

export class YWhy extends Error {
  constructor(reason, opts = {}) {
    super(`yield reason ${reason}`);
    this.name = 'YWhy';
    this.reason = reason;
    this.status = opts.status;
    this.wait = opts.wait === undefined ? null : opts.wait;
  }
}

export class YTrap extends Error {
  constructor(signal) {
    super(`trap signal ${signal}`);
    this.name = 'YTrap';
    this.signal = Number(signal) & 0xffff;
  }
}

export function sleepSync(ms) {
  if (!(ms > 0)) return;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Math.ceil(ms));
}

// A wasm stack overflow surfaces as a RangeError in V8, not a
// WebAssembly.RuntimeError; S8's 139 is what a native stack overflow gives.
export function isWasmStackOverflow(err) {
  return (
    err instanceof RangeError &&
    typeof err.message === 'string' &&
    /call stack|stack size|stack overflow/i.test(err.message)
  );
}

export class Scheduler {
  constructor(kernel, opts = {}) {
    this.kernel = kernel;
    this.fuel = Number.isFinite(opts.fuel) ? opts.fuel >>> 0 : 1000000;
    this.trace = !!opts.trace;
    this.threads = [];
    this.current = null;
    this.cursor = 0;
    this.message = null;
    this.slices = 0;
    // ?perf=1 (the page) collects slice durations; the page reports p50/p95.
    this.perf = false;
    this.sliceMs = [];
    this.sliceBudget = opts.sliceMs === undefined ? 8 : Number(opts.sliceMs);
    this.started = kernel.now ? kernel.now() : 0;
  }

  addThread(t) {
    if (!Number.isInteger(t.id)) t.id = this.threads.length + 1;
    if (!t.state) t.state = 'runnable';
    if (t.needsLoad === undefined) t.needsLoad = true;
    if (t.wait === undefined) t.wait = null;
    if (t.exitCode === undefined) t.exitCode = 0;
    this.threads.push(t);
    return t;
  }

  liveCount() {
    let n = 0;
    for (const t of this.threads) if (t.state !== 'dead') n++;
    return n;
  }

  hasLiveThreads() {
    return this.liveCount() > 0;
  }

  pickRunnable() {
    const n = this.threads.length;
    for (let i = 0; i < n; i++) {
      const idx = (this.cursor + i) % n;
      const t = this.threads[idx];
      if (t.state === 'runnable') {
        this.cursor = (idx + 1) % n;
        return t;
      }
    }
    return null;
  }

  // Wake a blocked thread with the result to put in rax (S8 step 5).
  wakeThread(t, result) {
    if (t.state !== 'blocked') return false;
    t.state = 'runnable';
    t.wait = null;
    t.wakeResult = typeof result === 'bigint' ? result : BigInt(result === undefined ? 0 : result);
    t.needsLoad = true;
    return true;
  }

  // Run ready()/timeouts for every parked thread.  Called before a slice,
  // after any fd operation (a pipe write makes a reader ready) and after a
  // sleep.  Returns the number of threads woken.
  serviceWaits() {
    let woke = 0;
    const now = this.kernel.now();
    for (const t of this.threads) {
      if (t.state !== 'blocked' || !t.wait) continue;
      const w = t.wait;
      // Readiness wins over a timeout at the same instant: poll on a timerfd
      // whose deadline has arrived reports POLLIN, not a zero result.
      let ready = false;
      if (typeof w.ready === 'function') {
        try {
          ready = !!w.ready();
        } catch (e) {
          ready = false;
        }
      }
      if (ready) {
        let r = 0n;
        try {
          r = typeof w.resume === 'function' ? w.resume() : 0n;
        } catch (e) {
          r = -5n; // EIO: a host-side wait thunk failed
        }
        if (this.wakeThread(t, r)) woke++;
        continue;
      }
      if (w.until !== undefined && Number.isFinite(w.until) && now >= w.until) {
        const r = typeof w.onTimeout === 'function' ? w.onTimeout() : 0n;
        if (this.wakeThread(t, r)) woke++;
        continue;
      }
    }
    return woke;
  }

  earliestTimer() {
    let until = Infinity;
    for (const t of this.threads) {
      if (t.state !== 'blocked' || !t.wait) continue;
      const w = t.wait;
      if (w.until !== undefined && Number.isFinite(w.until)) until = Math.min(until, w.until);
    }
    return until;
  }

  finalStatus() {
    // The process status is the main thread's, or the last thread's if it
    // ended through exit(2) after the main thread was gone.
    const main = this.kernel.mainThread;
    if (main && main.exitCode !== undefined && main.exitReason === 'exit') return main.exitCode & 255;
    return this.kernel.exitStatus & 255;
  }

  // The synchronous loop (Node's default for tests and the plain CLI).
  run() {
    this.message = null;
    let status = null;
    while (status === null) {
      this.serviceWaits();
      const t = this.pickRunnable();
      if (!t) {
        if (!this.hasLiveThreads()) {
          status = this.finalStatus();
          break;
        }
        const until = this.earliestTimer();
        if (!Number.isFinite(until)) {
          // One more scan so a wake queued by the operation that parked the
          // last thread is not missed, then it really is stuck.
          if (this.serviceWaits() === 0) {
            throw new Error('deadlock: every thread is blocked and nothing can wake them');
          }
          continue;
        }
        this.kernel.sleepUntil(until);
        continue;
      }

      this.current = t;
      t.state = 'running';
      if (t.wakeResult !== undefined) {
        this.kernel.applyWake(t, t.wakeResult);
        t.wakeResult = undefined;
      }
      if (t.needsLoad) {
        this.kernel.loadContext(t);
        t.needsLoad = false;
      }
      this.kernel.setFuel(this.fuel);
      this.slices++;

      let exc = null;
      const t0 = this.perf ? nowMs() : 0;
      try {
        this.kernel.resume(t.pc);
      } catch (e) {
        exc = e;
      }
      if (this.perf) this.sliceMs.push(nowMs() - t0);
      status = this.finish(t, exc);
    }
    return status;
  }

  // The event-loop loop: sleeps with setTimeout and gives the event loop a
  // turn after every slice, so host promises and Node timers can progress.
  async runAsync() {
    this.message = null;
    let status = null;
    while (status === null) {
      // pause_hidden: a hidden page runs nothing; the clock is frozen by the
      // kernel, so on visibilitychange the pending deadlines are still ahead.
      if (this.kernel.waitUnpaused) await this.kernel.waitUnpaused();
      this.serviceWaits();
      const t = this.pickRunnable();
      if (!t) {
        if (!this.hasLiveThreads()) {
          status = this.finalStatus();
          break;
        }
        const until = this.earliestTimer();
        if (Number.isFinite(until)) {
          await this.kernel.sleepUntilAsync(until);
          continue;
        }
        const promises = [];
        for (const th of this.threads) {
          if (th.state === 'blocked' && th.wait && th.wait.promise) promises.push(th.wait.promise);
        }
        if (promises.length > 0) {
          await Promise.race(promises);
          continue;
        }
        if (this.serviceWaits() === 0) {
          throw new Error('deadlock: every thread is blocked and nothing can wake them');
        }
        continue;
      }

      this.current = t;
      t.state = 'running';
      if (t.wakeResult !== undefined) {
        this.kernel.applyWake(t, t.wakeResult);
        t.wakeResult = undefined;
      }
      if (t.needsLoad) {
        this.kernel.loadContext(t);
        t.needsLoad = false;
      }
      this.kernel.setFuel(this.fuel);
      this.slices++;

      let exc = null;
      const t0 = this.perf ? nowMs() : 0;
      try {
        this.kernel.resume(t.pc);
      } catch (e) {
        exc = e;
      }
      if (this.perf) this.sliceMs.push(nowMs() - t0);
      status = this.finish(t, exc);
      if (status === null) await this.kernel.yieldLoop();
    }
    return status;
  }

  // Returns a status to end the process, or null to continue scheduling.
  finish(t, exc) {
    let reason;
    if (exc) {
      if (exc instanceof YWhy) {
        reason = exc.reason;
        if (reason === WHY.EXIT) {
          const st = exc.status === undefined ? this.kernel.exitStatus : exc.status;
          this.kernel.exitStatus = st;
          t.exitReason = 'group';
          return st & 255;
        }
      } else if (exc instanceof YTrap) {
        this.kernel.trapped = true;
        this.kernel.trapSignal = exc.signal;
        return statusForSignal(exc.signal);
      } else if (exc instanceof WebAssembly.RuntimeError) {
        this.message = `segmentation fault (wasm: ${exc.message})`;
        this.kernel.trapped = true;
        this.kernel.trapSignal = 11;
        return STATUS.SIGSEGV;
      } else if (isWasmStackOverflow(exc)) {
        this.message = `segmentation fault (wasm: ${exc.message})`;
        this.kernel.trapped = true;
        this.kernel.trapSignal = 11;
        return STATUS.SIGSEGV;
      } else {
        throw exc;
      }
    } else {
      reason = this.kernel.why();
      if (reason === WHY.NONE) {
        throw new Error('module returned from resume without setting $why (host/ABI bug)');
      }
    }

    if (reason === WHY.EXIT) {
      return this.kernel.exitStatus & 255;
    }

    if (reason === WHY.THREAD_EXIT) {
      t.state = 'dead';
      t.exitReason = 'exit';
      t.wait = null;
      // No ctx_save: the thread is gone.  The kernel clears ctid, wakes a
      // join futex and releases the context page.
      this.kernel.threadExit(t);
      this.current = null;
      if (!this.hasLiveThreads()) return this.finalStatus();
      return null;
    }

    // ctx_save is the only way to read $pc back; the registers also have to
    // reach the context before another thread can run.
    this.kernel.saveContext(t);

    switch (reason) {
      case WHY.PREEMPT:
      case WHY.YIELD: {
        t.state = 'runnable';
        t.needsLoad = this.threads.length > 1;
        return null;
      }
      case WHY.BLOCK: {
        t.state = 'blocked';
        t.wait = (exc instanceof YWhy && exc.wait) || this.kernel.pendingWait || null;
        this.kernel.pendingWait = null;
        if (t.wait === null) throw new Error('blocked without a wait object (host bug)');
        return null;
      }
      default:
        throw new Error(`unknown yield reason ${reason}`);
    }
  }
}
