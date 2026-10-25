// mm -- user memory: mmap/munmap/mprotect/brk/madvise, getrandom, and the page-fault
// handler that gives the regions their pages.
//
// Besides the common interface it exports mm_ok, mm_touch and a few more helpers.
//
// An address space (kernel.task_cr3) has a SPACE here: a sorted list of regions
// (VMAs: [lo, hi) page aligned, prot) plus the program break.  Threads share their
// leader's space (thread.thread_shares_mm); fork copies it; exec starts a fresh
// one.  Nothing is mapped eagerly: `y_kernel_pf` (which replaces std/kernel.y's,
// a program's `y_` def wins at link time) gives a zeroed page the first time a
// page inside a region with prot != 0 is touched -- by the program or by the
// kernel on its behalf.  munmap really unmaps: the pages go back to
// kernel.page_free, and the region list is cut.
//
// Layout (per space): the image at 0x400000 (loaded eagerly by the loader), the
// break from 64 MB up to 88 MB, the stack's growth area 88..96 MB (the loader maps
// the top 64 KB at 96 MB), the mmap area from 256 MB up to 4 TB, first fit.
//
// mprotect only changes the region's prot (PROT_NONE refuses faults); the PTEs
// stay read-write, there is no copy-on-write and no file mapping.
import kernel;
import kconst from "./kconst.y";
import thread from "./thread.y";
import kstat from "./kstat.y";

type Vma = { lo: long, hi: long, prot: long };
type Space = { vmas: [Vma], brk0: long, brk: long, refs: long };

const MM_BASE = 268435456;           // 256 MB: the mmap area
const MM_TOP = 4398046511104;        // 4 TB
const MM_BRK0 = 67108864;            // 64 MB: the break starts here
const MM_BRK_MAX = 92274688;         // 88 MB: and may not pass this
const MM_STACK_LO = 92274688;        // 88 MB .. 96 MB grows down from the loader's stack
const MM_STACK_HI = 100663296;
const MM_USER_MIN = 65536;
const MM_PAGE = 4096;
const MM_MAP_FIXED = 16;
const MM_MAP_ANON = 32;

let mm_spaces: [Space] = [];
let mm_sp: [long] = [];             // per task slot: index into mm_spaces, -1 none yet
let mm_rng = 0;

def mm_new_space() -> long {
    let st: [Vma] = [];
    let stack: Vma = { lo: MM_STACK_LO, hi: MM_STACK_HI - 65536, prot: 3 };
    st += stack;
    let sp: Space = { vmas: st, brk0: MM_BRK0, brk: MM_BRK0, refs: 1 };
    mm_spaces += sp;
    len(mm_spaces) - 1
};

/** The space index of task `slot`, made on first use (the boot task never forked). */
def mm_space_of(slot: long) -> long {
    while (len(mm_sp) <= slot) { mm_sp += 0 - 1; };
    if (mm_sp[slot] < 0) { mm_sp[slot] = mm_new_space(); };
    mm_sp[slot]
};

def mm_copy_vmas(src: [Vma]) -> [Vma] {
    let out: [Vma] = [];
    foreach (v in src) {
        let c: Vma = { lo: v.lo, hi: v.hi, prot: v.prot };
        out += c;
    };
    out
};

def mm_on_fork(parent: long, child: long) -> void {
    let ps = mm_space_of(parent);
    while (len(mm_sp) <= child) { mm_sp += 0 - 1; };
    if (thread.thread_shares_mm(child)) {
        mm_sp[child] = ps;
        mm_spaces[ps].refs = mm_spaces[ps].refs + 1;
    } else {
        let sp: Space = { vmas: mm_copy_vmas(mm_spaces[ps].vmas), brk0: mm_spaces[ps].brk0, brk: mm_spaces[ps].brk, refs: 1 };
        mm_spaces += sp;
        mm_sp[child] = len(mm_spaces) - 1;
    };
};

def mm_release(slot: long) -> void {
    if (slot < len(mm_sp) && mm_sp[slot] >= 0) {
        let i = mm_sp[slot];
        mm_spaces[i].refs = mm_spaces[i].refs - 1;
        if (mm_spaces[i].refs <= 0) { mm_spaces[i].vmas = []; };
    };
};

def mm_on_exec(slot: long) -> void {
    mm_release(slot);
    while (len(mm_sp) <= slot) { mm_sp += 0 - 1; };
    mm_sp[slot] = mm_new_space();
};

def mm_on_exit(slot: long) -> void {
    // The slot keeps its index: a doomed thread may still fault for a moment
    // (y_kernel_pf); the regions go when the last sharer is gone.
    mm_release(slot);
};

// ── regions ─────────────────────────────────────────────────────────────
def mm_round(n: long) -> long { (n + 4095) & (0 - 4096) };

/** Index of the region of space `s` that holds `addr`, or -1. */
def mm_find(s: long, addr: long) -> long {
    let i = 0;
    let n = len(mm_spaces[s].vmas);
    while (i < n) {
        let v: Vma = mm_spaces[s].vmas[i];
        if (addr >= v.lo && addr < v.hi) { return i; };
        i = i + 1;
    };
    0 - 1
};

/** Does any region of space `s` intersect [lo, hi)? */
def mm_overlaps(s: long, lo: long, hi: long) -> bool {
    let hit = false;
    foreach (v in mm_spaces[s].vmas) {
        if (v.lo < hi && v.hi > lo) { hit = true; };
    };
    hit
};

/** First fit in the mmap area for `size` bytes, or 0. */
def mm_gap(s: long, size: long) -> long {
    let at = MM_BASE;
    foreach (v in mm_spaces[s].vmas) {
        if (v.hi > MM_BASE && v.lo < at + size && v.hi > at) { at = v.hi; };
    };
    if (at + size > MM_TOP) { 0 } else { at }
};

/** Cut [lo, hi) out of the regions of space `s` (splitting at the edges). */
def mm_cut(s: long, lo: long, hi: long) -> void {
    let out: [Vma] = [];
    foreach (v in mm_spaces[s].vmas) {
        if (v.hi <= lo || v.lo >= hi) {
            out += v;
        } else {
            if (v.lo < lo) {
                let a: Vma = { lo: v.lo, hi: lo, prot: v.prot };
                out += a;
            };
            if (v.hi > hi) {
                let b: Vma = { lo: hi, hi: v.hi, prot: v.prot };
                out += b;
            };
        };
    };
    mm_spaces[s].vmas = out;
};

/** Add [lo, hi) with `prot` (no overlap), keeping the list sorted and merged. */
def mm_add(s: long, lo: long, hi: long, prot: long) -> void {
    let nv: Vma = { lo: lo, hi: hi, prot: prot };
    let out: [Vma] = [];
    let done = false;
    foreach (v in mm_spaces[s].vmas) {
        if (!done && v.lo >= hi) { out += nv; done = true; };
        out += v;
    };
    if (!done) { out += nv; };
    let merged: [Vma] = [];
    foreach (v in out) {
        let k = len(merged) - 1;
        if (k >= 0 && merged[k].hi == v.lo && merged[k].prot == v.prot) {
            let m: Vma = { lo: merged[k].lo, hi: v.hi, prot: v.prot };
            merged[k] = m;
        } else {
            merged += v;
        };
    };
    mm_spaces[s].vmas = merged;
};

/** Give the pages of [lo, hi) back (page-table entries cleared, frames freed). */
def mm_free_pages(dir: long, lo: long, hi: long) -> void {
    let v = lo;
    while (v < hi) {
        let slot = kernel.vm_slot(dir, v, false, false);
        if (slot == 0) {
            v = (v | 2097151) + 1;
        } else {
            let stop = (v | 2097151) + 1;
            if (stop > hi) { stop = hi; };
            while (v < stop) {
                let e = kernel.peek64(slot);
                if ((e & kernel.PTE_P) != 0 && (e & kernel.PTE_U) != 0) {
                    kernel.page_free(e & kernel.PHYS_MASK);
                    kernel.poke64(slot, 0);
                    kernel.vm_flush(v);
                };
                slot = slot + 8;
                v = v + MM_PAGE;
            };
        };
    };
};

// ── what other modules need ─────────────────────────────────────────────
/** Is the page holding `va` mapped (or mappable by a fault) in task `slot`'s
 *  space?  Maps it when it is only mappable. */
def mm_touch(slot: long, va: long) -> bool {
    if (va < 4194304 || va >= kernel.USER_LIMIT) { return false; };
    let dir = kernel.task_cr3(slot);
    if (kernel.vm_translate(dir, va) != 0) { return true; };
    let s = mm_space_of(slot);
    let i = mm_find(s, va);
    if (i < 0) { return false; };
    let v: Vma = mm_spaces[s].vmas[i];
    if (v.prot == 0) { return false; };
    let page = kernel.page_alloc();
    if (page == 0) { return false; };
    kernel.vm_map(dir, va & (0 - 4096), page, kernel.PTE_U | kernel.PTE_W)
};

/** May the kernel touch [addr, addr+n) of task `slot`'s space?  Every page is
 *  mapped, or inside a readable region (then it is mapped now). */
def mm_ok_for(slot: long, addr: long, n: long) -> bool {
    if (!kernel.user_ok(addr, n)) { return false; };
    if (n == 0) { return true; };
    let p = addr & (0 - 4096);
    let end = addr + n;
    let good = true;
    while (good && p < end) {
        if (!mm_touch(slot, p)) { good = false; };
        p = p + MM_PAGE;
    };
    good
};

/** mm_ok_for the running task. */
def mm_ok(addr: long, n: long) -> bool { mm_ok_for(kernel.task_slot(), addr, n) };

/** The physical address behind `va` in task `slot`'s space (mapped on demand), or 0. */
def mm_phys(slot: long, va: long) -> long {
    if (!mm_touch(slot, va)) { return 0; };
    kernel.vm_translate(kernel.task_cr3(slot), va)
};

// ── the page-fault handler ──────────────────────────────────────────────
/** Called by the trap stub first for a #PF: nonzero when mended (a page of a
 *  region is mapped and the instruction retried). */
def y_kernel_pf(err: long, addr: long) -> long {
    kstat.kstat_fault();
    if ((err & 1) != 0) { return 0; };
    if (addr < 4194304 || addr >= kernel.USER_LIMIT) { return 0; };
    let slot = kernel.task_slot();
    let st = kernel.task_state(slot);
    if (st == kernel.TASK_DEAD || st == kernel.TASK_REAPED) {
        // a doomed thread running its last instructions on a space that is going
        // away: any page will do
        let junk = kernel.page_alloc();
        if (junk == 0) { return 0; };
        if (!kernel.vm_map(kernel.vm_current(), addr & (0 - 4096), junk, kernel.PTE_U | kernel.PTE_W)) { return 0; };
        return 1;
    };
    if (mm_touch(slot, addr)) { 1 } else { 0 }
};

// ── syscalls ────────────────────────────────────────────────────────────
def sys_mmap(addr: long, size: long, prot: long, flags: long, fd: long, off: long) -> long {
    if (size <= 0 || size > 17179869184) { return kconst.EINVAL; };
    if ((flags & MM_MAP_ANON) == 0) { return kconst.ENODEV; };
    let slot = kernel.task_slot();
    let s = mm_space_of(slot);
    let want = mm_round(size);
    let at = 0;
    if ((flags & MM_MAP_FIXED) != 0) {
        if ((addr & 4095) != 0 || addr < MM_USER_MIN || addr + want > kernel.USER_LIMIT) { return kconst.EINVAL; };
        at = addr;
        mm_free_pages(kernel.task_cr3(slot), at, at + want);
        mm_cut(s, at, at + want);
    } else {
        if (addr != 0 && (addr & 4095) == 0 && addr >= MM_BASE && addr + want <= MM_TOP && !mm_overlaps(s, addr, addr + want)) {
            at = addr;
        } else {
            at = mm_gap(s, want);
        };
        if (at == 0) { return kconst.ENOMEM; };
    };
    mm_add(s, at, at + want, prot & 7);
    at
};

def sys_munmap(addr: long, size: long) -> long {
    if ((addr & 4095) != 0 || size <= 0 || addr < MM_USER_MIN) { return kconst.EINVAL; };
    let want = mm_round(size);
    if (addr + want > kernel.USER_LIMIT) { return kconst.EINVAL; };
    let slot = kernel.task_slot();
    mm_free_pages(kernel.task_cr3(slot), addr, addr + want);
    mm_cut(mm_space_of(slot), addr, addr + want);
    0
};

def sys_mprotect(addr: long, size: long, prot: long) -> long {
    if ((addr & 4095) != 0) { return kconst.EINVAL; };
    if (size == 0) { return 0; };
    let want = mm_round(size);
    let s = mm_space_of(kernel.task_slot());
    // the covered parts take the new prot; a hole in the range is ENOMEM
    let lo = addr;
    let hi = addr + want;
    let covered = 0;
    let pieces: [Vma] = [];
    foreach (v in mm_spaces[s].vmas) {
        if (v.lo < hi && v.hi > lo) {
            let a = v.lo;
            if (a < lo) { a = lo; };
            let b = v.hi;
            if (b > hi) { b = hi; };
            covered = covered + (b - a);
            let p: Vma = { lo: a, hi: b, prot: prot & 7 };
            pieces += p;
        };
    };
    foreach (p in pieces) {
        mm_cut(s, p.lo, p.hi);
        mm_add(s, p.lo, p.hi, p.prot);
    };
    if (covered < want) { kconst.ENOMEM } else { 0 }
};

def sys_brk(addr: long) -> long {
    let slot = kernel.task_slot();
    let s = mm_space_of(slot);
    let cur = mm_spaces[s].brk;
    if (addr == 0 || addr < mm_spaces[s].brk0 || addr > MM_BRK_MAX) { return cur; };
    let old_end = mm_round(cur);
    let new_end = mm_round(addr);
    if (new_end > old_end) {
        if (mm_overlaps(s, old_end, new_end)) { return cur; };
        mm_add(s, old_end, new_end, 3);
    } else if (new_end < old_end) {
        mm_free_pages(kernel.task_cr3(slot), new_end, old_end);
        mm_cut(s, new_end, old_end);
    };
    mm_spaces[s].brk = addr;
    addr
};

def sys_mremap(old: long, oldlen: long, newlen: long, flags: long, newaddr: long) -> long { kconst.ENOSYS };

def sys_madvise(addr: long, size: long, advice: long) -> long {
    if ((addr & 4095) != 0) { return kconst.EINVAL; };
    // DONTNEED (4) and FREE (8): the pages go, the next touch is zeros again
    if ((advice == 4 || advice == 8) && size > 0 && addr >= MM_USER_MIN && addr + size <= kernel.USER_LIMIT) {
        let slot = kernel.task_slot();
        let s = mm_space_of(slot);
        // only inside anonymous regions
        let lo = addr;
        let hi = addr + mm_round(size);
        foreach (v in mm_spaces[s].vmas) {
            if (v.lo < hi && v.hi > lo) {
                let a = v.lo;
                if (a < lo) { a = lo; };
                let b = v.hi;
                if (b > hi) { b = hi; };
                mm_free_pages(kernel.task_cr3(slot), a, b);
            };
        };
    };
    0
};

/** xorshift64*, reseeded from the TSC on every call. */
def mm_random() -> long {
    if (mm_rng == 0) { mm_rng = 88172645463325252; };
    mm_rng = mm_rng ^ kernel.rdtsc();
    mm_rng = mm_rng ^ (mm_rng << 13);
    mm_rng = mm_rng ^ (mm_rng >>> 7);
    mm_rng = mm_rng ^ (mm_rng << 17);
    mm_rng * 2685821657736338717
};

def sys_getrandom(buf: long, size: long, flags: long) -> long {
    if (size < 0) { return kconst.EINVAL; };
    if (size == 0) { return 0; };
    let n = size;
    if (n > 1048576) { n = 1048576; };
    if (!mm_ok(buf, n)) { return kconst.EFAULT; };
    let i = 0;
    while (i + 8 <= n) {
        kernel.poke_va64(buf + i, mm_random());
        i = i + 8;
    };
    if (i < n) {
        let r = mm_random();
        while (i < n) {
            kernel.poke_va8(buf + i, r);
            r = r >>> 8;
            i = i + 1;
        };
    };
    n
};
