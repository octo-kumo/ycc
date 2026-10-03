// std/rt.y — the runtime library, written in Y.
//
// This file holds the BEHAVIOUR that used to be hand-written x86 in
// arch_x64.y: number formatting, the print/put/eput family, string
// searching/parsing, time, files. native.y embeds its text (`embed RT_SRC
// from "./std/rt.y";` — the shipped ycc is a standalone static ELF and
// cannot read support files at run time) and splices it in front of every
// program; tree shaking (prune_bodies) drops the defs a program never
// calls. arch_x64.y keeps only the primitives that need raw memory: the
// allocator, the traps, dynamic record lookup (y_rec_has / y_dot_lookup),
// the byte-moving string/array cores, the str<->[byte] bridge, float
// formatting and argv materialization.
//
// Rules for code here:
//   - it is compiled into programs, never into the compiler itself (the C
//     copy embeds the same bytes, see Y_EMBED in src/c/yv.h), so it may
//     use the whole native language: `&x`, `*p`, `syscall`.
//   - every compile parses and checks all of it, used or not: what goes
//     here costs every program's compile time.
//   - function names starting with `y_` are emitted under their bare name
//     (see fn_label_of in native.y): generated code calls them by fixed
//     label, so the emitter's `call y_print_long` finds this def. The `y_`
//     prefix is reserved for the runtime.
//   - arguments arrive on the stack (pushed left to right, caller cleans
//     up) and the result is in %rax — the same convention every Y function
//     uses, so these are callable from both Y code and generated code.
//   - a helper may call intrinsics freely: a string slice `s[a:b]` here
//     is the asm y_str_slice primitive, `bytes`/`from_bytes` the
//     str<->[byte] bridge, `tostring` the value formatter (a float
//     reaches the asm y_float_tostr). Direct calls to asm-only labels are
//     not allowed (the checker would call them undefined), so every
//     bridge into the primitives goes through an intrinsic or an operator.

// One write(2) of a string's bytes to fd 1 / fd 2 (no newline).
def y_put_hstr(s: str) -> long {
    syscall(1, 1, s, len(s))
};
def y_eput_hstr(s: str) -> long {
    syscall(1, 2, s, len(s))
};
def y_print_hstr(s: str) -> long {
    y_put_hstr(s);
    y_put_hstr("\n");
    0
};

// (long -> decimal string is y_long_tostr in arch_x64.y: one idiv
// per digit and one allocation; tostring(v) reaches it.)
def y_bool_tostr(b: bool) -> str {
    if (b) { "true" } else { "false" }
};

// The print/put/eput family: every value becomes a string first,
// so the only output primitive is a byte write above.
def y_print_long(v: long) -> long { y_print_hstr(tostring(v)) };
def y_print_bool(b: bool) -> long { y_print_hstr(y_bool_tostr(b)) };
def y_print_float(f: float) -> long { y_print_hstr(tostring(f)) };
def y_put_long(v: long) -> long { y_put_hstr(tostring(v)) };
def y_put_bool(b: bool) -> long { y_put_hstr(y_bool_tostr(b)) };
def y_eput_long(v: long) -> long { y_eput_hstr(tostring(v)) };
def y_eput_bool(b: bool) -> long { y_eput_hstr(y_bool_tostr(b)) };

// ord(s) = code of the first byte, -1 when empty. chr(n) is its
// inverse. Both work through the [byte] bridge.
def y_str_ord(s: str) -> long {
    if (len(s) > 0) { byte_at(s, 0) } else { 0 - 1 }
};
def y_str_chr(n: long) -> str {
    let b: [byte; 1] = [0; 1];
    b[0] = n;
    from_bytes(b)
};

// a[lo:hi] = src, for 8-byte and packed 1-byte elements: the range
// must lie inside a and hold exactly len(src) elements.
def y_setslice_check(n: long, lo: long, hi: long, m: long) -> long {
    if (lo < 0 || hi > n || lo > hi) {
        y_put_hstr("runtime error: slice assignment out of bounds\n");
        exit(1);
        0
    } else if (hi - lo != m) {
        y_put_hstr("runtime error: slice assignment length mismatch\n");
        exit(1);
        0
    } else { 0 }
};
def y_arr_setslice8(dst: [long], lo: long, hi: long, src: [long]) -> long {
    y_setslice_check(len(dst), lo, hi, len(src));
    let i = 0;
    while (i < hi - lo) {
        dst[lo + i] = src[i];
        i = i + 1;
    };
    0
};
def y_arr_setslice1(dst: [byte], lo: long, hi: long, src: [byte]) -> long {
    y_setslice_check(len(dst), lo, hi, len(src));
    let i = 0;
    while (i < hi - lo) {
        dst[lo + i] = src[i];
        i = i + 1;
    };
    0
};

// The fall-through of a match the checker proved exhaustive.
def y_match_fail() -> long {
    y_put_hstr("runtime error: no match arm matched\n");
    exit(1);
    0
};

// A shift by a negative count: `x << n`, `>>` and `>>>` jump here (x86
// would quietly shift by the count's low 6 bits).
def y_shift_neg() -> long {
    y_put_hstr("runtime error: negative shift count\n");
    exit(1);
    0
};

// tonum(s): optional '-', then digits; anything else stops the
// scan and is ignored (exactly the old asm behaviour).
def y_str_tonum(s: str) -> long {
    let n = len(s);
    let neg = false;
    let i = 0;
    if (n > 0) {
        if (byte_at(s, 0) == 45) {
            neg = true;
            i = 1;
        } else { };
    } else { };
    let acc = 0;
    let go = true;
    while (go) {
        if (i < n) {
            let c = byte_at(s, i);
            if (c >= 48) {
                if (c <= 57) {
                    acc = acc * 10 + (c - 48);
                    i = i + 1;
                } else { go = false; };
            } else { go = false; };
        } else { go = false; };
    };
    if (neg) { 0 - acc } else { acc }
};

// last_index_of: the last match of needle in hay, -1 when absent; an
// empty needle never matches. (index_of, split and trim are assembly:
// arch_x64.y y_str_index, y_str_split, y_str_trim.)
def y_str_lastidx(hay: str, needle: str) -> long {
    let n = len(hay);
    let m = len(needle);
    let found = 0 - 1;
    if (m > 0) {
        if (n >= m) {
            let i = n - m;
            let go = true;
            while (go) {
                if (i >= 0) {
                    if (found < 0) {
                        let j = 0;
                        let ok = true;
                        while (j < m) {
                            if (byte_at(hay, i + j) != byte_at(needle, j)) { ok = false; } else { };
                            j = j + 1;
                        };
                        if (ok) { found = i; } else { };
                    } else { go = false; };
                    i = i - 1;
                } else { go = false; };
            };
        } else { };
    } else { };
    found
};

// range(n) = [0 .. n), empty for n <= 0.
def y_range(n: long) -> [long] {
    let out: [long] = [];
    let m = n;
    if (m < 0) { m = 0; } else { };
    let i = 0;
    while (i < m) {
        out += i;
        i = i + 1;
    };
    out
};

// Time: clock_gettime / nanosleep, straight through the syscall
// intrinsic. clock_us is CLOCK_MONOTONIC microseconds, time_us
// CLOCK_REALTIME's: the wall clock, since the Unix epoch. (heap_used
// reads the allocator's own counter: y_heap_used in arch_x64.y.)
def y_clock_us() -> long {
    let ts: [long; 2] = [0; 2];
    syscall(228, 1, &ts[0]);
    ts[0] * 1000000 + ts[1] / 1000
};
def y_time_us() -> long {
    let ts: [long; 2] = [0; 2];
    syscall(228, 0, &ts[0]);
    ts[0] * 1000000 + ts[1] / 1000
};
// wait_pid(pid): wait4 for a child (fork) -> its exit code, 128 + the
// signal that ended it, or -1 when there is no such child.
def y_wait_pid(pid: long) -> long {
    let status: [long; 1] = [0; 1];
    let r = syscall(61, pid, &status[0], 0, 0);
    let s = status[0] & 65535;
    if (r < 0) { -1 } else if ((s & 127) == 0) { (s >> 8) & 255 } else { 128 + (s & 127) }
};
def y_sleep(ms: long) -> long {
    let m = ms;
    if (m < 0) { m = 0; } else { };
    let ts: [long; 2] = [0; 2];
    ts[0] = m / 1000;
    ts[1] = (m % 1000) * 1000000;
    syscall(35, &ts[0], 0)
};

// b'...' -- Python-style byte-string repr: printable ASCII verbatim,
// quote and backslash escaped, \n \r \t as escapes, everything else
// as \xHH. Built from chr() so the embedded text stays escape-free.
def y_hex_esc(c: long) -> str {
    let d = "0123456789abcdef";
    let hi = (c / 16) % 16;
    let lo = c % 16;
    chr(92) + "x" + d[hi:hi + 1] + d[lo:lo + 1]
};
def y_bytes_repr(b: [byte]) -> str {
    let bs = chr(92);
    let out = "b" + chr(39);
    let i = 0;
    let n = len(b);
    while (i < n) {
        let c = b[i];
        if (c == 92) { out += bs + bs; }
        else if (c == 39) { out += bs + chr(39); }
        else if (c == 10) { out += bs + "n"; }
        else if (c == 13) { out += bs + "r"; }
        else if (c == 9) { out += bs + "t"; }
        else {
            if (c >= 32) {
                if (c < 127) { out += chr(c); }
                else { out += y_hex_esc(c); };
            } else {
                out += y_hex_esc(c);
            };
        };
        i = i + 1;
    };
    out + chr(39)
};
