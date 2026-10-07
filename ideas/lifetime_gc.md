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
`test/treeshake/minimal.y` fell from 3,120 to 440 bytes. A program that allocates but cannot
*grow* now leaves it out too: `--gc` (auto/always/never, default auto) stubs the
collector's three entry points in the arch module when no loop or recursion can
reach `y_alloc`, so the rest of the runtime goes unreachable and shakes out.
`let a = [1, 2, 3]; print(a[0]);` is 3,428 B with `--gc=always` and 1,312 B with
the default; `test/sh/test_treeshake.sh` gates auto/always/never and the corpus
still carries the collector.

`make ynew` (generations 2 and 3 byte-identical), `make cycc`,
`make port-check` and the heap fixtures `t101`/`t138`/`t139`
(byte-for-byte unchanged) all pass with the collector on, and every program
in `ideas/oom/` completes under a **256 MiB** cap (it needed 3.5 GB before,
or died).

### What is left

1. **Threads (done).** A spawned thread used to disable collection outright
   (`y_gc_collect` returned at `y_heap+24`), so a threaded program's memory grew
   with its work. It now stops the world:
   * the tcb (threads.s) is 112 bytes: `next`, `rsp`, `state` and the gc mark
     after the ten words the thread code uses, and the main thread's block is a
     tcb too, so the collector walks one list;
   * `y_gc_safepoint` parks a thread at the allocator's slow path, where every
     register is already pushed -- publishing `%rsp` publishes its roots.
     `y_spawn` goes through it before registering, and a thread takes the
     stop-the-world flag itself before unlinking on exit;
   * `y_gc_stw_begin` takes the flag with `xchg` and walks the list until every
     other thread is parked (state 1) or **blocked** (state 3, published by
     `y_gc_block_begin`/`_end` around the join/mutex/sem futex waits -- without
     that the common `spawn`+`join` shape stops the main thread in `join` and
     no cycle ever runs). The wait is bounded: a running thread may hold the
     only pointer to a live object in a register, so a timeout SKIPS the cycle;
   * the roots are each thread's own: `y_gc_roots` takes the current thread's
     stack top (its 8 MiB mapping; `y_gc_stack_top` for the main thread) and
     `y_gc_thread_roots` scans every other parked/blocked thread's
     `[published rsp, top)`;
   * `y_gc_maybe` measures the current thread's `used` against its tcb's mark,
     because the global heap block is empty once threads exist;
   * the allocation side is shared, so `y_gc_lk` guards the free lists and the
     chunk registry and `y_gc_mlk` guards the metadata arena (always in that
     order, and never held while parked -- the safepoint comes first).
   `test/sh/test_gc.sh` is the measurement: two threads of 300k allocations
   (~90 MB of garbage) inside a **64 MiB** cap, with `--gc=never` as the
   control, which does not fit. Scaled up, two threads of **2,000,000**
   allocations (~600 MB of garbage) still run in 64 MiB and print the same
   accumulators, while the pre-collector runtime runs out of memory at
   **256 MiB**. The floor is the per-thread trigger (`used - mark` reaching
   `max(live, 8 MiB)`) plus a chunk each, so four threads of 250k want ~96 MiB;
   tightening that is a tuning question, not a leak.

   One case the mode found is still open: `test/y/native/t160_threads.y` built
   with `--gc-stress` prints all of its output and *then* trips the collector's
   own `collector: bad block header` trap, so something a mutex-waiting thread
   holds is still reachable only from a register when a cycle sweeps. It
   reproduces in a second:

       ./ynew --gc-stress test/y/native/t160_threads.y -o /tmp/t && /tmp/t
       ./ynew -g --gc-stress test/y/native/t160_threads.y -o /tmp/tg
       gdb -batch -ex 'break y_bad_trap' -ex run -ex bt --args /tmp/tg

   The fixes already in: every blocking wait publishes the CALLER's `%rsp`
   (so the callee-saved registers its wrapper pushed are what the collector
   scans), the safepoint spills all six callee-saved registers, the futex
   waits carry a 100us timeout so a blocked thread comes back, sees the
   stop-the-world flag and PARKS, and the stop-the-world walk accepts only a
   real park (state 1) -- which is what `--gc-stress` showed was necessary.
   Everything else passes under stress: t341/t342/t343, the two-thread
   allocation shapes, and the cap test (two threads of 2,000,000 allocations
   in 64 MiB).

   What the trap says, from the gdb recipe above: at `y_bad_trap` the walk's
   chunk node (`%rbx`) reads correctly -- `{base, end, next}` for a 4 MiB chunk
   -- but the node its `next` names is filled with `0x5555555555555555`, i.e.
   live registry memory was overwritten (not a dangling pointer: both nodes are
   40 bytes apart in one arena segment, and the arena is rooted through
   `y_gc_meta_cur`). Nothing in the tree writes that pattern, so it is stale
   data from a bump write into the collector's metadata.

   What makes it fatal is the next observation: in a run where the trap fires,
   gdb can no longer read the program's own globals (`x/gx &y_gc_all` is
   "Cannot access memory at address 0x804080"), while an earlier run read them
   fine. The process has unmapped a range that covers its own `.bss`. The
   collector's only unmap is `ygc_sweep_big`, which trusts a dedicated flag in
   a block header, so it was handed a `{base, end}` that was never a dedicated
   mapping -- the corruption and the unmap are one failure seen twice.

   So the shape to chase is: a writer of descriptor or arena memory that can
   run while another thread sweeps, or a dedicated-block header that outlives
   the mapping it describes. Removing t160's fork section does not change the
   failure; removing the threads does.

   The registers at the trap point at the second half of that. The chunk being
   walked is a normal one full of 16-byte closure records (`{header=0x11,
   value=<code address>}` repeated), and the word the walk mistook for a header
   is `0x7ffff7600000` -- the chunk's own `end`, the value a bump allocator
   stores in a heap block's word 1. So the walk crossed from allocated blocks
   into a region where a *pointer* sits at a header offset. The one region that
   can look like that is a thread's bump tail: `y_alloc_more` sets a thread's
   `cur`/`end` (words 0/8 of its tcb) to `[base+size, base+4MiB)` but writes no
   header for that space, so pass1 and the sweep see free space there and
   coalesce it into the free lists while the thread still bumps into it. The
   main thread's tail is `y_heap` itself, which is why single-threaded
   collection never shows it. The candidate fix is to make the tail a real
   allocated block (header `size|1` at `cur`) when a chunk is taken, so the
   sweep keeps it while the tcb's `cur` points into it and frees it once the
   thread has moved on.

2. **Performance.** The byte buffers are pointer-free (`y_str_cat`,
   `y_str_app`, the join buffer, `ylts_mk`, `ycs_mk`, `y_bytes_to_str`): 61.9M
   -> 49.3M instructions on 120 live ~108 KB strings. Packed `[byte]` array data
   is marked in the five allocations a byte array grows through (90.9M -> 36.7M
   on 600 live 30 KB arrays), and for 8-byte elements the emitter marks the data
   block at a literal, a slice, `array + element`, `array + array` and
   `arr += other` when the element type is long/bool/float/byte (146.0M ->
   100.7M on 200 arrays of 12288 longs), and `range()` is marked (400 ranges of
   4000 longs: 127.1M -> 105.4M). `arr += x` is deliberately NOT marked -- five
   instructions per pushed element costs more than the scan it saves -- and
   `map`/`filter` results are left, because filter's closure returns bool while
   its result holds the source elements (`ideas/OPTIMIZE.md` A8).
   
3. Optional knobs: `--gc-stress` (collect on every slow path) is DONE, with
   `--no-gc` as an alias for `--gc=never`; both are checked by the `gc` suite.
   What is left of this item is nothing; and `--no-gc`,
   plus a `test/sh/test_gc.sh` suite that runs the corpus under a small cap.


## Round 19: two attempts on the --gc-stress trap, and where it actually is

Clamping the sweep's per-chunk walk to the lowest registered thread `cur` inside
that chunk (so a live bump tail is never free-listed) was implemented, measured
and reverted: it is principled, but `test/y/native/t160_threads.y` still traps
under `--gc-stress`, so it went back out rather than ship unproven.

The registers then say the trap is not in the sweep at all. At `y_bad_trap`,
`%r13` equals descriptor word 2, which is pass1's *map* pointer (`mov
16(%rbx),%r13`), and the word pass1 read as a header is a heap POINTER in the
chunk base/end range, not a size. A pointer sitting at a block boundary is what
a previously swept block looks like once the sweep's free-run bookkeeping has
been written into it. The likeliest reading is therefore a MISSED ROOT: the
sweep freed a block that was still live, and the next cycle's pass1 read the
bookkeeping as a header. The bump-tail hazard (free space with no header that
the owner still bumps into) is a second, separate thing, still open, and the
clamp above is the shape its fix should take.

## Round 20: the stress trap prints its state

`--gc-stress` builds now replace `y_bad_trap` as well as `y_gc_maybe`
(`arch_gc_stress_lines`), so the invariant failure prints the walking state
instead of just dying: chunk base, chunk end, the block pointer `%r12`, the word
it read as a header, then `%r13` (pass1's map) and its word. On t160_threads
that reads, in order:

    140465496129536    chunk base   0x7ffff5800000
    140465500323840    chunk end    0x7ffff5c00000
    140465496316344    block        base+0x2d9b8, 8-aligned
    140465500323840    "header"     == the chunk END
    140465463820528    %r13         the map (descriptor word 2)
    2594636358205046853 its word     bitmap bits

So the word where a header belongs is exactly the chunk's `end` -- the value a
thread's bump allocator stores in a tcb's word 1, and the only pointer-shaped
number a chunk-take writes. `y_gc_flush_run` itself writes a proper free-run
header (`mov %r15,(%r14)`, r15 = run size), so this is not the free list's own
bookkeeping: something wrote a heap-block `end` field into the middle of this
chunk. The chunk is one a thread is bump-allocating in (its `end` is this
chunk's end), which keeps the tail hypothesis alive as the place to look next,
with the reporting trap now in place to say which object is hit.

## Round 21: the map is not a map, and the spare-tail handoff is load-bearing

The reporting trap added in round 20 prints one more thing worth reading: the
word at pass1's map pointer (`%r13`, descriptor word 2) is
`6148914691236517205` = `0x5555555555555555`. pass1 *zeroes* that map at the
start of every chunk before setting a bit per block start (`ygp1_zmap`), so a
map that is all alternating bits is not a map this cycle wrote -- the
descriptor's map pointer does not point at a map it owns. Combined with the
"header" being the chunk's `end`, both fields of this descriptor disagree with
their own contents.

Also tried, and reverted: disabling the spare-tail handoff in `y_spawn` (the
`40(%rcx)` spare list that `y_join_code` fills) to see whether the tail is what
plants a heap-block `end` in the middle of a live chunk. The program then
produced no output at all, so the handoff is load-bearing and cannot simply be
bypassed: understanding it -- what `y_spawn` stores in the new tcb's words 0/8
from the spare entry -- is part of the fix, not an alternative to it.

## Round 22: the root cause -- y_join_done writes a chunk end into a live tail

Reading `y_join_done` (threads.s) explains the exact word the round-20 trap
prints. When a joined thread ends, the joining thread takes the finished
thread's unused chunk tail for its next spawn, and the old code recorded that
spare *in the tail itself*:

    mov %rax, 0(%rdi)      # rax = the finished thread's end, rdi = its cur
    mov %rdx, 8(%rdi)      # next spare
    mov %rdi, 40(%rcx)     # push the entry

`%rdi` is the tail's start -- a block boundary in the middle of a live chunk --
and the word written there is the chunk's **end**. pass1 stops a chunk at a
*zero* header, which is why an untouched tail is invisible; after a join the
first word is a pointer, so pass1 reads it as a header whose size runs past the
chunk and traps. That is the reported shape: block = `base+0x2d9b8`,
"header" = the chunk end. `y_spawn` later cleared those two words when it
claimed the spare, which is why the window is between a join and the next
spawn -- and why `--gc-stress`, with a cycle at every allocation, finds it.

The fix is to keep the spare bookkeeping out of the heap: put {tail start, tail
end} in the joining thread's tcb (it needs two more words, so a 128-byte tcb)
and write nothing into the chunk at all, leaving the zero header pass1 stops
at. A first attempt at exactly that regressed t160's *normal* run, and the two
reasons are worth writing down before retrying:

- a fresh tcb is 128 bytes now, so the spawn path must zero words 14/15 as well
  (the round-18 fix zeroes 0, 8, 88, 96, 104 only);
- the main thread's tcb is `y_heap`, a fixed bss block; if it is smaller than
  128 bytes, words 14/15 alias other globals, so the main thread needs either a
  larger `y_heap` or a separate side location for its spare.

## Round 24: the map is a map, and the spare was not the cause

Two corrections and one result, after the y_heap fix landed.

The map is fine. The `0x5555555555555555` read at pass1's map pointer is not
corruption: a chunk full of 16-byte blocks -- which is what the earlier dump of
this chunk showed, `{header=0x11, value=<code>}` repeated -- has a block start
every other bit, so 0x55 per byte is exactly the bitmap that walk builds. The
round-21 note that "the map is not a map" was wrong.

The spare is not (or not only) the cause. Re-applied the round-22 change (spare
{start, end} in the joining tcb's words 14/15, nothing written into the chunk),
with words 14/15 zeroed on a fresh tcb and y_heap now 128 bytes: t160_threads
under --gc-stress still trips the invariant trap, at a *different* block address
each run (base+32 this time, the chunk end before), and sometimes segfaults
instead. So the stray tail header is real but is not what pass1 is hitting, or
there is a second writer of the same shape.

State left behind: the y_heap/is-128 fix from round 23 stays; the spare change
is reverted again. The next attempt should make the trap print the *previous*
block's header too (the word at block-8), which distinguishes "the walk is
misaligned" from "one block's header was overwritten", and should run the trap
under four threads only (no mutex, no fork) to shrink the search.

## Round 25: the walk is aligned -- a header was overwritten

The trap now prints the block's two neighbours as well, and on the smallest
failing case (four threads, one mutex, no fork: t160's first two sections) they
read:

    chunk base    139800239669248
    chunk end     139800243863552   (base + 4 MiB)
    block         base + 159920    (16-byte aligned)
    word there    the chunk END    <-- where a header belongs
    word at -8    4200060          (0x40167c: a CODE address)
    word at +8    0

The word before the block is a closure record's code pointer, so pass1's walk
is *aligned* (it stepped block to block through the 16-byte closure records) and
the header slot of one block was overwritten with a thread's chunk end. That
retires the "misaligned walk" reading and puts the writers of a chunk `end` back
at the centre: `y_alloc_more`'s new-chunk words 0/1 and `y_join_done`'s spare
bookkeeping (round 22), both of which write [start, end) or `end` at a block
boundary. The round-24 attempt removed the join's write and still trapped (a
different address), so either a second writer of the same shape exists or the
live bump tail (round 19) is the second one -- both fixes are needed.

## Round 26: the spare change breaks the queue fixture

Re-applied the spare-in-tcb change on top of round 23's y_heap fix (128-byte
tcb, words 14/15 zeroed, {tail start, tail end} kept in the joining thread's
tcb, nothing written into the chunk). The allocation-thread fixtures pass
(t385, t389) and t160's normal run is correct, but
test/y/native/t343_threads_queue.y now *segfaults*, so the change is reverted
again rather than landed. The spare handoff is load-bearing in a way still not
understood: it decides which region a new thread bumps in, and the queue
fixture's threads allocate after spawn, so a wrong [cur, end) there is fatal
even though the tail write it removes was real. Two things to check next time:
whether the tail a joined thread leaves is still reachable by the collector
(it is not freed -- the walk stops at its zero header -- so with the write gone
the region is reserved forever), and whether a *fresh* thread's tcb words 14/15
are read before y_spawn's zeroing on every path (the fork path copies a tcb).
