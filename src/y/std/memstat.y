// memstat -- where a program's memory is: the Y heap's size, what the collector found live,
// and a walk of every block on it.
//
//   used()          bytes this thread's heap has handed out (the `heap_used()` builtin)
//   mapped()        bytes of address space the allocator has mapped (4 MB chunks, or one per large block)
//   live()          bytes the last collection found reachable (0 before the first cycle)
//   since_gc()      bytes handed out since that cycle (main heap)
//   gc_trigger()    how many bytes may be handed out between cycles: 2.5 times the live size, at least 12 MiB
//   census()        a walk of every block: counts and bytes by state and by size class (the C_* indexes)
//   report()        the same, as text
//   rss_kb()        resident memory as the OS reports it, or -1 (Linux: /proc/self/statm)
//
// `used` counts block sizes as the allocator hands them out; `mapped` is what the OS was asked for, so
// `mapped - used` is the room not yet handed out plus what the collector has recycled. A program whose
// `used` keeps growing between collections is not leaking: the collector runs when `since_gc` reaches
// `gc_trigger`, and a freed block is reused, never returned, so `mapped` settles near the peak.
//
// The walk reads the allocator's own structures (arch/prelude.s: a chunk is {base, end, bitmap, next,
// dedicated}; a block starts with a header word, its size in the high bits and flags 1 allocated, 2 marked,
// 4 pointer-free, and a zero header ends a chunk's used part), so call it from one thread, between
// allocations -- it allocates only its result.
ndef y_mem_gc_all() -> long = "y_mem_gc_all";
ndef y_mem_gc_live() -> long = "y_mem_gc_live";
ndef y_mem_gc_last() -> long = "y_mem_gc_last";

/** census() indexes. */
const C_CHUNKS = 0;
const C_MAPPED = 1;
const C_LIVE_BLOCKS = 2;
const C_LIVE_BYTES = 3;
const C_PF_BYTES = 4;
const C_FREE_BLOCKS = 5;
const C_FREE_BYTES = 6;
const C_TAIL_BYTES = 7;
const C_LARGEST = 8;
/** From here, a (blocks, bytes) pair per size class: up to 32 B, 64, 128, 256, 512, 1 KiB, 4 KiB, 16 KiB, 64 KiB, larger. */
const C_CLASS0 = 16;
const NCLASS = 10;

def used() -> long { heap_used() };

def rd(a: long) -> long {
    let q: *long = ptr_from(a);
    *q
};

/** The chunk descriptors' base, end and dedicated flag, newest first: the number of chunks. */
def chunk_count() -> long {
    let n = 0;
    let c = y_mem_gc_all();
    while (c != 0) {
        n = n + 1;
        c = rd(c + 24);
    };
    n
};

def mapped() -> long {
    let n = 0;
    let c = y_mem_gc_all();
    while (c != 0) {
        n = n + rd(c + 8) - rd(c);
        c = rd(c + 24);
    };
    n
};

def live() -> long { y_mem_gc_live() };

def since_gc() -> long { heap_used() - y_mem_gc_last() };

def gc_trigger() -> long {
    let l = y_mem_gc_live();
    let t = l + l + l / 2;
    if (t < 12582912) { t = 12582912; };
    t
};

def class_of(size: long) -> long {
    if (size <= 32) { return 0; };
    if (size <= 64) { return 1; };
    if (size <= 128) { return 2; };
    if (size <= 256) { return 3; };
    if (size <= 512) { return 4; };
    if (size <= 1024) { return 5; };
    if (size <= 4096) { return 6; };
    if (size <= 16384) { return 7; };
    if (size <= 65536) { return 8; };
    9
};

def census() -> [long] {
    let r: [long] = [0; 36];
    let c = y_mem_gc_all();
    while (c != 0) {
        let base = rd(c);
        let end = rd(c + 8);
        r[C_CHUNKS] = r[C_CHUNKS] + 1;
        r[C_MAPPED] = r[C_MAPPED] + end - base;
        let p = base;
        let go = true;
        while (go && p < end) {
            let h = rd(p);
            let size = h & -8;
            if (h == 0 || size < 16 || p + size > end) {
                go = false;
            } else {
                if ((h & 1) != 0) {
                    r[C_LIVE_BLOCKS] = r[C_LIVE_BLOCKS] + 1;
                    r[C_LIVE_BYTES] = r[C_LIVE_BYTES] + size;
                    if ((h & 4) != 0) { r[C_PF_BYTES] = r[C_PF_BYTES] + size; };
                    if (size > r[C_LARGEST]) { r[C_LARGEST] = size; };
                    let k = C_CLASS0 + 2 * class_of(size);
                    r[k] = r[k] + 1;
                    r[k + 1] = r[k + 1] + size;
                } else {
                    r[C_FREE_BLOCKS] = r[C_FREE_BLOCKS] + 1;
                    r[C_FREE_BYTES] = r[C_FREE_BYTES] + size;
                };
                p = p + size;
            };
        };
        r[C_TAIL_BYTES] = r[C_TAIL_BYTES] + end - p;
        c = rd(c + 24);
    };
    r
};

def kib(n: long) -> str {
    if (n < 1024) { return tostring(n) + " B"; };
    if (n < 1048576) { return tostring(n / 1024) + "." + tostring(n * 10 / 1024 % 10) + " KiB"; };
    tostring(n / 1048576) + "." + tostring(n * 10 / 1048576 % 10) + " MiB"
};

def class_name(k: long) -> str {
    if (k == 0) { return "<= 32 B"; };
    if (k == 1) { return "<= 64 B"; };
    if (k == 2) { return "<= 128 B"; };
    if (k == 3) { return "<= 256 B"; };
    if (k == 4) { return "<= 512 B"; };
    if (k == 5) { return "<= 1 KiB"; };
    if (k == 6) { return "<= 4 KiB"; };
    if (k == 7) { return "<= 16 KiB"; };
    if (k == 8) { return "<= 64 KiB"; };
    "larger"
};

/** The heap as text: sizes, the collector's state, and the live blocks by size class. */
def report() -> str {
    let r = census();
    let s = "heap: " + kib(heap_used()) + " handed out, " + kib(mapped()) + " mapped in " + tostring(r[C_CHUNKS]) + " chunks\n";
    s += "gc: " + kib(y_mem_gc_live()) + " live after the last cycle, " + kib(since_gc()) + " since, next at " + kib(gc_trigger()) + "\n";
    s += "blocks: " + tostring(r[C_LIVE_BLOCKS]) + " live (" + kib(r[C_LIVE_BYTES]) + ", " + kib(r[C_PF_BYTES]) + " pointer-free), ";
    s += tostring(r[C_FREE_BLOCKS]) + " free (" + kib(r[C_FREE_BYTES]) + "), " + kib(r[C_TAIL_BYTES]) + " never used, largest " + kib(r[C_LARGEST]) + "\n";
    let k = 0;
    while (k < NCLASS) {
        let n = r[C_CLASS0 + 2 * k];
        if (n > 0) { s += "  " + class_name(k) + ": " + tostring(n) + " blocks, " + kib(r[C_CLASS0 + 2 * k + 1]) + "\n"; };
        k = k + 1;
    };
    s
};

/** Resident memory in KiB, from /proc/self/statm where there is one; -1 otherwise. */
def rss_kb() -> long {
    let path = "/proc/self/statm";
    let fd = os_call("y_os_openat", -100, path, len(path), 524288, 0);
    if (fd < 0) { return 0 - 1; };
    let b: [byte] = [0; 128];
    let n = os_call("y_os_read", fd, &b[0], 127);
    os_call("y_os_close", fd);
    if (n <= 0) { return 0 - 1; };
    // "size resident shared ..." in pages: the second number
    let i = 0;
    while (i < n && b[i] != 32) { i = i + 1; };
    i = i + 1;
    let v = 0;
    while (i < n && b[i] >= 48 && b[i] <= 57) {
        v = v * 10 + b[i] - 48;
        i = i + 1;
    };
    v * 4
};
