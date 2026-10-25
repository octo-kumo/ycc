// src/web/bytes.js — the byte array the browser host uses.
//
// Node has Buffer; the browser does not.  Every host module (vfs.js,
// memfs.js, core.js) is written against this small Uint8Array subclass, so the
// same code runs in both places.  Buffer is a Uint8Array too, so Node's fs
// accepts these values directly and a Node callback can still pass a Buffer
// in.  Only the handful of methods the host actually uses are provided.

export class U8 extends Uint8Array {
  static alloc(size, fill = 0) {
    const out = new U8(size);
    if (fill !== 0) out.fill(fill);
    return out;
  }

  static from(value, enc) {
    if (typeof value === 'string') {
      return new U8(new TextEncoder().encode(value).buffer);
    }
    if (value instanceof Uint8Array) {
      const out = new U8(value.length);
      out.set(value);
      return out;
    }
    if (value instanceof ArrayBuffer) return new U8(value);
    if (ArrayBuffer.isView(value)) return new U8(value.buffer, value.byteOffset, value.byteLength);
    return new U8(value);
  }

  static concat(list, total) {
    let n = total;
    if (n === undefined) {
      n = 0;
      for (const b of list) n += b.length;
    }
    const out = new U8(n);
    let off = 0;
    for (const b of list) {
      out.set(b, off);
      off += b.length;
    }
    return out;
  }

  static byteLength(value) {
    return typeof value === 'string' ? new TextEncoder().encode(value).length : value.length;
  }

  static isBuffer(value) {
    return value instanceof U8;
  }

  copy(target, targetStart = 0, sourceStart = 0, sourceEnd = this.length) {
    const part = this.subarray(sourceStart, sourceEnd);
    target.set(part, targetStart);
    return part.length;
  }

  readBigUInt64LE(off = 0) {
    return new DataView(this.buffer, this.byteOffset, this.byteLength).getBigUint64(off, true);
  }

  readBigInt64LE(off = 0) {
    return new DataView(this.buffer, this.byteOffset, this.byteLength).getBigInt64(off, true);
  }

  writeBigUInt64LE(value, off = 0) {
    new DataView(this.buffer, this.byteOffset, this.byteLength).setBigUint64(off, BigInt.asUintN(64, BigInt(value)), true);
    return off + 8;
  }

  writeBigInt64LE(value, off = 0) {
    new DataView(this.buffer, this.byteOffset, this.byteLength).setBigInt64(off, BigInt.asIntN(64, BigInt(value)), true);
    return off + 8;
  }

  readUInt16LE(off = 0) {
    return new DataView(this.buffer, this.byteOffset, this.byteLength).getUint16(off, true);
  }

  writeUInt16LE(value, off = 0) {
    new DataView(this.buffer, this.byteOffset, this.byteLength).setUint16(off, value & 0xffff, true);
    return off + 2;
  }

  readUInt32LE(off = 0) {
    return new DataView(this.buffer, this.byteOffset, this.byteLength).getUint32(off, true);
  }

  writeUInt32LE(value, off = 0) {
    new DataView(this.buffer, this.byteOffset, this.byteLength).setUint32(off, value >>> 0, true);
    return off + 4;
  }

  toString(enc) {
    if (enc === 'utf8' || enc === 'utf-8' || enc === undefined) {
      return new TextDecoder().decode(this);
    }
    if (enc === 'latin1' || enc === 'binary') {
      let s = '';
      for (let i = 0; i < this.length; i++) s += String.fromCharCode(this[i]);
      return s;
    }
    return new TextDecoder(enc).decode(this);
  }
}

export function randomBytes(n) {
  const out = new Uint8Array(n);
  const c = globalThis.crypto;
  if (c && typeof c.getRandomValues === 'function') {
    for (let off = 0; off < n; off += 65536) {
      c.getRandomValues(out.subarray(off, Math.min(n, off + 65536)));
    }
    return out;
  }
  for (let i = 0; i < n; i++) out[i] = Math.floor(Math.random() * 256);
  return out;
}
