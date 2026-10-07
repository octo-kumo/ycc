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
The arena and collector passes are not implemented yet.
