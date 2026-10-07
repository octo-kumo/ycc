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

// One write of a string's bytes to fd 1 / fd 2 (no newline). Through the named
// syscall layer -- os_call("y_os_write", ...) -- rather than a raw
// `syscall(1, fd, ...)`: 1 is write(2) on Linux and some unrelated Nt function
// on Windows, so a raw Linux number here printed nothing at all under
// --target=windows while the program still exited 0. The number and the
// argument shape belong to the arch module (y_os_write), which is the only
// thing that works here: rt.y is one of the four std units serialized into the
// std pack, so anything resolved while COMPILING it is baked for whichever
// target wrote the pack and --target on the consuming compiler cannot undo it.
def y_put_hstr(s: str) -> long {
    os_call("y_os_write", 1, s, len(s))
};
def y_eput_hstr(s: str) -> long {
    os_call("y_os_write", 2, s, len(s))
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

// tolong(s): optional '-', then digits; anything else stops the
// scan and is ignored (exactly the old asm behaviour). This was `tolong` until
// it grew a float arm, and a name that says "number" cannot say which.

// Whitespace around a number is allowed; nothing else is. 32 space, 9 tab,
// 10 newline, 11 vertical tab, 12 form feed, 13 return.
def y_is_space(c: byte) -> bool {
    c == 32 || (c >= 9 && c <= 13)
};

// tolong(s): some(n) when s is a whole number and NOTHING else, none otherwise.
// The version before this one read what it could and stopped at the first byte
// that was not part of a number: "12abc" answered 12, "" answered 0, " 12 "
// answered 0, "0x10" answered 0, and a 21-digit number wrapped silently. Five
// wrong answers a caller could not tell from the right ones.
//
// The magnitude is carried as a NEGATIVE long when the sign is negative,
// because the most negative long has no positive counterpart: -(acc*10) - d
// reaches -9223372036854775808 without ever forming 9223372036854775808.
def y_str_tolong(s: str) -> long? {
    let n = len(s);
    let i = 0;
    while (i < n && y_is_space(byte_at(s, i))) { i = i + 1; };
    let neg = false;
    if (i < n) {
        let sg = byte_at(s, i);
        if (sg == 45 || sg == 43) {
            neg = sg == 45;
            i = i + 1;
        };
    };
    let start = i;
    let mag = 0;
    let ovf = false;
    let go = true;
    while (i < n && go) {
        let c = byte_at(s, i);
        if (c < 48 || c > 57) { go = false; } else {
            let d = c - 48;
            if (neg) {
                if (mag < -922337203685477580) { ovf = true; }
                else if (mag == -922337203685477580 && d > 8) { ovf = true; }
                else { mag = mag * 10 - d; };
            } else {
                if (mag > 922337203685477580) { ovf = true; }
                else if (mag == 922337203685477580 && d > 7) { ovf = true; }
                else { mag = mag * 10 + d; };
            };
            if (ovf) { go = false; } else { i = i + 1; };
        };
    };
    if (ovf || i == start) {
        none
    } else {
        while (i < n && y_is_space(byte_at(s, i))) { i = i + 1; };
        if (i < n) { none } else { some(mag) }
    }
};

// tofloat(s): the same rule -- a whole number, or one with a fraction, and
// nothing else; whitespace around it is fine; none otherwise. The accumulation
// is unchanged and deliberately not strtod: it adds in double as it goes, so
// "3.14" comes back as the double nearest 3.14 and "0.1" as the double nearest
// 0.1, which is what every other language's parser returns and what this
// module's own literals are. Exponents ("1e9") are still not read -- a program
// that wants them wants math.log10 and pow_mod, not a parser with a different
// answer per platform -- and now they are REJECTED rather than silently
// truncated to the digits before the "e".
def y_str_tofloat(s: str) -> float? {
    let n = len(s);
    let i = 0;
    while (i < n && y_is_space(byte_at(s, i))) { i = i + 1; };
    let neg = false;
    if (i < n) {
        let sg = byte_at(s, i);
        if (sg == 45 || sg == 43) {
            neg = sg == 45;
            i = i + 1;
        };
    };
    let acc = 0.0;
    let scale = 0.1;
    let dot = false;
    let digits = 0;
    let go = true;
    while (i < n && go) {
        let c = byte_at(s, i);
        if (c >= 48 && c <= 57) {
            if (dot) {
                acc = acc + (c - 48) * scale;
                scale = scale * 0.1;
            } else {
                acc = acc * 10.0 + (c - 48);
            };
            digits = digits + 1;
            i = i + 1;
        } else if (c == 46 && !dot) {
            dot = true;
            i = i + 1;
        } else { go = false; };
    };
    if (digits == 0) {
        none
    } else {
        while (i < n && y_is_space(byte_at(s, i))) { i = i + 1; };
        if (i < n) { none } else if (neg) { some(0.0 - acc) } else { some(acc) }
    }
};

// The bare truncating cast, and a `ndef` is what makes it reachable from
// here: naming the label puts it in this program's references, which is how
// uses_math decides whether math.s is in the program at all. One instruction of
// machine code, already written and already gated -- not a second copy of it.
ndef trunc_to_long(x: float) -> long = "y_to_int";

// tolong(x) for a float: truncated toward zero, and CHECKED. A float with no
// long answer -- a NaN, or |x| at or past 2^63 -- traps here rather than coming
// back as the machine's "integer indefinite" value, which is a perfectly good
// index and an utterly misleading one. math.to_int makes the same promise for
// the same reason, and one rule in a language is worth more than four
// instructions.
def y_f2l(x: float) -> long? {
    // 2^63 as a double: the first float with no long answer. It is exact, which
    // matters -- an inexact bound would reject x = 2^63 - 1024 for no reason.
    // A LOCAL, deliberately: a module-level `let` here becomes a .bss cell and
    // an _init thunk in every binary, because rt.y is linked by every program
    // and so its globals are the one thing the shaker cannot drop. Inside the
    // function the bound is materialised only by a program that calls it.
    //
    // This used to TRAP on a NaN or an out-of-range float. tolong now answers
    // T?, so "there is no long answer" is `none` -- which is the same
    // distinction the string form makes, and a caller can check it.
    let two63: float = 9223372036854775808.0;
    if (x != x || x >= two63 || x < 0.0 - two63) {
        none
    } else {
        // The cast is where the truncation happens: cvttsd2si rounds toward zero,
        // which is what "truncate" means and what floor does not.
        some(trunc_to_long(x))
    }
};

// last_index_of: the last match of needle in hay, -1 when absent; an
// empty needle never matches. (index_of, split and trim are assembly:
// arch_x64.y y_str_index, y_str_split, y_str_trim.)
def y_str_lastidx(hay: str, needle: str, from: long) -> long {
    let n = len(hay);
    let m = len(needle);
    let found = 0 - 1;
    if (m > 0) {
        if (n >= m) {
            // a `from` past the end means the whole string (the two-argument
            // caller passes LONG_MAX); see str.y's twin
            let lim = from;
            if (lim > n - m) { lim = n - m; };
            let i = lim;
            let go = true;
            while (go) {
                if (i >= 0) {
                    if (found < 0) {
                        let j = 0;
                        let ok = true;
                        while (j < m) {
                            if (byte_at(hay, i + j) != byte_at(needle, j)) { ok = false; }
                            j = j + 1;
                        };
                        if (ok) { found = i; }
                    } else { go = false; };
                    i = i - 1;
                } else { go = false; };
            };
        }
    }
    found
};

// range(n) = [0 .. n), empty for n <= 0.
def y_range(n: long) -> [long] {
    let out: [long] = [];
    let m = n;
    if (m < 0) { m = 0; }
    let i = 0;
    while (i < m) {
        out += i;
        i = i + 1;
    };
    out
};

// Time: clock_gettime / nanosleep, through the named syscall layer like every
// other call in this unit -- the Windows halves convert a FILETIME and a QPC
// tick into the same struct timespec, so the code above the arch module is the
// same bytes on both targets. clock_us is CLOCK_MONOTONIC microseconds, time_us
// CLOCK_REALTIME's: the wall clock, since the Unix epoch. (heap_used
// reads the allocator's own counter -- y_heap_used in arch_x64.y -- minus
// the pre-main baseline y_heap_base_set records after y_argv_init, so the
// heap copy of argv is not in the figure and an absolute number does not
// move with the length of the command line.)
// ONE timespec for the whole runtime, not one per call.
//
// The obvious spelling -- `let ts: [long; 2] = [0; 2];` inside the function --
// puts a fresh 2-element array on the arena every call, because &ts[0] needs an
// address: 56 bytes a call, measured (1000 calls = 56000, and a frame loop
// calling clock_us once a frame grows without bound).  A module-level `let` is
// allocated once, so the syscall below borrows the same two words for ever.
// Not thread-safe, and deliberately so: two threads racing here would both get
// a time within a syscall of the right one, which is what clock_gettime is for.
let CLK_TS: [long; 2] = [0; 2];
def y_clock_us() -> long {
    os_call("y_os_clock_gettime", 1, &CLK_TS[0]);
    CLK_TS[0] * 1000000 + CLK_TS[1] / 1000
};
def y_time_us() -> long {
    os_call("y_os_clock_gettime", 0, &CLK_TS[0]);
    CLK_TS[0] * 1000000 + CLK_TS[1] / 1000
};
// wait_pid(pid): wait4 for a child (fork) -> its exit code, 128 + the
// signal that ended it, or -1 when there is no such child.
def y_wait_pid(pid: long) -> long {
    let status: [long; 1] = [0; 1];
    let r = os_call("y_os_wait4", pid, &status[0]);
    let s = status[0] & 65535;
    if (r < 0) { -1 } else if ((s & 127) == 0) {(s >> 8) & 255 } else { 128 + (s & 127) }
};
def y_sleep(ms: long) -> long {
    let m = ms;
    if (m < 0) { m = 0; }
    let ts: [long; 2] = [0; 2];
    ts[0] = m / 1000;
    ts[1] = (m % 1000) * 1000000;
    os_call("y_os_nanosleep", &ts[0])
};
// y_sleep_us(us): nanosleep in MICROSECONDS, where y_sleep takes whole
// milliseconds.  The two differ by a factor of 1000 and there is no way to
// express the smaller one with the larger one's signature, so a frame loop
// that wants a 200 us nap cannot have one.  ORCHESTRATOR.md 0d asks for
// "sub-millisecond pacing" by name, and three examples in examples/ carried
// their own `nap_us` for it -- examples/badapple wrote it three times, once per
// pipeline, rather than share it.
//
// The nanosecond field is the remainder in microseconds times 1000; there is no
// way to ask for a fraction of a microsecond, so that is where the resolution
// stops rather than silently rounding.
def y_sleep_us(us: long) -> long {
    let u = us;
    if (u < 0) { u = 0; }
    // the same borrowed timespec the clocks above use -- see CLK_TS for why it
    // is not a local.  sleep is not reentrant with the clocks for the same
    // reason, and it does not matter: the kernel has already been handed the
    // pointer before anything else can run on this thread.
    CLK_TS[0] = u / 1000000;
    CLK_TS[1] = (u % 1000000) * 1000;
    os_call("y_os_nanosleep", &CLK_TS[0])
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

// ── big integers ───────────────────────────────────────────────────────
// A bigint is a heap record: sign, significant-limb count, and little-endian
// base-2^28 limbs. Base 2^28 keeps every schoolbook product inside a signed
// long with a wide margin (see examples/bignum/README.md) and makes bit shifts
// and the low-64-bit narrowing cheap. The language's `bigint` is this exact
// object at run time; only the labels below cross that boundary, so the type
// checker can keep bigint opaque while the runtime manipulates YBig records.
type YBig = { neg: long, n: long, limbs: [long] };
type YBigPair = { q: YBig, r: YBig };

ndef y_bigint_fbits(x: float) -> long = "y_fbits";

def y_bigint_zero() -> YBig {
    { neg: 0, n: 0, limbs: [] }
};

// n zero limbs.
def y_bigint_new(n: long) -> YBig {
    let limbs: [long] = [];
    let i = 0;
    while (i < n) {
        limbs += 0;
        i = i + 1;
    };
    { neg: 0, n: 0, limbs: limbs }
};

// Drop leading zero limbs (and the sign of zero).
def y_bigint_norm(b: YBig) -> YBig {
    let l: [long] = b.limbs;
    let n = len(l);
    while (n > 0 && l[n - 1] == 0) { n = n - 1; };
    b.n = n;
    if (n == 0) { b.neg = 0; };
    b
};

def y_bigint_copy_mag(a: YBig, neg: long) -> YBig {
    let out = y_bigint_new(a.n);
    let i = 0;
    while (i < a.n) {
        out.limbs[i] = a.limbs[i];
        i = i + 1;
    };
    out.n = a.n;
    out.neg = neg;
    y_bigint_norm(out)
};

def y_bigint_copy(a: YBig) -> YBig {
    y_bigint_copy_mag(a, a.neg)
};

def y_bigint_from_long(v: long) -> YBig {
    if (v == 0) { return y_bigint_zero(); };
    let neg = 0;
    let m = v;
    if (v < 0) {
        neg = 1;
        m = 0 - v;
        if (m < 0) {
            // -2^63: 0 - v wraps back negative. It is 128 * 2^56, which is
            // exactly [0, 0, 128] in base 2^28.
            let s: [long] = [0, 0, 128];
            let z: YBig = { neg: 1, n: 3, limbs: s };
            return z;
        };
    };
    let limbs: [long] = [];
    while (m > 0) {
        limbs += m & 268435455;
        m = m >> 28;
    };
    let out: YBig = { neg: neg, n: len(limbs), limbs: limbs };
    y_bigint_norm(out)
};

def y_bigint_mag_cmp(a: YBig, b: YBig) -> long {
    if (a.n != b.n) {
        if (a.n < b.n) { return 0 - 1; } else { return 1; };
    };
    let i = a.n - 1;
    while (i >= 0) {
        let av = a.limbs[i];
        let bv = b.limbs[i];
        if (av != bv) {
            if (av < bv) { return 0 - 1; } else { return 1; };
        };
        i = i - 1;
    };
    0
};

def y_bigint_cmp(a: YBig, b: YBig) -> long {
    if (a.neg != b.neg) {
        if (a.neg == 1) { return 0 - 1; } else { return 1; };
    };
    let c = y_bigint_mag_cmp(a, b);
    if (a.neg == 1) { return 0 - c; } else { return c; }
};

def y_bigint_mag_add(a: YBig, b: YBig) -> YBig {
    let n = a.n;
    if (b.n > n) { n = b.n; };
    let out = y_bigint_new(n + 1);
    let carry = 0;
    let i = 0;
    while (i < n) {
        let av = 0;
        if (i < a.n) { av = a.limbs[i]; };
        let bv = 0;
        if (i < b.n) { bv = b.limbs[i]; };
        let cur = av + bv + carry;
        out.limbs[i] = cur & 268435455;
        carry = cur >> 28;
        i = i + 1;
    };
    out.n = n;
    if (carry > 0) {
        out.limbs[n] = carry;
        out.n = n + 1;
    };
    y_bigint_norm(out)
};

// a - b for magnitudes a >= b.
def y_bigint_mag_sub(a: YBig, b: YBig) -> YBig {
    let out = y_bigint_new(a.n);
    let borrow = 0;
    let i = 0;
    while (i < a.n) {
        let bv = 0;
        if (i < b.n) { bv = b.limbs[i]; };
        let cur = a.limbs[i] - bv - borrow;
        if (cur < 0) {
            cur = cur + 268435456;
            borrow = 1;
        } else {
            borrow = 0;
        };
        out.limbs[i] = cur;
        i = i + 1;
    };
    out.n = a.n;
    y_bigint_norm(out)
};

def y_bigint_add(a: YBig, b: YBig) -> YBig {
    if (a.neg == 0) {
        if (b.neg == 0) { return y_bigint_mag_add(a, b); };
        let c = y_bigint_mag_cmp(a, b);
        if (c >= 0) { return y_bigint_mag_sub(a, b); };
        let r = y_bigint_mag_sub(b, a);
        r.neg = 1;
        return y_bigint_norm(r);
    };
    if (b.neg == 0) {
        let c = y_bigint_mag_cmp(b, a);
        if (c >= 0) { return y_bigint_mag_sub(b, a); };
        let r = y_bigint_mag_sub(a, b);
        r.neg = 1;
        return y_bigint_norm(r);
    };
    let r = y_bigint_mag_add(a, b);
    r.neg = 1;
    y_bigint_norm(r)
};

def y_bigint_neg(a: YBig) -> YBig {
    if (a.n == 0) { return y_bigint_zero(); };
    let r = y_bigint_copy_mag(a, a.neg);
    if (r.neg == 0) { r.neg = 1; } else { r.neg = 0; };
    r
};

def y_bigint_sub(a: YBig, b: YBig) -> YBig {
    y_bigint_add(a, y_bigint_neg(b))
};

def y_bigint_mul_small(a: YBig, m: long) -> YBig {
    if (a.n == 0 || m == 0) { return y_bigint_zero(); };
    let out = y_bigint_new(a.n + 1);
    let carry = 0;
    let i = 0;
    while (i < a.n) {
        let cur = a.limbs[i] * m + carry;
        out.limbs[i] = cur & 268435455;
        carry = cur >> 28;
        i = i + 1;
    };
    out.n = a.n;
    if (carry > 0) {
        out.limbs[a.n] = carry;
        out.n = a.n + 1;
    };
    y_bigint_norm(out)
};

def y_bigint_add_small(a: YBig, d: long) -> YBig {
    if (d == 0) { return y_bigint_copy(a); };
    let out = y_bigint_new(a.n + 1);
    let carry = d;
    let i = 0;
    while (i < a.n) {
        let cur = a.limbs[i] + carry;
        out.limbs[i] = cur & 268435455;
        carry = cur >> 28;
        i = i + 1;
    };
    out.n = a.n;
    if (carry > 0) {
        out.limbs[a.n] = carry;
        out.n = a.n + 1;
    };
    y_bigint_norm(out)
};

def y_bigint_mag_mul(a: YBig, b: YBig) -> YBig {
    if (a.n == 0 || b.n == 0) { return y_bigint_zero(); };
    let out = y_bigint_new(a.n + b.n + 1);
    let i = 0;
    while (i < a.n) {
        let carry = 0;
        let j = 0;
        while (j < b.n) {
            let cur = out.limbs[i + j] + a.limbs[i] * b.limbs[j] + carry;
            out.limbs[i + j] = cur & 268435455;
            carry = cur >> 28;
            j = j + 1;
        };
        out.limbs[i + b.n] = carry;
        i = i + 1;
    };
    out.n = a.n + b.n;
    y_bigint_norm(out)
};

def y_bigint_mul(a: YBig, b: YBig) -> YBig {
    let r = y_bigint_mag_mul(a, b);
    if (a.neg != b.neg) { r.neg = 1; } else { r.neg = 0; };
    y_bigint_norm(r)
};

// Shift the magnitude left/right by `bits` (0 <= bits <= a few thousand).
def y_bigint_mag_shl_bits(a: YBig, bits: long) -> YBig {
    if (a.n == 0 || bits <= 0) { return y_bigint_copy_mag(a, 0); };
    let limb_shift = bits / 28;
    let bit_shift = bits % 28;
    let out = y_bigint_new(a.n + limb_shift + 1);
    let i = 0;
    if (bit_shift == 0) {
        while (i < a.n) {
            out.limbs[i + limb_shift] = a.limbs[i];
            i = i + 1;
        };
    } else {
        let carry = 0;
        let mask = 268435455;
        while (i < a.n) {
            let cur = (a.limbs[i] << bit_shift) | carry;
            out.limbs[i + limb_shift] = cur & mask;
            carry = cur >> 28;
            i = i + 1;
        };
        out.limbs[a.n + limb_shift] = carry;
    };
    out.n = a.n + limb_shift + 1;
    y_bigint_norm(out)
};

def y_bigint_mag_shr_bits(a: YBig, bits: long) -> YBig {
    if (a.n == 0 || bits <= 0) { return y_bigint_copy_mag(a, 0); };
    let limb_shift = bits / 28;
    let bit_shift = bits % 28;
    if (limb_shift >= a.n) { return y_bigint_zero(); };
    let n = a.n - limb_shift;
    let out = y_bigint_new(n);
    let i = 0;
    if (bit_shift == 0) {
        while (i < n) {
            out.limbs[i] = a.limbs[i + limb_shift];
            i = i + 1;
        };
    } else {
        let mask = (1 << bit_shift) - 1;
        while (i < n) {
            let lo = a.limbs[i + limb_shift] >> bit_shift;
            let hi = 0;
            if (i + limb_shift + 1 < a.n) {
                hi = (a.limbs[i + limb_shift + 1] & mask) << (28 - bit_shift);
            };
            out.limbs[i] = lo | hi;
            i = i + 1;
        };
    };
    out.n = n;
    y_bigint_norm(out)
};

def y_bigint_mag_bitlen(a: YBig) -> long {
    if (a.n == 0) { return 0; };
    let bits = (a.n - 1) * 28;
    let v = a.limbs[a.n - 1];
    while (v > 0) {
        bits = bits + 1;
        v = v >> 1;
    };
    bits
};

def y_bigint_mag_bit(a: YBig, i: long) -> long {
    let li = i / 28;
    if (li >= a.n) { return 0; };
    (a.limbs[li] >> (i % 28)) & 1
};

def y_bigint_mag_setbit(a: YBig, i: long) -> YBig {
    let li = i / 28;
    while (len(a.limbs) <= li) { a.limbs += 0; };
    a.limbs[li] = a.limbs[li] | (1 << (i % 28));
    if (li + 1 > a.n) { a.n = li + 1; };
    a
};

// Binary long division on magnitudes. The quotient and remainder are exact;
// the caller applies the signs.
def y_bigint_mag_divmod(a: YBig, b: YBig) -> YBigPair {
    let q = y_bigint_zero();
    let r = y_bigint_zero();
    let i = y_bigint_mag_bitlen(a) - 1;
    while (i >= 0) {
        r = y_bigint_mag_shl_bits(r, 1);
        if (y_bigint_mag_bit(a, i) == 1) {
            r = y_bigint_add_small(r, 1);
        };
        if (y_bigint_mag_cmp(r, b) >= 0) {
            r = y_bigint_mag_sub(r, b);
            q = y_bigint_mag_setbit(q, i);
        };
        i = i - 1;
    };
    { q: q, r: r }
};

// Divide by a small positive long, in place, returning the remainder.
def y_bigint_mag_div_small(a: YBig, d: long) -> long {
    let i = a.n - 1;
    let rem = 0;
    while (i >= 0) {
        let cur = rem * 268435456 + a.limbs[i];
        a.limbs[i] = cur / d;
        rem = cur % d;
        i = i - 1;
    };
    y_bigint_norm(a);
    rem
};

def y_bigint_div_zero() -> YBig {
    y_put_hstr("runtime error: division by zero\n");
    exit(1);
    y_bigint_zero()
};

def y_bigint_div(a: YBig, b: YBig) -> YBig {
    if (b.n == 0) { return y_bigint_div_zero(); };
    let p = y_bigint_mag_divmod(y_bigint_copy_mag(a, 0), y_bigint_copy_mag(b, 0));
    let q = p.q;
    if (a.neg != b.neg) { q.neg = 1; } else { q.neg = 0; };
    y_bigint_norm(q)
};

def y_bigint_mod(a: YBig, b: YBig) -> YBig {
    if (b.n == 0) { return y_bigint_div_zero(); };
    let p = y_bigint_mag_divmod(y_bigint_copy_mag(a, 0), y_bigint_copy_mag(b, 0));
    let r = p.r;
    if (a.neg == 1) { r.neg = 1; } else { r.neg = 0; };
    y_bigint_norm(r)
};

def y_bigint_digit(c: byte, radix: long) -> long {
    if (c >= '0' && c <= '9') { return c - '0'; };
    if (c >= 'a' && c <= 'f') { return c - 'a' + 10; };
    if (c >= 'A' && c <= 'F') { return c - 'A' + 10; };
    0 - 1
};

def y_bigint_parse(s: str) -> YBig {
    let n = len(s);
    let radix = 10;
    let start = 0;
    if (n >= 2 && byte_at(s, 0) == '0') {
        let p = byte_at(s, 1);
        if (p == 'x' || p == 'X') { radix = 16; start = 2; }
        else if (p == 'o' || p == 'O') { radix = 8; start = 2; }
        else if (p == 'b' || p == 'B') { radix = 2; start = 2; };
    };
    let out = y_bigint_zero();
    let i = start;
    while (i < n) {
        let c = byte_at(s, i);
        if (c != '_') {
            let d = y_bigint_digit(c, radix);
            if (d >= 0) {
                out = y_bigint_mul_small(out, radix);
                out = y_bigint_add_small(out, d);
            };
        };
        i = i + 1;
    };
    y_bigint_norm(out)
};

def y_bigint_to_dec(a: YBig) -> str {
    if (a.n == 0) { return "0"; };
    let x = y_bigint_copy_mag(a, 0);
    let out = "";
    let first = true;
    while (x.n > 0) {
        let r = y_bigint_mag_div_small(x, 1000000000);
        let part = tostring(r);
        if (first) {
            out = part;
            first = false;
        } else {
            while (len(part) < 9) { part = "0" + part; };
            out = part + out;
        };
    };
    let start = 0;
    while (start + 1 < len(out) && byte_at(out, start) == '0') { start = start + 1; };
    if (start > 0) { out = out[start:len(out)]; };
    if (a.neg == 1) { out = "-" + out; };
    out
};

def y_bigint_tostr(a: YBig) -> str {
    y_bigint_to_dec(a)
};

def y_bigint_print(a: YBig) -> long {
    y_print_hstr(y_bigint_to_dec(a))
};

// The checked narrowing: some(v) when v fits a signed long, none when it
// does not. tolong(bigint) therefore has the same T? shape as tolong(str)
// and tolong(float).
def y_bigint_to_long(a: YBig) -> long? {
    if (a.n == 0) { return some(0); };
    let mag_a = y_bigint_copy_mag(a, 0);
    if (a.neg == 0) {
        let max = y_bigint_from_long(9223372036854775807);
        if (y_bigint_mag_cmp(mag_a, max) > 0) { return none; };
    } else {
        // The magnitude of LONG_MIN is one past LONG_MAX; build it without
        // ever naming the unrepresentable positive value.
        let lim = y_bigint_from_long(0 - 9223372036854775807);
        lim = y_bigint_sub(lim, y_bigint_from_long(1));
        let lim_mag = y_bigint_copy_mag(lim, 0);
        if (y_bigint_mag_cmp(mag_a, lim_mag) > 0) { return none; };
    };
    let l0 = 0;
    let l1 = 0;
    let l2 = 0;
    if (a.n > 0) { l0 = a.limbs[0]; };
    if (a.n > 1) { l1 = a.limbs[1]; };
    if (a.n > 2) { l2 = a.limbs[2]; };
    let mag = l0 + (l1 << 28) + ((l2 & 255) << 56);
    if (a.neg == 1) { some(0 - mag) } else { some(mag) }
};

// tofloat(bigint) is an option too: the decimal path already answers T?.
def y_bigint_to_float(a: YBig) -> float? {
    y_str_tofloat(y_bigint_to_dec(a))
};

def y_bigint_from_float(f: float) -> YBig {
    let bits = y_bigint_fbits(f);
    let exp = (bits >>> 52) & 2047;
    if (exp == 2047) {
        y_put_hstr("runtime error: float has no bigint value\n");
        exit(1);
        return y_bigint_zero();
    };
    let sign = bits >>> 63;
    let frac = bits & 4503599627370495;
    if (exp == 0) {
        if (frac == 0) { return y_bigint_zero(); };
        // A subnormal truncates to zero: frac * 2^-1074 < 1.
        return y_bigint_zero();
    };
    let mant = frac + 4503599627370496;
    let e = exp - 1075;
    let mag = y_bigint_from_long(mant);
    if (e >= 0) {
        mag = y_bigint_mag_shl_bits(mag, e);
    } else {
        mag = y_bigint_mag_shr_bits(mag, 0 - e);
    };
    if (sign == 1) { mag.neg = 1; };
    y_bigint_norm(mag)
};

def y_bigint_from_bytes_be(b: [byte]) -> YBig {
    let out = y_bigint_zero();
    let i = 0;
    while (i < len(b)) {
        out = y_bigint_mul_small(out, 256);
        out = y_bigint_add_small(out, b[i]);
        i = i + 1;
    };
    y_bigint_norm(out)
};

def y_bigint_to_bytes_be(a: YBig, n: long) -> [byte] {
    let out: [byte] = [];
    let i = 0;
    while (i < n) {
        out += 0;
        i = i + 1;
    };
    let x = y_bigint_copy_mag(a, 0);
    i = n - 1;
    while (i >= 0) {
        out[i] = y_bigint_mag_div_small(x, 256);
        i = i - 1;
    };
    out
};
