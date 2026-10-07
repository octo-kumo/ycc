# Lifetime tracking and GC — design notes

Goal: heap usage must not grow with loop iterations while keeping Y's
reference semantics. The pragmatic design is two-tiered.

## 1. Static lifetime: block arenas for non-escaping values

An allocation literal (`{...}`, `[...]`, `some(...)`, a capture cell, an
anonymous closure) is *local* when a whole-function escape analysis proves
it cannot outlive the block that created it. The analysis marks a binding
escaped when it is returned, passed to an unknown call, stored through an
assignment/field/index/global, captured by a closure, or has its address
taken; reads (`a[i]`, `a.f`, `len(a)`) do not escape.

Local allocations go through `y_arena_alloc` instead of `y_alloc`. A block
that owns any local allocation does `y_arena_enter` on entry and
`y_arena_leave` on every exit path (normal, `break`, `continue`, `return`).
The arena is a second bump pointer over the existing mmap chunks, so
`y_arena_leave` is O(1) and reclaims every local value from that block at
once. Escaping values keep using the general heap, so no object is ever
freed while a reference can still reach it.

## 2. Dynamic GC: closures and other untrackable graphs

Closure records and capture cells are deliberately not arena-allocated:
they can form cycles and can be shared by a closure that escapes the block
that created the cell. They carry a small object header
`{size, next, mark}`; every tracked allocation is threaded onto a list.

A collection is triggered when tracked bytes cross a threshold:

1. Save all GPRs on the stack and scan the stack, `.bss`, and any live
   thread roots conservatively. An address word is a root if it lies in an
   object payload range; interior pointers (`p + i`) are handled by a
   sorted-start lookup or a page/bitmap range check.
2. Mark transitively over every tracked payload word. Normal heap values
   are opaque to this collector — they are freed only by their own arena
   or by the general collector, not by the closure collector.
3. Sweep unmarked tracked blocks onto a size-segregated free list; reuse
   them before touching the bump pointer.

The closure collector is deliberately conservative; false retention is
allowed, dangling is not. A full collector over all heap values can be
added later by giving every `y_alloc` object the same header and replacing
the tracked list with the complete object list.

## Status

Pointer arithmetic (`p +/- n`, `n + p`, `p - q`, `+=`, `-=`, `++`, `--`)
is implemented on branch `mem-lifetime` in commit `ee66a02`; it is the
address-level primitive the closure collector needs to walk object graphs.

`ideas/oom/` is the acceptance corpus for those passes: small programs that
are ordinary code in a GC language but grow the Y heap every iteration (and
the flat controls that must stay flat). See its `README.md` for the measured
per-iteration costs and OOM points.

### What has landed

The collector is built as a **whole-heap, non-moving, conservative
mark-sweep** over every `y_alloc` block, not the two-tier design above:
tier 1 (arenas) cannot reclaim the old value in `s = s + t`, because the
binding is loop-carried, so it fixes none of the corpus's quadratic cases;
tier 2 restricted to closures is too narrow. One collector over all blocks
fixes both, and the arena becomes an optional performance tier.

**Phase 0 is in the tree and gated** (`make ynew`, `make cycc`,
`make port-check`, `make check`, the heap fixtures `t101`/`t138`/`t139`
byte-for-byte unchanged):

* every block carries an **8-byte header** at its (8-byte-aligned) base:
  the block size in the high bits and three flags in the low three (1
  allocated, 2 marked, 4 pointer-free);
* the header costs nothing: the allocator used to hand out `(n+15)&-8`
  bytes, whose last 8 were spare room for the word-at-a-time copy loops, and
  the payload is now that minus 8. The word-at-a-time copy loops need
  `ceil(n/8)*8`, which the shrunk payload still covers exactly, so nothing
  over-writes the next header; `used` and therefore `heap_used()` are
  byte-for-byte what they were;
* `_start` records the entry stack top in `y_gc_stack_top` (the emitter's
  prologue, native.y/native.c), and the assembler synthesises `y_bss_lo` /
  `y_bss_hi` around the writable data (asm.y/asm.c), so the collector has a
  stack and a global root range;
* the array header is now 32 bytes **in the request**: its fourth word
  (`front`, for `*=`) had been living in the allocator's spare, which the
  header takes over.

**Phase 1 is in the tree and gated.** `src/y/arch/prelude.s` carries the
whole collector: a metadata arena, a chunk registry with a window hash and a
one-bit-per-8-bytes block-start map, conservative roots (stack + `y_bss` +
every GPR `y_alloc_more` pushes), mark/sweep, coalescing free runs split
largest-first, and `munmap` of unmarked dedicated large blocks.

* **the trigger** is `used - y_gc_last >= max(y_gc_live, 8 MiB)` and is
  tested only in the allocator's slow path, so a cycle always starts at a
  point where every live value is on the stack or in a saved register;
* **the sweep rebuilds the free lists from the walk** every cycle. That is
  not an optimisation but a correctness rule: a run that is on a list and
  later coalesced into a bigger one would otherwise stay reachable through
  its old class slot, and a pop would hand out memory inside the new run;
* **the block-start map is cleared and rebuilt** each cycle, for the same
  reason -- a stale bit at an interior address resolves a candidate to the
  middle of a run and *shadows* the real block, so a live object could go
  unmarked;
* **a chunk that has been `munmap`ped is tombstoned (`base = 0`)** and both
  the resolver and the sweep skip it.

**Linkage.** The collector is linked only when something reaches `y_alloc`, and
that is now a real gate rather than a formality: `link_units` drops the
initializer range of a global cell no kept body reads, and that includes a
**std** unit's cells (rt.y's `CLK_TS` was `[0; 2]`, and its startup allocation
was the only thing naming `y_alloc` in a hello world). A program that never
allocates therefore carries neither the allocator nor the collector --
`bench/y/hello.y` is 390 bytes, and `test/sh/test_treeshake.sh` fails if a
`y_alloc` call or a `collector:` string comes back. `print(<integer>)` formats
into a stack buffer too (`y_print_long` -> arch `y_os_print_int`, through the
checker's named `os_call` layer so the documented override still works), so
`test/treeshake/minimal.y` fell from 3,120 to 440 bytes. What still carries the
collector is a program that really allocates -- an array, a string, a float
`tostring` -- where it is needed; the `--gc` switch for a provably bounded
program is the next item below.

`make ynew` (generations 2 and 3 byte-identical), `make cycc`,
`make port-check` and the heap fixtures `t101`/`t138`/`t139`
(byte-for-byte unchanged) all pass with the collector on, and every program
in `ideas/oom/` completes under a **256 MiB** cap (it needed 3.5 GB before,
or died).

### What is left

1. **Threads.** A cycle is only safe while one thread runs; `y_gc_collect`
   returns immediately once `y_heap+24` (the spawned-a-thread flag) is set,
   so a threaded program still leaks. The plan: stop-the-world at the
   allocator's slow path (the one place a thread can be parked) and scan
   each thread's stack from its own control block.
2. **Performance.** Strings and primitive arrays are scanned word by word
   even though they cannot hold a reference. `y_alloc_pf` exists for
   this (`bit 2` = pointer-free, the drain skips such payloads) but no call
   site uses it yet: `y_str_cat`/`y_str_app`/`y_str_repeat` buffers and
   `[byte]`/`[long]`/`[float]` array data are the conversions that matter.
3. Optional knobs: `--gc-stress` (collect on every slow path) and `--no-gc`,
   plus a `test/sh/test_gc.sh` suite that runs the corpus under a small cap.

