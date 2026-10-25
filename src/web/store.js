// src/web/store.js — persistent /home/web for the browser host.
//
// The database is yweb:<id>; one object store 'files' keyed by absolute path
// holds {kind, mode, data, target, uid, gid, mtimeMs}.  The page loads every
// record before the program starts, attaches the Store to memfs.js, and
// memfs.js queues changed paths.  Writes are batched into one transaction at a
// time, in queue order, so a rename and the writes before it cannot reorder.
//
// When IndexedDB is missing (some private modes) available is false and the
// page shows that saves will not persist; the in-memory tree still works.

export class Store {
  constructor(opts = {}) {
    this.id = String(opts.id || 'default');
    this.name = 'yweb:' + this.id;
    this.db = null;
    this.available = typeof indexedDB !== 'undefined';
    this.memfs = null;
    this.queue = new Set();
    this.timer = null;
    this.chain = Promise.resolve();
    this.error = null;
  }

  attach(memfs) {
    this.memfs = memfs;
  }

  async open() {
    if (!this.available) return false;
    try {
      this.db = await new Promise((resolve, reject) => {
        const req = indexedDB.open(this.name, 1);
        req.onupgradeneeded = () => {
          const db = req.result;
          if (!db.objectStoreNames.contains('files')) db.createObjectStore('files');
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error || new Error('IndexedDB open failed'));
        req.onblocked = () => reject(new Error('IndexedDB open blocked'));
      });
      return true;
    } catch (e) {
      this.error = e && e.message ? e.message : String(e);
      this.available = false;
      return false;
    }
  }

  // Every record as Map<path, record>; an empty Map when storage is absent.
  async load() {
    const out = new Map();
    if (!this.available || !this.db) return out;
    try {
      const keys = await new Promise((resolve, reject) => {
        const tx = this.db.transaction('files', 'readonly');
        const req = tx.objectStore('files').getAllKeys();
        req.onsuccess = () => resolve(req.result || []);
        req.onerror = () => reject(req.error);
      });
      if (keys.length === 0) return out;
      const values = await new Promise((resolve, reject) => {
        const tx = this.db.transaction('files', 'readonly');
        const store = tx.objectStore('files');
        const got = new Map();
        let left = keys.length;
        for (const key of keys) {
          const req = store.get(key);
          req.onsuccess = () => {
            got.set(String(key), req.result);
            if (--left === 0) resolve(got);
          };
          req.onerror = () => reject(req.error);
        }
      });
      for (const [path, rec] of values) {
        if (!rec) continue;
        if (rec.kind === 'file' && rec.data) {
          rec.data = rec.data instanceof Uint8Array ? rec.data : new Uint8Array(rec.data);
        }
        out.set(path, rec);
      }
      return out;
    } catch (e) {
      this.error = e && e.message ? e.message : String(e);
      return out;
    }
  }

  changed(path) {
    if (!this.available || !this.db) return;
    this.queue.add(path);
    this.flushSoon();
  }

  flushSoon() {
    if (!this.available || !this.db || this.timer !== null) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.flush().catch((e) => { this.error = e && e.message ? e.message : String(e); });
    }, 60);
  }

  // Queue one transaction with the current value of every queued path.
  flush() {
    const run = async () => {
      if (!this.available || !this.db || !this.memfs) return;
      const paths = [...this.queue];
      this.queue.clear();
      if (paths.length === 0) return;
      const records = [];
      for (const path of paths) records.push([path, this.memfs.record(path)]);
      await new Promise((resolve, reject) => {
        const tx = this.db.transaction('files', 'readwrite');
        const store = tx.objectStore('files');
        for (const [path, rec] of records) {
          if (rec === null) store.delete(path);
          else store.put(rec, path);
        }
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error || new Error('IndexedDB write failed'));
        tx.onabort = () => reject(tx.error || new Error('IndexedDB transaction aborted'));
      });
    };
    this.chain = this.chain.then(run, run);
    return this.chain;
  }
}
