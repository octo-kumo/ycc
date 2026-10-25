// src/web/web.js — the web.* host functions.
//
// The Y side is src/y/std/web.y. It resolves these names through
// y_os_host_sym and calls them through y_os_host_call, every argument an i64:
//
//   web.platform  buf, cap                     -> the length, or -(needed)
//   web.param     name_ptr, name_len, buf, cap -> the length, or -ENOENT when
//                                                 there is no such parameter
//   web.eval      js_ptr, js_len, buf, cap     -> the result as a string
//   web.log       text_ptr, text_len           -> 0
//   web.open_url  url_ptr, url_len             -> 1 or 0
//   web.fetch     url_ptr, url_len             -> a fetch handle > 0, or 0
//   web.fetch_len handle                       -> the body's length
//   web.fetch_read handle, buf, cap            -> bytes copied, or -(needed)
//   web.fetch_free handle                      -> 0
//
// A string answer uses the (buf, cap) shape S10 defines: the bytes are copied
// into wasm memory at buf and their length returned, or -(needed) when the
// string did not fit. A web.fetch is a promise: the calling green thread
// blocks until the host's own fetch settles, and the body is read out of the
// handle table this module owns before fetch_free drops it.
//
// This file has no node: import and touches no DOM at module scope, so both
// hosts load it: yhost.js supplies Node's fs/fetch, vm and stdout, page.js the
// browser's fetch, window.open and console. Nothing here is platform policy.

import { encode as utf8Encode } from './vfs.js';

export const WEB_NAMES = [
  'platform', 'param', 'eval', 'log', 'open_url',
  'fetch', 'fetch_len', 'fetch_read', 'fetch_free',
];

const EPERM = -1;
const ENOENT = -2;
const EIO = -5;
const EFAULT = -14;
const EINVAL = -22;

function toInt(v) {
  if (typeof v === 'bigint') return Number(v);
  return Number(v) | 0;
}

// A JS value as the string web.eval answers: null and undefined are empty,
// a string is itself, anything else its String().
export function evalResultText(value) {
  if (value === undefined || value === null) return '';
  if (typeof value === 'string') return value;
  if (typeof value === 'bigint') return String(value);
  return String(value);
}

export class Web {
  constructor(host, opts = {}) {
    this.host = host;
    this.platform = String(opts.platform || 'node');
    this.paramOf = typeof opts.param === 'function' ? opts.param : () => null;
    this.evalOf = typeof opts.eval === 'function' ? opts.eval : ((js) => new Function(js)());
    this.logOf = typeof opts.log === 'function' ? opts.log : ((s) => console.log(s));
    this.openUrlOf = typeof opts.openUrl === 'function' ? opts.openUrl : (() => false);
    this.fetchBytesOf = typeof opts.fetchBytes === 'function' ? opts.fetchBytes : (async () => null);
    this.fetches = new Map();
    this.nextFetch = 1;
    for (const name of WEB_NAMES) {
      host.register('web.' + name, (args, mem) => this.dispatch(name, args, mem));
    }
  }

  dispatch(name, args, mem) {
    switch (name) {
      case 'platform': return this.platform_(args, mem);
      case 'param': return this.param(args, mem);
      case 'eval': return this.eval(args, mem);
      case 'log': return this.log(args, mem);
      case 'open_url': return this.openUrl(args, mem);
      case 'fetch': return this.fetch(args, mem);
      case 'fetch_len': return this.fetchLen(args);
      case 'fetch_read': return this.fetchRead(args);
      case 'fetch_free': return this.fetchFree(args);
      default: return BigInt(EINVAL);
    }
  }

  // The text at (ptr, len), or null when it is outside wasm memory.
  text(mem, args, at) {
    return mem.str(toInt(args[at]), toInt(args[at + 1]));
  }

  // Copy 'text' into the (buf, cap) pair at args[at]: the length, or
  // -(needed) when it did not fit. An invalid buffer is -EFAULT.
  put(args, at, text) {
    const bytes = utf8Encode(String(text));
    const ptr = toInt(args[at]);
    const cap = toInt(args[at + 1]);
    if (cap < bytes.length) return BigInt(-bytes.length);
    if (bytes.length === 0) return 0n;
    const view = this.host.memoryBytes(ptr, bytes.length);
    if (view === null) return BigInt(EFAULT);
    view.set(bytes);
    return BigInt(bytes.length);
  }

  platform_(args, mem) {
    return this.put(args, 0, this.platform);
  }

  param(args, mem) {
    const name = this.text(mem, args, 0);
    if (name === null) return BigInt(EFAULT);
    let value;
    try {
      value = this.paramOf(name);
    } catch (e) {
      return BigInt(EIO);
    }
    if (value === null || value === undefined) return BigInt(ENOENT);
    return this.put(args, 2, value);
  }

  eval(args, mem) {
    const js = this.text(mem, args, 0);
    if (js === null) return BigInt(EFAULT);
    let value;
    try {
      value = this.evalOf(js);
    } catch (e) {
      // a throw is none in Y, not a crash and not an empty string
      return BigInt(EIO);
    }
    return this.put(args, 2, evalResultText(value));
  }

  log(args, mem) {
    const text = this.text(mem, args, 0);
    if (text === null) return BigInt(EFAULT);
    try {
      this.logOf(text);
    } catch (e) {
      return BigInt(EIO);
    }
    return 0n;
  }

  openUrl(args, mem) {
    const url = this.text(mem, args, 0);
    if (url === null) return BigInt(EFAULT);
    let ok = false;
    try {
      ok = this.openUrlOf(url) === true;
    } catch (e) {
      return BigInt(EPERM);
    }
    return ok ? 1n : 0n;
  }

  fetch(args, mem) {
    const url = this.text(mem, args, 0);
    if (url === null) return BigInt(EFAULT);
    let pending;
    try {
      pending = this.fetchBytesOf(url);
    } catch (e) {
      return 0n;
    }
    return Promise.resolve(pending).then((bytes) => {
      if (!(bytes instanceof Uint8Array)) return 0n;
      const id = this.nextFetch++;
      this.fetches.set(id, bytes);
      return BigInt(id);
    }, () => 0n);
  }

  fetchLen(args) {
    const body = this.fetches.get(toInt(args[0]));
    if (!body) return BigInt(EINVAL);
    return BigInt(body.length);
  }

  fetchRead(args) {
    const body = this.fetches.get(toInt(args[0]));
    if (!body) return BigInt(EINVAL);
    const ptr = toInt(args[1]);
    const cap = toInt(args[2]);
    if (cap < body.length) return BigInt(-body.length);
    if (body.length === 0) return 0n;
    const view = this.host.memoryBytes(ptr, body.length);
    if (view === null) return BigInt(EFAULT);
    view.set(body);
    return BigInt(body.length);
  }

  fetchFree(args) {
    this.fetches.delete(toInt(args[0]));
    return 0n;
  }
}

/** Install the nine web.* names on a host and return the Web object. */
export function installWeb(host, opts = {}) {
  return new Web(host, opts);
}
