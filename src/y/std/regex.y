// std/regex.y — regular expressions in plain Y: a Pike VM (a Thompson NFA
// simulated with priority-ordered thread lists), over BYTES.
//
//     import regex;
//     let re = regex.compile("(?<host>\\S+)@(\\S+):(\\d+)")!;
//     foreach (m in re.find(text)) {
//         print(m.start, "..", m.end, " ", regex.named(m, "host")!);
//     };
//
// Rules on top of rt.y's:
//   - a MODULE, not a std unit: `import regex;` is the only way in, so the file
//     is parsed only by a program that asks for it. No top-level `let` either —
//     a top-level binding is a shake root, inlined at _start in every binary
//     that imports the module (see crypto.y:131) — so every table here is built
//     inside a def.
//   - it never prints and never exits. A pattern is data (a config file, an
//     argv), not a caller bug, so one that does not compile is `none` from
//     compile and a message from check — x509.verify_chain's rule (x509.y:430).
//   - no closures: a Match is plain data and every accessor is a module-level
//     function taking it, because the C twin's value model has no function
//     value to store one in (AGENTS.md, "Y code style").
//   - BYTES, like every other string operation in the tree: `.` is one byte,
//     \d \w \s \b and (?i) are ASCII, and \x{...} is UTF-8 encoded at compile
//     time. No code points, no \p{...}, no Unicode case folding.
//   - no backreferences and no pattern recursion: an NFA simulation has no
//     single path for a backreference to compare against, and recursion would
//     need the machine stack. The only run-time recursion is a lookaround's,
//     bounded by the pattern's own nesting.
//
// The dialect, and what is deliberately not in it:
//
//   x . [abc] [^a-z] [[:alpha:]]   \d \D \w \W \s \S   \b \B
//   \n \r \t \f \v \a \0 \xHH \x{H+} ^ $ \A \z           a|b
//   ( ) (?: ) (?<name> )          * + ? {n} {n,} {n,m}  (each may be lazy: x*?)
//   (?i) (?s) (?m)  (?is: … )      (?= ) (?! )  (?<= ) (?<! )   (lookbehind: fixed width)
//
//   not: \1 \k<name>   no path to compare against (RE2 refuses them too)
//        (?R) \g<…>    needs a machine stack
//        \p{…}         Unicode tables nothing else in std has
//        (?>…) a*+     atomic/possessive need backtracking to mean anything
//        (?-i)         turning a flag off would re-fold an already-emitted set
//
// Semantics are Perl's (leftmost, then first alternative, greedy unless lazy),
// not POSIX's leftmost-longest: search("ab") with a|ab gives "a".

// ── limits ────────────────────────────────────────────────────────────────
// Each has a message (see p_rep, p_alt, build), so a pattern that would cost
// the machine its memory says so instead of trying.
const MAX_REPEAT = 1000;      // a {n,m} count
const MAX_INST = 4096;        // instructions after the {n,m} expansion
const MAX_GROUPS = 200;       // capturing groups
const MAX_LOOK = 32;          // lookaround nesting: the only run-time recursion
const MAX_DEPTH = 200;        // ( ) nesting: the parser and the emitter recurse on it

// ── opcodes (three longs per instruction: op, a, b) ───────────────────────
//   1 CLS    a = a byte set       consume one byte in it
//   2 SPLIT  a = try a first, then b  (greedy vs lazy lives in the order)
//   3 JMP    a = where             continue at a
//   4 SAVE   a = a capture slot    record the current position there
//   5 ASSERT a = kind              zero-width: 1 ^  2 $  3 ^m  4 $m  5 \b  6 \B
//   6 LOOK   a = width * 8 + kind  zero-width: kind 1 (?= 2 (?! 3 (?<= 4 (?<!
//                                   (a lookbehind's width is fixed at compile
//                                   time and rides along here)
//   7 MATCH                         the match ends here

// ── the parse tree ────────────────────────────────────────────────────────
// A union, so each node is a record of exactly its own fields. Every member
// leads with k, which is therefore the one field readable without a cast.
type RSet = { k: long, set: long };
type RSeq = { k: long, items: [RE] };
type RAlt = { k: long, alts: [RE] };
type RRep = { k: long, min: long, max: long, greedy: bool, item: RE };
type RGroup = { k: long, num: long, item: RE };
type RAs = { k: long, kind: long };
type RLook = { k: long, kind: long, width: long, item: RE };
type RErr = { k: long };
type RE = RSet | RSeq | RAlt | RRep | RGroup | RAs | RLook | RErr;

// k of each node kind (the one field every member shares)
const K_SET = 1;
const K_SEQ = 2;
const K_ALT = 3;
const K_REP = 4;
const K_GROUP = 5;
const K_AS = 6;
const K_LOOK = 7;
const K_ERR = 8;

// ── the parse state ───────────────────────────────────────────────────────
// One record, passed everywhere by reference: pos is the cursor and err the
// first message ("" = fine). Every p_* def checks err before it uses its node.
type PP = {
    pat: str, pos: long, err: str,
    icase: bool, dotall: bool, multiline: bool,
    groups: long, names: { str => long }, classes: [byte]
};

// ── the results ───────────────────────────────────────────────────────────

// A compiled pattern. prog is three longs per instruction (the opcodes above);
// classes is 32 bytes per byte set; first is the set a match can begin with,
// or -1 when any byte can (a pattern that can match nothing); literal is the
// bytes every match must BEGIN with ("" = none); need is bytes every match must
// contain wherever they are ("" = none); anchored says only position 0 can
// match. prog, classes, first, literal, need and nclass are the engine's own
// data — they are fields because a Y record is exact, so there is no hiding.
type Re = {
    pattern: str, prog: [long], classes: [byte], nclass: long,
    first: long, literal: str, need: str, anchored: bool,
    groups: long, names: { str => long }
};

// One match. text is subject[start:end] (one copy — a Y string slice always
// allocates); caps holds two slots per group, group 0 first, -1 for a group that
// took no part, so m.caps[2 * 1] is group 1's start without a call.
type Match = { subject: str, text: str, start: long, end: long, caps: [long], names: { str => long } };

// What build() hands back: the compiled pattern, or the message. (A Re cannot
// be spelled empty for the failure case, so the two travel apart.)
type Built = { re: Re, err: str };

// A running match: the program, the subject, and the scratch.
//
// A thread is a pc and the captures it has filled in, kept as two PARALLEL
// arrays with a live count rather than as records in an array. There is no free
// in the heap this runs on, so every allocation counts for the life of the
// process: a record per thread per step is 16 million of them over an 8 MB
// subject, while a parallel array only grows when a list outgrows the width it
// has already reached. The counts (cur_n, nxt_n) are what let a list be
// emptied without touching it at all.
//
// ok is per step ("a match ended here, so stop handing out lower-priority
// threads") and matched is for the whole run ("hit holds an answer"), which are
// not the same thing: a greedy x+ records its short match and then keeps going
// with the threads that outrank it. base and hit are buffers rather than fresh
// arrays for the same reason. subs holds one Run per lookaround depth, shared
// by reference through every level (each with its own stamps), so a lookahead
// costs no allocation after the first time at that depth.
type Run = {
    prog: [long], classes: [byte], subject: str, end: long,
    ninst: long, ncap: long,
    cur_pc: [long], cur_cap: [[long]], cur_n: long,
    nxt_pc: [long], nxt_cap: [[long]], nxt_n: long,
    seen: [long], gen: long, wpc: [long], wcap: [[long]],
    base: [long], hit: [long], hit_end: long, want_end: long,
    free: [[long]], free_n: long,
    ok: bool, matched: bool, look: long, subs: [Run]
};

// ── byte sets: 32 bytes = 256 bits ────────────────────────────────────────
// A set is a reference, so each of these writes through its parameter. The
// parse tree keeps them in one flat classes: [byte], 32 bytes per set, and the
// VM looks a set up there by number.

// bit c of bm
def set_bit(bm: [byte; 32], c: long) -> long {
    let i = (c >> 3) & 31;
    bm[i] = bm[i] | (1 << (c & 7));
    0
};

// every byte but c
def set_all_but(bm: [byte; 32], c: long) -> long {
    set_range(bm, 0, 255);
    let i = (c >> 3) & 31;
    bm[i] = bm[i] - (1 << (c & 7));        // the bit is set, so taking it off clears
    0
};

def set_range(bm: [byte; 32], lo: long, hi: long) -> long {
    let c = lo;
    let go = lo <= hi;
    while (go) {
        set_bit(bm, c);
        c = c + 1;
        go = c <= hi;
    };
    0
};

def set_all(bm: [byte; 32]) -> long { set_range(bm, 0, 255) };

def set_invert(bm: [byte; 32]) -> long {
    let i = 0;
    while (i < 32) {
        bm[i] = 255 - bm[i];
        i = i + 1;
    };
    0
};

def set_or(dst: [byte; 32], src: [byte; 32]) -> long {
    let i = 0;
    while (i < 32) {
        dst[i] = dst[i] | src[i];
        i = i + 1;
    };
    0
};

def set_full_p(bm: [byte; 32]) -> bool {
    let i = 0;
    while (i < 32) {
        if (bm[i] != 255) { return false; };
        i = i + 1;
    };
    true
};

// How many bytes the set holds (capped at two: only 0, 1 and "more" are asked).
def set_count2(bm: [byte; 32]) -> long {
    let n = 0;
    let i = 0;
    while (i < 32) {
        let b = bm[i];
        let j = 0;
        while (j < 8) {
            if ((b >> j) & 1 == 1) {
                n = n + 1;
                if (n > 1) { return 2; };
            };
            j = j + 1;
        };
        i = i + 1;
    };
    n
};

// The one byte a set holding exactly one byte holds, -1 otherwise.
def set_the_one(bm: [byte; 32]) -> long {
    let out = 0 - 1;
    let i = 0;
    while (i < 32) {
        let b = bm[i];
        let j = 0;
        while (j < 8) {
            if ((b >> j) & 1 == 1) { out = i * 8 + j; };
            j = j + 1;
        };
        i = i + 1;
    };
    out
};

def set_has(bm: [byte; 32], c: long) -> bool {(bm[(c >> 3) & 31] & (1 << (c & 7))) != 0 };

// The same two questions, of set number k in a flat classes array (what the VM
// asks, so it never has to build a [byte; 32] to ask them).
def class_has(classes: [byte], k: long, c: long) -> bool {
    ((classes[k * 32 + (c >> 3)] >> (c & 7)) & 1) != 0
};

def class_one(classes: [byte], k: long) -> long {
    let bm: [byte; 32] = [0; 32];
    let i = 0;
    while (i < 32) { bm[i] = classes[k * 32 + i]; i = i + 1; };
    if (set_count2(bm) == 1) { set_the_one(bm) } else { 0 - 1 }
};

// The next set number, with bm's 32 bytes in the list.
def add_class(p: PP, bm: [byte; 32]) -> long {
    let k = len(p.classes) / 32;
    let i = 0;
    while (i < 32) {
        p.classes += bm[i];
        i = i + 1;
    };
    k
};

// One byte into a set, case-folded when (?i) is on. ASCII only, like
// str.upper / str.lower (str.y:194-209).
def add_byte(p: PP, bm: [byte; 32], c: long) -> long {
    set_bit(bm, c);
    if (p.icase) {
        if (c >= 65 && c <= 90) { set_bit(bm, c + 32); };
        if (c >= 97 && c <= 122) { set_bit(bm, c - 32); };
    };
    0
};

// ── bytes ─────────────────────────────────────────────────────────────────

def is_digit_byte(c: long) -> bool { c >= 48 && c <= 57 };

def is_word_byte(c: long) -> bool {
    (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
};

def is_space_byte(c: long) -> bool { c == 32 || c == 9 || c == 10 || c == 11 || c == 12 || c == 13 };

// The bytes a backslash may escape as themselves (everything else has to be a
// named escape or \x, so a typo is a typo).
def escapable_p(c: long) -> bool {
    (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126)
};

def hex_val(c: long) -> long {
    if (c >= 48 && c <= 57) { c - 48 }
    else if (c >= 97 && c <= 102) { c - 97 + 10 }
    else if (c >= 65 && c <= 70) { c - 65 + 10 }
    else { 0 - 1 }
};

def hex_of(v: long) -> str {
    let d = "0123456789abcdef";
    chr(d[v >> 4]) + chr(d[v & 15])
};

// A code point as UTF-8 (RFC 3629): one to four bytes.
def utf8_of(cp: long) -> [byte] {
    let out: [byte] = [];
    if (cp < 128) { out += cp; }
    else if (cp < 2048) {
        out += 192 + (cp >> 6);
        out += 128 + (cp & 63);
    } else if (cp < 65536) {
        out += 224 + (cp >> 12);
        out += 128 + ((cp >> 6) & 63);
        out += 128 + (cp & 63);
    } else {
        out += 240 + (cp >> 18);
        out += 128 + ((cp >> 12) & 63);
        out += 128 + ((cp >> 6) & 63);
        out += 128 + (cp & 63);
    };
    out
};

// ── the parse helpers ─────────────────────────────────────────────────────

def perr_at(p: PP, msg: str) -> RErr {
    if (p.err == "") { p.err = msg + " at byte " + tostring(p.pos); };
    { k: K_ERR }
};

def perr(p: PP, msg: str) -> RErr {
    if (p.err == "") { p.err = msg; };
    { k: K_ERR }
};

// The byte at the cursor, -1 at the end (byte_at traps, and the cursor may sit
// there).
def peek(p: PP) -> long {
    if (p.pos < len(p.pat)) { byte_at(p.pat, p.pos) } else { 0 - 1 }
};

def peek_at(p: PP, k: long) -> long {
    let i = p.pos + k;
    if (i < len(p.pat)) { byte_at(p.pat, i) } else { 0 - 1 }
};

def eat(p: PP, c: long) -> bool {
    if (peek(p) == c) { p.pos = p.pos + 1; true } else { false }
};

def name_start_p(c: long) -> bool {(c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 };
def name_byte_p(c: long) -> bool { name_start_p(c) || is_digit_byte(c) };

def read_name(p: PP) -> str {
    let out = "";
    while (name_byte_p(peek(p))) {
        out += chr(peek(p));
        p.pos = p.pos + 1;
    };
    out
};

def read_int(p: PP) -> long {
    let v = 0;
    while (is_digit_byte(peek(p))) {
        v = v * 10 + (peek(p) - 48);
        p.pos = p.pos + 1;
    };
    v
};

// The bytes \c names, with the cursor on the c: \n \r \t \f \v \a \0 \xHH
// \x{H+}, or a punctuation byte as itself. [] on an error (p.err set).
def esc_bytes(p: PP) -> [byte] {
    let out: [byte] = [];
    let c = peek(p);
    if (c < 0) { perr_at(p, "pattern ends with a backslash"); return out; };
    if (c == 110) { out += 10; p.pos = p.pos + 1; }
    else if (c == 114) { out += 13; p.pos = p.pos + 1; }
    else if (c == 116) { out += 9; p.pos = p.pos + 1; }
    else if (c == 102) { out += 12; p.pos = p.pos + 1; }
    else if (c == 118) { out += 11; p.pos = p.pos + 1; }
    else if (c == 97) { out += 7; p.pos = p.pos + 1; }
    else if (c == 48) { out += 0; p.pos = p.pos + 1; }
    else if (c == 120) { p.pos = p.pos + 1; esc_hex(p, out); }
    else if (escapable_p(c)) { out += c; p.pos = p.pos + 1; }
    else { perr_at(p, "unknown escape \\" + chr(c)); };
    out
};

// The \x… half of an escape, appended to out.
def esc_hex(p: PP, out: [byte]) -> long {
    if (eat(p, 123)) {
        let cp = 0;
        let n = 0;
        while (hex_val(peek(p)) >= 0) {
            cp = cp * 16 + hex_val(peek(p));
            n = n + 1;
            p.pos = p.pos + 1;
        };
        if (n == 0) { perr_at(p, "a \\x{} needs at least one hex digit"); }
        else if (!eat(p, 125)) { perr_at(p, "a \\x{ is not closed"); }
        else if (cp > 1114111) { perr_at(p, "a \\x{} value must be at most 0x10ffff"); }
        else if (cp >= 55296 && cp <= 57343) { perr_at(p, "a \\x{} value must not be a surrogate"); }
        else {
            let bs = utf8_of(cp);
            let i = 0;
            while (i < len(bs)) { out += bs[i]; i = i + 1; };
        };
    } else {
        let hi = hex_val(peek(p));
        let lo = hex_val(peek_at(p, 1));
        if (hi < 0 || lo < 0) {
            perr_at(p, "a \\x needs two hex digits");
        } else {
            out += hi * 16 + lo;
            p.pos = p.pos + 2;
        };
    };
    0
};

// \d \w \s and their negations, added to bm: 1 when it was one of them, 0 when
// the byte was not a shorthand at all. ASCII, as everywhere else in the tree.
def shorthand(c: long, bm: [byte; 32]) -> long {
    let out = 0;
    if (c == 100 || c == 68) {
        set_range(bm, 48, 57);
        if (c == 68) { set_invert(bm); };
        out = 1;
    } else if (c == 119 || c == 87) {
        set_range(bm, 48, 57);
        set_range(bm, 65, 90);
        set_range(bm, 97, 122);
        set_bit(bm, 95);
        if (c == 87) { set_invert(bm); };
        out = 1;
    } else if (c == 115 || c == 83) {
        set_bit(bm, 32); set_bit(bm, 9); set_bit(bm, 10);
        set_bit(bm, 11); set_bit(bm, 12); set_bit(bm, 13);
        if (c == 83) { set_invert(bm); };
        out = 1;
    };
    out
};

// One of the class shorthands (\d \w \s) as a bare byte, 1 for a letter, a
// digit or _ ; a POSIX class's, 2; an escape's byte, 3; anything else that is a
// metacharacter, 4. 0 means "not a shorthand".
def shorthand_kind(c: long) -> long {
    let out = 0;
    if (c == 100 || c == 68 || c == 119 || c == 87 || c == 115 || c == 83) { out = 1; }
    else if (c == 112 || c == 80) { out = 2; }
    else if (c == 92) { out = 3; }
    else if (c == 42 || c == 43 || c == 63 || c == 123 || c == 125) { out = 4; };
    out
};

// [:name:] inside a [...] , added to bm; false on an unknown name (p.err set).
def posix_class(p: PP, bm: [byte; 32]) -> bool {
    let at = p.pos;
    p.pos = p.pos + 2;                      // "[:"
    let neg = false;
    if (eat(p, 94)) { neg = true; };
    let name = read_name(p);
    if (!eat(p, 58) || !eat(p, 93)) {
        p.pos = at;
        perr_at(p, "unterminated character class");
        return false;
    };
    let known = true;
    if (name == "alnum") { set_range(bm, 48, 57); set_range(bm, 65, 90); set_range(bm, 97, 122); }
    else if (name == "alpha") { set_range(bm, 65, 90); set_range(bm, 97, 122); }
    else if (name == "ascii") { set_range(bm, 0, 127); }
    else if (name == "blank") { set_bit(bm, 32); set_bit(bm, 9); }
    else if (name == "cntrl") { set_range(bm, 0, 31); set_bit(bm, 127); }
    else if (name == "digit") { set_range(bm, 48, 57); }
    else if (name == "graph") { set_range(bm, 33, 126); }
    else if (name == "lower") { set_range(bm, 97, 122); }
    else if (name == "print") { set_range(bm, 32, 126); }
    else if (name == "punct") {
        set_range(bm, 33, 47); set_range(bm, 58, 64);
        set_range(bm, 91, 96); set_range(bm, 123, 126);
    }
    else if (name == "space") {
        set_bit(bm, 32); set_bit(bm, 9); set_bit(bm, 10);
        set_bit(bm, 11); set_bit(bm, 12); set_bit(bm, 13);
    }
    else if (name == "upper") { set_range(bm, 65, 90); }
    else if (name == "word") {
        set_range(bm, 48, 57); set_range(bm, 65, 90);
        set_range(bm, 97, 122); set_bit(bm, 95);
    }
    else if (name == "xdigit") {
        set_range(bm, 48, 57); set_range(bm, 65, 70); set_range(bm, 97, 102);
    } else { known = false; };
    if (!known) {
        p.pos = at;
        perr_at(p, "unknown class [:" + name + ":]");
        return false;
    };
    if (neg) { set_invert(bm); };
    true
};

// ── one item of a [...] ───────────────────────────────────────────────────
// Adds its bytes to bm and returns the single byte it stands for, -1 when it
// stands for several (a shorthand, a POSIX class, \x{...}, or a letter under
// (?i), which is two bytes), -2 on an error (p.err set). `fold` says whether a
// literal byte here may case-fold: a range's endpoint may not, or `[a-z]` under
// (?i) would stop being a range.
def class_item(p: PP, bm: [byte; 32], fold: bool) -> long {
    let c = peek(p);
    if (c < 0) { return 0 - 2; };
    let sk = shorthand_kind(c);
    if (c == 91 && peek_at(p, 1) == 58) {
        if (!posix_class(p, bm)) { return 0 - 2; };
        return 0 - 1;
    };
    if (sk == 1) {
        p.pos = p.pos + 1;
        shorthand(c, bm);
        return 0 - 1;
    };
    if (c == 92) {
        p.pos = p.pos + 1;
        let e = peek(p);
        if (shorthand_kind(e) == 1) {
            p.pos = p.pos + 1;
            shorthand(e, bm);
            return 0 - 1;
        };
        if (e == 98) {                       // \b is a backspace in here
            set_bit(bm, 8);
            p.pos = p.pos + 1;
            return 8;
        };
        let bs = esc_bytes(p);
        let i = 0;
        while (i < len(bs)) { set_bit(bm, bs[i]); i = i + 1; };
        if (len(bs) != 1) { return 0 - 1; };
        return bs[0];
    };
    p.pos = p.pos + 1;
    if (fold && p.icase) {
        add_byte(p, bm, c);
        0 - 1
    } else {
        set_bit(bm, c);
        c
    }
};

// ── [...] ─────────────────────────────────────────────────────────────────
def p_class(p: PP) -> RE {
    let bm: [byte; 32] = [0; 32];
    p.pos = p.pos + 1;                       // the '['
    let neg = false;
    if (eat(p, 94)) { neg = true; };
    let first = true;
    let go = true;
    while (go) {
        let c = peek(p);
        if (c < 0) {
            perr_at(p, "unterminated character class");
            go = false;
        } else if (c == 93 && !first) {
            p.pos = p.pos + 1;
            go = false;
        } else {
            // an item, and then a range if a '-' follows it
            let lo = class_item(p, bm, true);
            first = false;
            if (p.err != "") {
                go = false;
            } else {
                let dash = peek(p) == 45 && peek_at(p, 1) >= 0 && peek_at(p, 1) != 93;
                if (dash) {
                    p.pos = p.pos + 1;
                    let hi = class_item(p, bm, false);
                    if (hi < 0) {
                        perr_at(p, "a range needs two bytes");
                        go = false;
                    } else if (hi < lo) {
                        perr_at(p, "a range is out of order");
                        go = false;
                    } else {
                        set_range(bm, lo, hi);
                        if (p.icase) {
                            let f = lo;
                            while (f <= hi) { add_byte(p, bm, f); f = f + 1; };
                        };
                    };
                };
            };
        };
    };
    if (p.err != "") { return { k: K_ERR }; };
    if (neg) { set_invert(bm); };
    { k: K_SET, set: add_class(p, bm) }
};

// ── ( … ) and everything spelled (?… ──────────────────────────────────────

// (?i) (?is: … ): the flags for the rest of the enclosing group. 1 when the
// ')' closed them (the flags stand where they were written), 2 when a ':' did
// and a group follows, 0 on an error (p.err set).
def p_flags(p: PP) -> long {
    p.pos = p.pos + 2;                       // "(?"
    let any = false;
    let closed = 41;
    let go = true;
    while (go) {
        let c = peek(p);
        if (c == 41) { p.pos = p.pos + 1; closed = 41; go = false; }
        else if (c == 58) { p.pos = p.pos + 1; closed = 58; go = false; }
        else if (c == 45) { perr_at(p, "a flag cannot be turned off"); go = false; }
        else if (c == 105) { p.icase = true; any = true; p.pos = p.pos + 1; }
        else if (c == 115) { p.dotall = true; any = true; p.pos = p.pos + 1; }
        else if (c == 109) { p.multiline = true; any = true; p.pos = p.pos + 1; }
        else {
            if (c < 0) { perr_at(p, "pattern ends inside a (? flag"); }
            else { perr_at(p, "unknown flag '" + chr(c) + "'"); };
            go = false;
        };
    };
    if (p.err != "") { return 0; };
    if (!any) { return 0; };
    if (closed == 58) { 2 } else { 1 }
};

// ( … ) given that the '(' is behind us: the body, the ')', and a group
// around it when num is not 0.
def p_group_tail(p: PP, num: long, d: long) -> RE {
    let item = p_alt(p, d + 1);
    if (p.err != "") { return { k: K_ERR }; };
    if (!eat(p, 41)) {
        perr_at(p, "unterminated group");
        return { k: K_ERR };
    };
    if (num == 0) { return item; };
    { k: K_GROUP, num: num, item: item }
};

// (?= … ) (?! … ) (?<= … ) (?<! … ): `skip` is how far past the '(' the body is.
// How many of them the pattern has is counted off the tree afterwards (see
// count_looks), not here.
def enter_look(p: PP, kind: long, skip: long, d: long) -> RE {
    p.pos = p.pos + skip;
    p_look(p, kind, d)
};

// (?= … ) (?! … ) (?<= … ) (?<! … ), given the prefix is behind us. A group
// inside one is an error: a NFA simulation has no path to give it to.
// How many lookarounds the pattern has, counted where they are written. It is a
// total rather than a nesting depth on purpose: a lookaround's walk nests inside
// the walk around it, so a total of at most MAX_LOOK bounds the nesting too, and
// the limit can be refused while compiling — where a wrong answer is a message,
// not a silent mis-match. (look_ok's counter is the belt to this braces.)
def p_look(p: PP, kind: long, d: long) -> RE {
    let item = p_alt(p, d + 1);
    if (p.err != "") { return { k: K_ERR }; };
    if (!eat(p, 41)) {
        perr_at(p, "unterminated group");
        return { k: K_ERR };
    };
    if (has_group(item)) {
        perr_at(p, "a group cannot be inside a lookaround");
        return { k: K_ERR };
    };
    let w = 0;
    if (kind == 3 || kind == 4) {
        w = width(item);
        if (w <= 0) {
            perr_at(p, "lookbehind must be a fixed width");
            return { k: K_ERR };
        };
    };
    { k: K_LOOK, kind: kind, width: w, item: item }
};

// The group number for the next '(' — its own number is taken before the body
// is parsed, so (a(b)) numbers the outer group first.
def next_group(p: PP) -> long {
    if (p.groups >= MAX_GROUPS) {
        if (p.err == "") { p.err = "more than " + tostring(MAX_GROUPS) + " capture groups"; };
        return 0;
    };
    p.groups = p.groups + 1;
    p.groups
};

// (?<name> … ), which also takes the number and the name.
def p_named(p: PP, d: long) -> RE {
    if (!name_start_p(peek(p))) {
        perr_at(p, "a group name must start with a letter or _");
        return { k: K_ERR };
    };
    let name = read_name(p);
    if (!eat(p, 62)) {
        perr_at(p, "a group name must end with >");
        return { k: K_ERR };
    };
    if (p.names[name] != none) {
        perr_at(p, "duplicate group name '" + name + "'");
        return { k: K_ERR };
    };
    let num = next_group(p);
    if (p.err != "") { return { k: K_ERR }; };
    p.names[name] = num;
    p_group_tail(p, num, d)
};

def p_atom(p: PP, d: long) -> RE {
    let c = peek(p);
    if (c < 0) { return { k: K_ERR }; };
    if (c == 40) {
        let k1 = peek_at(p, 1);
        if (k1 != 63) {
            p.pos = p.pos + 1;
            return p_group_tail(p, next_group(p), d);
        };
        let k2 = peek_at(p, 2);
        if (k2 == 58) { p.pos = p.pos + 3; return p_group_tail(p, 0, d); };         // (?: … )
        if (k2 == 61) { p.pos = p.pos + 3; return p_look(p, 1, d); };
        if (k2 == 33) { p.pos = p.pos + 3; return p_look(p, 2, d); };              // (?! … )
        if (k2 == 60 && (peek_at(p, 3) == 61 || peek_at(p, 3) == 33)) {
            let kind = 3;
            if (peek_at(p, 3) == 33) { kind = 4; };
            p.pos = p.pos + 4;
            return p_look(p, kind, d);
        };
        if (k2 == 60) { p.pos = p.pos + 3; return p_named(p, d); };               // (?<name> … )
        let how = p_flags(p);
        if (how == 0) {
            p.pos = p.pos - 2;                  // point at the ( again
            return perr_at(p, "unknown (? construct");
        };
        if (how == 2) {                          // (?is: … ): restore the flags after
            let icase = p.icase;
            let dotall = p.dotall;
            let multiline = p.multiline;
            let item = p_alt(p, d + 1);
            if (p.err != "") { return { k: K_ERR }; };
            if (!eat(p, 41)) {
                perr_at(p, "unterminated group");
                return { k: K_ERR };
            };
            p.icase = icase;
            p.dotall = dotall;
            p.multiline = multiline;
            return item;
        };
        return { k: K_SEQ, items: [] };        // (?i) on its own matches nothing
    };
    if (c == 91) { return p_class(p); };
    if (c == 46) {                              // .
        p.pos = p.pos + 1;
        let bm: [byte; 32] = [0; 32];
        if (p.dotall) { set_all(bm); } else { set_all_but(bm, 10); };
        return { k: K_SET, set: add_class(p, bm) };
    };
    if (c == 92 || c == 94 || c == 36) { return p_esc_atom(p); };
    if (c == 41) { perr_at(p, "unbalanced )"); return { k: K_ERR }; };
    if (c == 124 || c == 42 || c == 43 || c == 63) {
        perr_at(p, "nothing to repeat");
        return { k: K_ERR };
    };
    // anything else — including a lone ']' or '{' — is itself
    p.pos = p.pos + 1;
    let bm: [byte; 32] = [0; 32];
    add_byte(p, bm, c);
    { k: K_SET, set: add_class(p, bm) }
};

// One escape outside a class. A bare ^ or $ is an anchor, \d \w \s \b \B \A \z
// are the named ones, and \1..\9 is a backreference — which this engine has no
// path for. A bare digit is a literal byte (PCRE's rule), so `a{,3}` is those
// four bytes rather than a broken repetition.
def p_esc_atom(p: PP) -> RE {
    let c = peek(p);
    if (c == 94) {
        p.pos = p.pos + 1;
        if (p.multiline) { return { k: K_AS, kind: 3 }; };
        return { k: K_AS, kind: 1 };
    };
    if (c == 36) {
        p.pos = p.pos + 1;
        if (p.multiline) { return { k: K_AS, kind: 4 }; };
        return { k: K_AS, kind: 2 };
    };
    if (c != 92) { return { k: K_ERR }; };
    p.pos = p.pos + 1;
    let e = peek(p);
    if (e >= 49 && e <= 57) {
        perr_at(p, "a backreference is not supported");
        return { k: K_ERR };
    };
    if (e == 98) { p.pos = p.pos + 1; return { k: K_AS, kind: 5 }; };
    if (e == 66) { p.pos = p.pos + 1; return { k: K_AS, kind: 6 }; };
    if (e == 65) { p.pos = p.pos + 1; return { k: K_AS, kind: 1 }; };
    if (e == 122) { p.pos = p.pos + 1; return { k: K_AS, kind: 2 }; };
    // an ESCAPED ^ or $ is a literal byte (esc_bytes takes it); only a bare one
    // is an anchor, which p_atom's caller handled
    let bm: [byte; 32] = [0; 32];
    if (shorthand(e, bm) > 0) {
        p.pos = p.pos + 1;
        return { k: K_SET, set: add_class(p, bm) };
    };
    // \x{…} is several bytes, and they have to follow each other
    let bs = esc_bytes(p);
    if (p.err != "") { return { k: K_ERR }; };
    let items: [RE] = [];
    let i = 0;
    while (i < len(bs)) {
        let one: [byte; 32] = [0; 32];
        add_byte(p, one, bs[i]);
        items += { k: K_SET, set: add_class(p, one) };
        i = i + 1;
    };
    if (len(items) == 1) { return items[0]; };
    { k: K_SEQ, items: items }
};

// ── a repetition ──────────────────────────────────────────────────────────
// * + ? {n} {n,} {n,m}, each of them optionally lazy with a trailing '?', and
// possessive with a trailing '+' (which is an error: it needs backtracking to
// mean anything). A '{' that does not open a valid repetition is a literal byte
// (Python's rule), so only a digit after it makes one a repetition — and then a
// broken one is an error rather than a literal.
def p_rep(p: PP, atom: RE) -> RE {
    let c = peek(p);
    let lo = 0;
    let hi = 0;
    let any = false;
    if (c == 42) { p.pos = p.pos + 1; lo = 0; hi = 0 - 1; any = true; }
    else if (c == 43) { p.pos = p.pos + 1; lo = 1; hi = 0 - 1; any = true; }
    else if (c == 63) { p.pos = p.pos + 1; lo = 0; hi = 1; any = true; }
    else if (c == 123 && is_digit_byte(peek_at(p, 1))) {
        // the cursor is past the '}' by the time the checks below run
        p.pos = p.pos + 1;
        lo = read_int(p);
        if (eat(p, 44)) {
            if (is_digit_byte(peek(p))) { hi = read_int(p); } else { hi = 0 - 1; };
        } else { hi = lo; };
        if (p.err == "" && !eat(p, 125)) {
            perr_at(p, "bad repetition count");
        } else if (p.err == "" && (lo > MAX_REPEAT || hi > MAX_REPEAT)) {
            perr_at(p, "a repetition count must be at most " + tostring(MAX_REPEAT));
        } else if (p.err == "" && hi >= 0 && hi < lo) {
            perr_at(p, "a repetition count is out of order");
        };
        any = true;
    };
    if (p.err != "") { return { k: K_ERR }; };
    if (!any) { return atom; };
    let greedy = true;
    if (eat(p, 63)) { greedy = false; };
    let nx = peek(p);
    if (nx == 43 && hi == 0 - 1) {
        perr_at(p, "a repetition cannot be possessive");
        return { k: K_ERR };
    };
    if (nx == 42 || nx == 43 || nx == 63 || (nx == 123 && is_digit_byte(peek_at(p, 1)))) {
        perr_at(p, "two repetitions in a row");
        return { k: K_ERR };
    };
    { k: K_REP, min: lo, max: hi, greedy: greedy, item: atom }
};

// ── the parser ────────────────────────────────────────────────────────────
//   alt := seq ("|" seq)*     seq := (atom repetition?)*     atom := see p_atom
// `d` is the ( ) nesting depth, for the one recursion the machine stack has to
// survive.

def p_alt(p: PP, d: long) -> RE {
    if (d > MAX_DEPTH) {
        return perr_at(p, "pattern nested more than " + tostring(MAX_DEPTH) + " deep");
    };
    let alts: [RE] = [];
    alts += p_seq(p, d);
    while (p.err == "" && peek(p) == 124) {
        p.pos = p.pos + 1;
        alts += p_seq(p, d);
    };
    if (p.err != "") { return { k: K_ERR }; };
    if (len(alts) == 1) { return alts[0]; };
    { k: K_ALT, alts: alts }
};

def p_seq(p: PP, d: long) -> RE {
    if (d > MAX_DEPTH) {
        return perr_at(p, "pattern nested more than " + tostring(MAX_DEPTH) + " deep");
    };
    let items: [RE] = [];
    let go = true;
    while (go) {
        let c = peek(p);
        if (c < 0 || c == 124 || c == 41) {
            go = false;
        } else {
            let atom = p_atom(p, d);
            if (p.err != "") {
                go = false;
            } else {
                items += p_rep(p, atom);
                if (p.err != "") { go = false; };
            };
        };
    };
    if (p.err != "") { return { k: K_ERR }; };
    { k: K_SEQ, items: items }
};

// ── the analyses: the lookbehind's width and the VM's two prefilters ──────

// How many lookarounds this tree has. It is a total rather than a nesting depth
// on purpose: a lookaround's walk nests inside the walk around it, so a total of
// at most MAX_LOOK bounds the nesting too — and refusing it while compiling means
// the answer is a message, where refusing it at run time would mean a wrong
// match. Counted here, off the tree, rather than in the parse state.
def count_looks(n: RE) -> long {
    let out = 0;
    if (n.k == K_LOOK) {
        let l: RLook = n;
        out = 1 + count_looks(l.item);
    } else if (n.k == K_SEQ) {
        let s: RSeq = n;
        foreach (it in s.items) { out = out + count_looks(it); };
    } else if (n.k == K_ALT) {
        let a: RAlt = n;
        foreach (it in a.alts) { out = out + count_looks(it); };
    } else if (n.k == K_REP) {
        let r: RRep = n;
        out = count_looks(r.item);
    } else if (n.k == K_GROUP) {
        let g: RGroup = n;
        out = count_looks(g.item);
    };
    out
};

// Does this tree have a capturing group in it? (A lookaround may not.)
def has_group(n: RE) -> bool {
    if (n.k == K_GROUP) { true }
    else if (n.k == K_SEQ) { let s: RSeq = n; any_group(s.items) }
    else if (n.k == K_ALT) { let a: RAlt = n; any_group(a.alts) }
    else if (n.k == K_REP) { let r: RRep = n; has_group(r.item) }
    else if (n.k == K_LOOK) { let l: RLook = n; has_group(l.item) }
    else { false }
};

def any_group(xs: [RE]) -> bool {
    let out = false;
    foreach (x in xs) {
        if (has_group(x)) { out = true; };
    };
    out
};

// How many bytes this tree always matches, -1 when that is not a fixed number.
def width(n: RE) -> long {
    let out = 0 - 1;
    if (n.k == K_SET) { out = 1; }
    else if (n.k == K_AS) { out = 0; }
    else if (n.k == K_LOOK) { out = 0; }
    else if (n.k == K_GROUP) {
        let g: RGroup = n;
        out = width(g.item);
    } else if (n.k == K_SEQ) {
        let s: RSeq = n;
        let w = 0;
        let ok = true;
        let i = 0;
        while (i < len(s.items)) {
            let x = width(s.items[i]);
            if (x < 0) { ok = false; i = len(s.items); } else { w = w + x; i = i + 1; };
        };
        if (ok) { out = w; };
    } else if (n.k == K_ALT) {
        let a: RAlt = n;
        let w0 = 0;
        let ok = len(a.alts) > 0;
        let i = 0;
        while (i < len(a.alts)) {
            let x = width(a.alts[i]);
            if (i == 0) { w0 = x; }
            if (x != w0) { ok = false; };
            i = i + 1;
        };
        if (ok && w0 >= 0) { out = w0; };
    } else if (n.k == K_REP) {
        let r: RRep = n;
        let x = width(r.item);
        if (x >= 0 && r.max >= 0 && r.min == r.max) { out = x * r.min; };
    };
    out
};

// Every byte a match may begin with, ORed into acc; true when the tree can
// match nothing at all (then the caller must try every position). An assertion
// or a lookahead examines bytes where the match starts, so what it constrains
// goes in too: a smaller set would skip a match, and that is the one mistake a
// prefilter must not make.
def first_of(n: RE, p: PP, acc: [byte; 32]) -> bool {
    let nullable = false;
    if (n.k == K_SET) {
        let s: RSet = n;
        let tmp: [byte; 32] = [0; 32];
        let i = 0;
        while (i < 32) { tmp[i] = p.classes[s.set * 32 + i]; i = i + 1; };
        set_or(acc, tmp);
        nullable = false;
    } else if (n.k == K_AS) {
        let a: RAs = n;
        if (a.kind == 5 || a.kind == 6) { set_all(acc); };
        nullable = true;
    } else if (n.k == K_LOOK) {
        let l: RLook = n;
        // a negative lookaround is satisfied by its sub-program FAILING, so it
        // always matches and constrains no byte here; a positive one is the
        // sub-program's own first set and its own nullability
        if (l.kind == 1) { nullable = first_of(l.item, p, acc); } else { nullable = true; };
    } else if (n.k == K_GROUP) {
        let g: RGroup = n;
        nullable = first_of(g.item, p, acc);
    } else if (n.k == K_SEQ) {
        let s: RSeq = n;
        nullable = true;
        let i = 0;
        while (i < len(s.items) && nullable) {
            nullable = first_of(s.items[i], p, acc);
            i = i + 1;
        };
    } else if (n.k == K_ALT) {
        let a: RAlt = n;
        nullable = false;
        let i = 0;
        while (i < len(a.alts)) {
            if (first_of(a.alts[i], p, acc)) { nullable = true; };
            i = i + 1;
        };
    } else if (n.k == K_REP) {
        let r: RRep = n;
        let item_null = first_of(r.item, p, acc);
        nullable = (r.min == 0) || item_null;
    } else { nullable = true; };
    nullable
};

// The bytes every match must begin with, when the pattern opens with a run of
// single-byte literals ("" when it does not). A search then goes straight to
// the next occurrence of them.
def prefix_of(n: RE, p: PP) -> str {
    let out = "";
    if (n.k != K_SEQ) { return out; };
    let s: RSeq = n;
    let i = 0;
    let go = true;
    while (go && i < len(s.items)) {
        let it = s.items[i];
        if (it.k != K_SET) {
            go = false;
        } else {
            let st: RSet = it;
            let b = class_one(p.classes, st.set);
            if (b < 0) { go = false; } else { out += chr(b); };
            i = i + 1;
        };
    };
    out
};

// Bytes every match must contain, from the first single byte that every match
// has to reach: the mandatory items of a sequence, through groups and through
// repetitions of one or more, and not into an alternation (whose branches may
// not share it). "" when there is no such byte.
//
// This is what stops a scan of a large subject for a pattern that cannot
// possibly match: `(\w+)@(\w+)` over 8 MB with no '@' in it answers from one
// scan of the subject, where the first-set skip alone would run the machine at
// every word byte and, having groups, allocate a capture vector at each.
def required_of(n: RE, p: PP) -> str {
    let out = "";
    if (n.k == K_SEQ) {
        let s: RSeq = n;
        let i = 0;
        while (i < len(s.items) && out == "") {
            out = required_of(s.items[i], p);
            i = i + 1;
        };
    } else if (n.k == K_GROUP) {
        let g: RGroup = n;
        out = required_of(g.item, p);
    } else if (n.k == K_REP) {
        let r: RRep = n;
        if (r.min > 0) { out = required_of(r.item, p); };
    } else if (n.k == K_SET) {
        let st: RSet = n;
        let b = class_one(p.classes, st.set);
        if (b >= 0) { out = chr(b); };
    };
    out
};

// Only position 0 can match: the pattern opens with an absolute ^ or \A.
def anchored_p(n: RE) -> bool {
    let out = false;
    if (n.k == K_SEQ) {
        let s: RSeq = n;
        if (len(s.items) > 0) {
            let f = s.items[0];
            if (f.k == K_AS) {
                let a: RAs = f;
                out = (a.kind == 1);
            };
        };
    } else if (n.k == K_AS) {
        let a: RAs = n;
        out = (a.kind == 1);
    };
    out
};

// ── the emitter ───────────────────────────────────────────────────────────
// Straight-line code out of the tree. A repetition expands into copies, so the
// machine needs no per-thread counters (RE2's choice too); the expansion is
// iterative, so a {1000} costs instructions and not stack.

// A new instruction, and where it is.
def emit1(out: [long], op: long, a: long) -> long {
    let pc = len(out);
    out += op;
    out += a;
    out += 0;
    pc
};

def emit2(out: [long], op: long, a: long, b: long) -> long {
    let pc = len(out);
    out += op;
    out += a;
    out += b;
    pc
};

def patch(out: [long], pc: long, slot: long, v: long) -> long {
    out[pc + slot] = v;
    0
};

// item up to k times, each one optional: x(x(x)?)? — greedy prefers the item,
// lazy the way out. Every level but the last falls through to the next, so the
// chain is built by patching the previous level's two exits.
def emit_opt(out: [long], item: RE, k: long, greedy: bool) -> long {
    if (k <= 0) { return 0; };
    let next_slot = 2;                       // where the next level goes
    if (!greedy) { next_slot = 1; };
    let prev_jmp = 0 - 1;
    let prev_split = 0 - 1;
    let i = 0;
    while (i < k) {
        let sp = emit2(out, 2, 0, 0);
        if (prev_jmp >= 0) { patch(out, prev_jmp, 1, sp); };
        if (prev_split >= 0) { patch(out, prev_split, next_slot, sp); };
        patch(out, sp, 3 - next_slot, len(out));      // the item starts here
        emit(item, out);
        prev_jmp = emit1(out, 3, 0);
        prev_split = sp;
        i = i + 1;
    };
    let cont = len(out);
    patch(out, prev_jmp, 1, cont);
    patch(out, prev_split, next_slot, cont);
    0
};

// item as often as it will go. The loop head is always the zero-width split,
// because the first iteration is optional (x* may match nothing at all):
//   greedy  l: SPLIT body, out ; body: <item> ; JMP l
//   lazy    l: SPLIT out, body ; body: <item> ; JMP l
def emit_loop(out: [long], item: RE, greedy: bool) -> long {
    let l = len(out);
    let sp = emit2(out, 2, 0, 0);
    emit(item, out);
    emit1(out, 3, l);
    if (greedy) {
        patch(out, sp, 1, l + 3);        // another one first
        patch(out, sp, 2, len(out));
    } else {
        patch(out, sp, 1, len(out));     // the way out first
        patch(out, sp, 2, l + 3);
    };
    0
};

// The min copies, then a loop (max -1) or the optional chain.
def emit_rep(out: [long], r: RRep) -> long {
    if (r.max == 0) { return 0; };
    let i = 0;
    while (i < r.min) {
        emit(r.item, out);
        i = i + 1;
    };
    if (r.max < 0) {
        emit_loop(out, r.item, r.greedy);
    } else {
        emit_opt(out, r.item, r.max - r.min, r.greedy);
    };
    0
};

// a|b|c — try each branch, then jump past them all.
def emit_alt(out: [long], alts: [RE]) -> long {
    let jumps: [long] = [];
    let i = 0;
    let n = len(alts);
    while (i < n - 1) {
        let sp = emit2(out, 2, 0, 0);
        patch(out, sp, 1, len(out));
        emit(alts[i], out);
        jumps += emit1(out, 3, 0);
        patch(out, sp, 2, len(out));
        i = i + 1;
    };
    emit(alts[n - 1], out);
    let cont = len(out);
    foreach (jm in jumps) { patch(out, jm, 1, cont); };
    0
};

def emit(node: RE, out: [long]) -> long {
    if (node.k == K_SET) {
        let s: RSet = node;
        emit1(out, 1, s.set);
    } else if (node.k == K_SEQ) {
        let s: RSeq = node;
        foreach (it in s.items) { emit(it, out); };
    } else if (node.k == K_ALT) {
        let a: RAlt = node;
        emit_alt(out, a.alts);
    } else if (node.k == K_REP) {
        let r: RRep = node;
        emit_rep(out, r);
    } else if (node.k == K_GROUP) {
        let g: RGroup = node;
        emit1(out, 4, 2 * g.num);
        emit(g.item, out);
        emit1(out, 4, 2 * g.num + 1);
    } else if (node.k == K_AS) {
        let a: RAs = node;
        emit1(out, 5, a.kind);
    } else if (node.k == K_LOOK) {
        let l: RLook = node;
        let pc = emit2(out, 6, l.width * 8 + l.kind, 0);
        emit(l.item, out);
        emit1(out, 7, 0);
        patch(out, pc, 2, len(out));
    };
    0
};

// ── the machine ───────────────────────────────────────────────────────────

def new_run(re: Re, s: str) -> Run {
    let seen: [long] = [];
    let i = 0;
    while (i < len(re.prog)) { seen += 0; i = i + 1; };
    let ncap = (re.groups + 1) * 2;
    { prog: re.prog, classes: re.classes, subject: s, end: len(s),
        ninst: len(re.prog), ncap: ncap,
        cur_pc: [], cur_cap: [], cur_n: 0, nxt_pc: [], nxt_cap: [], nxt_n: 0,
        seen: seen, gen: 1, wpc: [], wcap: [],
        // both buffers start at their full width: the group-free match path
        // writes hit's two slots directly rather than copying into a vector that
        // has to grow first
        base: [], hit: blank_caps([], ncap), hit_end: 0, want_end: 0 - 1,
        free: [], free_n: 0,
        ok: false, matched: false, look: 0, subs: [] }
};

// A lookaround's own run: the same program and subject, but its own stamps —
// they must not collide with the walk that is running it. It shares the root's
// pool of them (subs is one array, by reference) and knows its own depth.
def new_sub(r: Run, depth: long) -> Run {
    let seen: [long] = [];
    let i = 0;
    while (i < r.ninst) { seen += 0; i = i + 1; };
    { prog: r.prog, classes: r.classes, subject: r.subject, end: r.end,
        ninst: r.ninst, ncap: r.ncap,
        cur_pc: [], cur_cap: [], cur_n: 0, nxt_pc: [], nxt_cap: [], nxt_n: 0,
        seen: seen, gen: 1, wpc: [], wcap: [],
        base: [], hit: blank_caps([], r.ncap), hit_end: 0, want_end: 0 - 1,
        free: [], free_n: 0,
        ok: false, matched: false, look: depth, subs: r.subs }
};

// n slots of "took no part", into dst (which grows once and is then reused).
def blank_caps(dst: [long], n: long) -> [long] {
    let dl = len(dst);
    let i = 0;
    while (i < n) {
        if (i < dl) { dst[i] = 0 - 1; } else { dst += 0 - 1; dl = dl + 1; };
        i = i + 1;
    };
    dst
};

// src's captures into a vector off the pool (a new one when the pool is dry).
// This is what a SAVE needs and what a match costs: on a heap with no free, a
// fresh vector per capture group per step is most of the memory a scan of a
// large subject takes.
def take_caps(r: Run, src: [long], n: long) -> [long] {
    if (r.free_n > 0) {
        r.free_n = r.free_n - 1;
        let got = r.free[r.free_n];
        copy_caps(got, src, n);
        got
    } else {
        clone_caps(src, n)
    }
};

// A vector no thread holds any more, back to the pool.
def drop_caps(r: Run, c: [long]) -> long {
    if (len(c) > 0) {
        if (r.free_n == len(r.free)) { r.free += c; } else { r.free[r.free_n] = c; };
        r.free_n = r.free_n + 1;
    };
    0
};

// How many entries of xs hold c itself (by address: two vectors with equal

// The recycle's question — c is held by exactly one thread of cur and by none of
// nxt — in one pass over each list. Two count_holding calls per thread became
// one call and one pass, which on a group-heavy pattern is a tenth of the scan.
def last_holder(cur: [[long]], ncur: long, nxt: [[long]], nnxt: long, c: [long]) -> bool {
    let a = ptr_addr(c.ptr);
    let mine = 0;
    let i = 0;
    while (i < ncur) {
        if (ptr_addr(cur[i].ptr) == a) { mine = mine + 1; };
        i = i + 1;
    };
    if (mine != 1) { return false; };
    let j = 0;
    while (j < nnxt) {
        if (ptr_addr(nxt[j].ptr) == a) { return false; };
        j = j + 1;
    };
    true
};

// src's captures into dst (which grows once and is then reused).
def copy_caps(dst: [long], src: [long], n: long) -> long {
    if (len(dst) == n && len(src) == n) {
        // both already the right width: no slot needs a length test, which is
        // most of what the general loop below spends
        let i = 0;
        while (i < n) { dst[i] = src[i]; i = i + 1; };
        return 0;
    };
    let dl = len(dst);
    let sl = len(src);
    let i = 0;
    while (i < n) {
        let v = 0 - 1;
        if (i < sl) { v = src[i]; };
        if (i < dl) { dst[i] = v; } else { dst += v; dl = dl + 1; };
        i = i + 1;
    };
    0
};

def clone_caps(c: [long], n: long) -> [long] {
    let out: [long] = [];
    let cl = len(c);
    let i = 0;
    while (i < n) {
        out += (if (i < cl) { c[i] } else { 0 - 1 });
        i = i + 1;
    };
    out
};

// The zero-width closure at pos: follow what consumes nothing until a CLS or a
// MATCH, queueing those into list. pc1 before pc2 the whole way down, so list
// comes out in priority order — which is what makes this leftmost-first rather
// than leftmost-longest, and what lets the first MATCH cut everything queued
// behind it.
//
// The walk is DEPTH-first, and it has to be: a breadth-first one reaches the
// second branch of a split before the first branch's item, so `x*` would record
// its empty match and stop before trying x, and a loop holding a group would
// never queue its body. The stack lives in the Run (r.wpc/r.wcap), grown
// once and reused, so the walk allocates nothing per call — an iterative stack
// rather than recursion, because a lookahead's walk nests inside this one.
//
// Every path carries its own capture vector, and a SAVE always clones: a shared
// one would leak a branch's captures into a sibling that skipped the group —
// `(a)|(b)` on "b" would then report group 1 as matched-and-empty instead of as
// not having taken part. Copying here is what a thread's later SAVE would do
// anyway, so it costs no more than copy-on-write bookkeeping would; a pattern
// with no groups never reaches it.
// The walk's own stack (see add): the closure path being followed, kept in the
// Run so it grows once and is reused by every walk from then on.

// push and queue, inlined: between them they are called ten million times an
// 8 MB scan, and at ~30 instructions of call and argument shuffling apiece that
// was a tenth of a group-free scan. The bodies are the two functions' verbatim.
def add(r: Run, pc0: long, pos: long, caps: [long]) -> long {
    let wpc = r.wpc;
    let wcap = r.wcap;
    let sp = 0;
    if (len(wpc) == 0) { wpc += pc0; wcap += caps; } else { wpc[0] = pc0; wcap[0] = caps; };
    sp = 1;
    while (sp > 0) {
        sp = sp - 1;
        let pc = wpc[sp];
        let c = wcap[sp];
        if (r.seen[pc] != r.gen) {
            r.seen[pc] = r.gen;
            let op = r.prog[pc];
            let n1 = 0 - 1;                     // what to visit next
            let c1 = c;                         // with these captures
            let n2 = 0 - 1;                     // then this, lower priority
            if (op == 3) {
                n1 = r.prog[pc + 1];
            } else if (op == 2) {
                n1 = r.prog[pc + 1];
                n2 = r.prog[pc + 2];
            } else if (op == 4) {
                let c2 = take_caps(r, c, r.ncap);
                c2[r.prog[pc + 1]] = pos;
                n1 = pc + 3;
                c1 = c2;
            } else if (op == 5) {
                if (assert_ok(r, r.prog[pc + 1], pos)) { n1 = pc + 3; };
            } else if (op == 6) {
                if (look_ok(r, r.prog[pc + 1], pc + 3, pos)) { n1 = r.prog[pc + 2]; };
            } else if (op == 1) {
                let nxt_pc = r.nxt_pc;
                let nxt_cap = r.nxt_cap;
                let n = r.nxt_n;
                if (n == len(nxt_pc)) { nxt_pc += pc; nxt_cap += c; } else {
                    nxt_pc[n] = pc;
                    nxt_cap[n] = c;
                };
                r.nxt_n = n + 1;
            } else if (r.want_end < 0 || pos == r.want_end) {
                // 7 MATCH: this thread is the answer, and it cuts the rest
                if (r.ncap == 2) {
                    r.hit[0] = c[0];               // no groups: start and end
                    r.hit[1] = pos;
                } else {
                    copy_caps(r.hit, c, r.ncap);
                    r.hit[1] = pos;
                };
                r.hit_end = pos;
                r.ok = true;
                r.matched = true;
                return 1;
            };
            // a MATCH short of r.want_end is not what full() asked for: keep
            // walking, the way a backtracker would try the next alternative
            if (n2 >= 0) {
                if (sp == len(wpc)) { wpc += n2; wcap += c; } else { wpc[sp] = n2; wcap[sp] = c; };
                sp = sp + 1;
            };
            if (n1 >= 0) {
                if (sp == len(wpc)) { wpc += n1; wcap += c1; } else { wpc[sp] = n1; wcap[sp] = c1; };
                sp = sp + 1;
            };
        };
    };
    0
};

// One byte: every thread in r.cur is at pos, so each consuming one either
// fails on this byte or joins r.nxt for pos + 1. r.ok says a match was found —
// and that is a FALLBACK, not the answer: whatever is already in r.nxt came
// first in priority order, so a match from one of those later REPLACES it (that
// is what makes a greedy `x+` take the longer run). Only when r.nxt runs dry is
// the recorded match the answer, so the thread count is what says whether the
// match can go on at all.
def step(r: Run, pos: long) -> long {
    r.gen = r.gen + 1;
    r.nxt_n = 0;
    r.ok = false;
    // hoisted out of the loop: add() below writes the run's scratch but none of
    // these, so a step reads them once instead of once a thread
    let prog = r.prog;
    let classes = r.classes;
    let subject = r.subject;
    let end = r.end;
    let cur_pc = r.cur_pc;
    let cur_cap = r.cur_cap;
    let cur_n = r.cur_n;
    let i = 0;
    while (i < cur_n && !r.ok) {
        let pc = cur_pc[i];
        let op = prog[pc];
        if (op == 1) {
            // the class bits read here, not through class_has: this is the
            // hottest test in the machine, and the call cost it a tenth of a
            // group-heavy scan
            let k32 = prog[pc + 1] * 32;
            if (pos < end) {
                let c = byte_at(subject, pos);
                if ((classes[k32 + (c >> 3)] & (1 << (c & 7))) != 0) {
                    add(r, pc + 3, pos + 1, cur_cap[i]);
                };
            };
        } else {
            if (r.ncap == 2) {
                r.hit[0] = cur_cap[i][0];         // no groups: start and end
                r.hit[1] = pos;
            } else {
                copy_caps(r.hit, cur_cap[i], r.ncap);
                r.hit[1] = pos;
            };
            r.hit_end = pos;
            r.ok = true;
            r.matched = true;
        };
        i = i + 1;
    };
    // A capture vector this step's threads were the last holders of goes back to
    // the pool: no queued thread took it, and this step's list is about to be
    // the write buffer. Only a pattern with groups has any, so a group-free scan
    // pays nothing for the check.
    //
    // A capture vector this step's threads were the last holders of goes back to
    // the pool: one thread holds it alone (count 1) and no queued thread took
    // it. Only a pattern with groups has any, so a group-free scan pays nothing
    // for the check.
    if (r.ncap > 2) {
        let j = 0;
        let cur = r.cur_cap;
        let ncur = r.cur_n;
        let nxt = r.nxt_cap;
        let nnxt = r.nxt_n;
        while (j < ncur) {
            let c = cur[j];
            if (last_holder(cur, ncur, nxt, nnxt, c)) { drop_caps(r, c); };
            j = j + 1;
        };
    };
    // This step's list becomes the next one's input, and the list just read
    // becomes the buffer to write: the two SWAP rather than alias, because queue
    // writes into nxt at its own index while step reads cur at another, and one
    // array would have them overwrite each other mid-step. Swapping allocates
    // nothing, and nxt_n is reset by the step that follows.
    let old_pc = r.cur_pc;
    let old_cap = r.cur_cap;
    r.cur_pc = r.nxt_pc;
    r.cur_cap = r.nxt_cap;
    r.cur_n = r.nxt_n;
    r.nxt_pc = old_pc;
    r.nxt_cap = old_cap;
    r.cur_n
}

// A match of the program from `from`, anchored at `at`. The first thread's
// closure is walked here rather than by a step: the program may open with a
// SAVE (a group at the front), and a step only steps a CLS.
//
// gen moves on at the start of every run, not only per step, and that matters
// when the first closure finds nothing: a run that never steps would leave the
// stamps as they were, and the next start position would find every pc already
// visited and give up — `\b\w+` against "  hi" would find no `\b` at 0 or 1,
// never step, and so never try 2, where it matches. One stamp per run also
// means one seen[] serves every start position a search tries.
def run_from(r: Run, from: long, at: long, want_end: long) -> bool {
    if (at > r.end) { return false; };          // nothing to match past the end
    r.want_end = want_end;
    r.gen = r.gen + 1;                          // this run's own stamp (see below)
    // the captures a fresh match starts from: r.base, refilled rather than
    // reallocated, since no SAVE writes into it (the first one clones)
    let base = r.base;
    if (len(base) == r.ncap) {
        let i = 0;
        while (i < r.ncap) { base[i] = 0 - 1; i = i + 1; };
    } else {
        base = blank_caps(base, r.ncap);
    };
    base[0] = at;
    r.ok = false;
    r.matched = false;
    r.nxt_n = 0;
    add(r, from, at, base);
    let old_pc = r.cur_pc;                  // the first closure is this step's list
    let old_cap = r.cur_cap;
    r.cur_pc = r.nxt_pc;
    r.cur_cap = r.nxt_cap;
    r.cur_n = r.nxt_n;
    r.nxt_pc = old_pc;
    r.nxt_cap = old_cap;
    let pos = at;
    let go = r.cur_n > 0;
    while (go) {
        if (step(r, pos) == 0) {
            go = false;
        } else {
            pos = pos + 1;
        };
    };
    r.matched
};

def run(r: Run, at: long) -> bool { run_from(r, 0, at, 0 - 1) };

// \b and \B look at the bytes on each side of pos, and past the ends there is
// no word.
def is_word_at(s: str, i: long, end: long) -> bool {
    if (i < 0 || i >= end) { false } else { is_word_byte(byte_at(s, i)) }
};

def assert_ok(r: Run, kind: long, pos: long) -> bool {
    let out = false;
    if (kind == 1) { out = pos == 0; }
    else if (kind == 2) { out = pos == r.end; }
    else if (kind == 3) { out = pos == 0 || (pos > 0 && byte_at(r.subject, pos - 1) == 10); }
    else if (kind == 4) { out = pos == r.end || (pos < r.end && byte_at(r.subject, pos) == 10); }
    else if (kind == 5) { out = is_word_at(r.subject, pos - 1, r.end) != is_word_at(r.subject, pos, r.end); }
    else { out = is_word_at(r.subject, pos - 1, r.end) == is_word_at(r.subject, pos, r.end); };
    out
};

// A lookaround at pos: does its sub-program (from sub, ending in its own
// MATCH) match there? A lookbehind's is of a width fixed at compile time, so
// one anchored run from pos - width answers it. Its own run, because its stamps
// must not collide with the walk that is running it.
def look_ok(r: Run, packed: long, sub: long, pos: long) -> bool {
    // compile refused a pattern nested deeper than MAX_LOOK, so this cannot
    // happen; it stays as the trap that keeps a bug from recursing without end
    r.look = r.look + 1;
    if (r.look > MAX_LOOK) {
        r.look = r.look - 1;
        return false;
    };
    let kind = packed % 8;
    let w = packed / 8;
    let at = pos;
    let ok = false;
    // a lookbehind's sub-program has to end exactly at pos, and needs room for
    // it; with no room it simply did not match, which is what makes the negative
    // form true there and the positive one false
    let fits = true;
    if (kind == 3 || kind == 4) {
        if (w <= 0 || pos < w) { fits = false; } else { at = pos - w; };
    };
    if (fits) {
        // this depth's run, made once and then reused: its stamps are its own
        // and its generation only moves on, so nothing needs clearing
        let d = r.look;
        while (len(r.subs) < d) { r.subs += new_sub(r, len(r.subs)); };
        if (d >= len(r.subs)) { r.subs += new_sub(r, d); };
        let r2 = r.subs[d];
        ok = run_from(r2, sub, at, 0 - 1);
        if (kind == 3 || kind == 4) { ok = ok && r2.hit_end == pos; };
    };
    r.look = r.look - 1;
    if (kind == 2 || kind == 4) { !ok } else { ok }
};

// ── the API ───────────────────────────────────────────────────────────────

// Compile the pattern, or none; check says why. Both run the same pass.
def build(pat: str) -> Built {
    let names: { str => long } = {};
    let p: PP = { pat: pat, pos: 0, err: "",
        icase: false, dotall: false, multiline: false,
        groups: 0, names: names, classes: [] };
    let empty: Re = { pattern: pat, prog: [], classes: [], nclass: 0, first: 0 - 1,
        literal: "", need: "", anchored: false, groups: 0, names: names };
    let node = p_alt(p, 0);
    if (p.err != "") { return { re: empty, err: p.err }; };
    if (p.pos < len(p.pat)) {
        perr_at(p, "unbalanced )");
        return { re: empty, err: p.err };
    };
    let looks = count_looks(node);
    if (looks > MAX_LOOK) {
        perr(p, "more than " + tostring(MAX_LOOK) + " lookarounds in one pattern");
        return { re: empty, err: p.err };
    };
    let out: [long] = [];
    emit(node, out);
    emit1(out, 7, 0);                      // MATCH
    if (len(out) / 3 > MAX_INST) {
        perr(p, "the pattern needs more than " + tostring(MAX_INST) + " instructions");
        return { re: empty, err: p.err };
    };
    // the prefilters: the set a match can begin with, the literal it must begin
    // with, and whether only position 0 can match
    let acc: [byte; 32] = [0; 32];
    let nullable = first_of(node, p, acc);
    let first = 0 - 1;
    if (!nullable && !set_full_p(acc)) { first = add_class(p, acc); };
    let re: Re = { pattern: pat, prog: out, classes: p.classes, nclass: len(p.classes) / 32,
        first: first, literal: prefix_of(node, p), need: required_of(node, p),
        anchored: anchored_p(node), groups: p.groups, names: names };
    { re: re, err: "" }
};

def compile(pat: str) -> Re? {
    let b = build(pat);
    if (b.err != "") { none } else { some(b.re) }
};

def check(pat: str) -> str { build(pat).err };

// QuoteMeta, with a byte that will not print written as \xHH so the pattern
// stays readable instead of carrying a control byte.
def escape(s: str) -> str {
    let out = "";
    let i = 0;
    while (i < len(s)) {
        let c = byte_at(s, i);
        if (is_word_byte(c)) { out += chr(c); }
        else if (c >= 32 && c < 127) { out += chr(92) + chr(c); }
        else { out += chr(92) + "x" + hex_of(c); };
        i = i + 1;
    };
    out
};

// Whether the subject holds the bytes every match must contain. One scan of
// the subject, and it is the whole answer when it does not.
def need_ok(re: Re, s: str) -> bool {
    if (re.need == "") { true } else { find_sub_from(s, re.need, 0) >= 0 }
};

// The byte a first set holds when it holds exactly one, -1 otherwise. A search
// skips on a byte compare instead of a set lookup when it has one.
def first_byte(re: Re) -> long {
    if (re.first < 0) { 0 - 1 } else { class_one(re.classes, re.first) }
};

// The next position at or after `from` where a match could begin, -1 when there
// is none: skip what cannot start one, then run the machine there. This is
// where the leftmost of leftmost-first comes from — the first position that
// matches wins, and within it the machine's priority order decides.
def seek(re: Re, r: Run, s: str, from: long, one: long) -> long {
    let n = len(s);
    let first = re.first;
    let last = n;
    if (first >= 0) { last = n - 1; };      // a match has to consume a byte
    let pos = from;
    let out = 0 - 1;
    let go = pos <= last;
    // hoisted: this loop runs once per match, and the old one read re's fields
    // through the record on every byte it skipped
    let classes = re.classes;
    let literal = re.literal;
    let anchored = re.anchored;
    let k32 = 0;
    if (first >= 0) { k32 = first * 32; };
    while (go) {
        if (first >= 0) {
            // The skip: to the next byte a match can begin with. A compare when
            // the set holds exactly one byte, the class's own bits otherwise —
            // inlined, because calling class_has per skipped byte cost more than
            // the step it was skipping towards.
            if (one >= 0) {
                while (pos < n && byte_at(s, pos) != one) { pos = pos + 1; };
            } else {
                let more = pos < n;
                while (more) {
                    let c = byte_at(s, pos);
                    if ((classes[k32 + (c >> 3)] & (1 << (c & 7))) != 0) {
                        more = false;
                    } else {
                        pos = pos + 1;
                        more = pos < n;
                    };
                };
            };
            if (pos > last) { go = false; };
        };
        if (go && literal != "") {
            let at2 = find_sub_from(s, literal, pos);
            if (at2 < 0) { go = false; } else { pos = at2; };
        };
        if (go) {
            if (run(r, pos)) { out = pos; go = false; }
            else if (anchored) { go = false; }
            else {
                pos = pos + 1;
                if (pos > last) { go = false; };
            };
        };
    };
    out
};

// needle in s at or after `from`, -1 when there is none: the first byte is the
// scan, the rest a compare.
def find_sub_from(s: str, needle: str, from: long) -> long {
    let m = len(needle);
    let n = len(s);
    let out = 0 - 1;
    if (m > 0 && m <= n) {
        let c0 = byte_at(needle, 0);
        let pos = from;
        let go = from + m <= n;
        while (go) {
            while (pos + m <= n && byte_at(s, pos) != c0) { pos = pos + 1; };
            if (pos + m > n) {
                go = false;
            } else {
                let j = 1;
                let ok = true;
                while (j < m) {
                    if (byte_at(s, pos + j) != byte_at(needle, j)) { ok = false; };
                    j = j + 1;
                };
                if (ok) { out = pos; go = false; } else { pos = pos + 1; };
            };
        };
    };
    out
};

def make_match(re: Re, r: Run) -> Match {
    let caps = clone_caps(r.hit, r.ncap);
    let st = caps[0];
    let en = caps[1];
    { subject: r.subject, text: r.subject[st:en], start: st, end: en,
        caps: caps, names: re.names }
};

// The first match at or after `at` (only at `at` when re.anchored), or none.
def search_at(re: Re, s: str, at: long) -> Match? {
    if (at < 0 || at > len(s)) { return none; };
    if (!need_ok(re, s)) { return none; };
    let r = new_run(re, s);
    let st = seek(re, r, s, at, first_byte(re));
    if (st < 0) { none } else { some(make_match(re, r)) }
};

def match_at(re: Re, s: str, at: long) -> Match? {
    if (at < 0 || at > len(s)) { return none; };
    if (!need_ok(re, s)) { return none; };
    if (re.literal != "" && len(re.literal) > len(s) - at) { return none; };
    let r = new_run(re, s);
    if (run(r, at)) { some(make_match(re, r)) } else { none }
};

def match(re: Re, s: str) -> Match? { match_at(re, s, 0) };

// The whole subject, whatever (?m) does to ^ and $ elsewhere in the pattern.
// Not just the first match checked against the end: `a|ab` matches "ab" here,
// because the short branch fails the end anchor and the search goes on, exactly
// as a backtracker would try the next alternative.
def full(re: Re, s: str) -> Match? {
    if (!need_ok(re, s)) { return none; };
    let r = new_run(re, s);
    if (run_from(r, 0, 0, len(s))) { some(make_match(re, r)) } else { none }
};

def search(re: Re, s: str) -> Match? { search_at(re, s, 0) };

def is_match(re: Re, s: str) -> bool {
    if (!need_ok(re, s)) { return false; };
    let r = new_run(re, s);
    seek(re, r, s, 0, first_byte(re)) >= 0
};

// Every non-overlapping match, left to right. An empty match abutting the
// previous one's end is skipped (Go's rule, and CPython's since 3.7) and the
// scan moves on one byte, so `a*` over "baab" gives "", "a", "a", "".
def find(re: Re, s: str, limit: long = -1) -> [Match] {
    let out: [Match] = [];
    if (!need_ok(re, s)) { return out; };
    let r = new_run(re, s);
    let one = first_byte(re);
    let n = len(s);
    let at = 0;
    let prev_end = 0 - 1;
    let go = limit != 0;
    while (go) {
        let st = seek(re, r, s, at, one);
        if (st < 0) {
            go = false;
        } else {
            let en = r.hit[1];
            let w = en - st;
            if (!(w == 0 && st == prev_end)) {
                out += make_match(re, r);
                if (limit > 0 && len(out) >= limit) { go = false; };
            };
            prev_end = en;
            at = en;
            if (w == 0) { at = at + 1; };
            if (at > n) { go = false; };
        };
    };
    out
}

// The subject cut at every match that took bytes; a match of none splits
// nothing. One trailing empty piece goes, as str.split drops one (the manual,
// "Sequences and text").
def split(re: Re, s: str) -> [str] {
    let out: [str] = [];
    if (!need_ok(re, s)) { return [s] };
    let r = new_run(re, s);
    let one = first_byte(re);
    let n = len(s);
    let at = 0;
    let go = true;
    while (go) {
        let st = seek(re, r, s, at, one);
        if (st < 0) {
            go = false;
        } else {
            let en = r.hit[1];
            let next = st + 1;
            if (en > st) {
                out += s[at:st];
                at = en;
                next = en;
            };
            if (next >= n) { go = false; } else { at = next; };
        };
    };
    if (at < n) { out += s[at:n]; };
    if (len(out) > 0 && len(out[len(out) - 1]) == 0) {
        out = out[0:len(out) - 1];
    };
    out
};

// Every match that took bytes replaced by what rep says: $0, $1..$9, ${name},
// and $$ for a literal $. A group that took no part is ""; a name or count the
// pattern does not have stays as written, so a typo shows instead of going
// quietly.
def replace(re: Re, s: str, rep: str) -> str {
    let out: [str] = [];
    if (!need_ok(re, s)) { return s; };
    let r = new_run(re, s);
    let one = first_byte(re);
    let n = len(s);
    let at = 0;
    let go = true;
    while (go) {
        let st = seek(re, r, s, at, one);
        if (st < 0) {
            go = false;
        } else {
            let en = r.hit[1];
            if (en == st) {
                // an empty match replaces nothing: copy through, go on
                if (st >= n) { go = false; } else {
                    out += s[at:st + 1];
                    at = st + 1;
                };
            } else {
                out += s[at:st];
                tmpl(re, r, rep, out);
                at = en;
            };
        };
    };
    out += s[at:n];
    join(out, "")
};

// replace, with a function deciding what each match becomes.
def replace_with(re: Re, s: str, f: (Match) -> str) -> str {
    let out: [str] = [];
    if (!need_ok(re, s)) { return s; };
    let r = new_run(re, s);
    let one = first_byte(re);
    let n = len(s);
    let at = 0;
    let go = true;
    while (go) {
        let st = seek(re, r, s, at, one);
        if (st < 0) {
            go = false;
        } else {
            let en = r.hit[1];
            if (en == st) {
                if (st >= n) { go = false; } else {
                    out += s[at:st + 1];
                    at = st + 1;
                };
            } else {
                out += s[at:st];
                out += f(make_match(re, r));
                at = en;
            };
        };
    };
    out += s[at:n];
    join(out, "")
}

// rep's substitutions, appended to parts. One `$…` at a time: subst says where
// it ended, or -1 that it was a literal $ after all.
def tmpl(re: Re, r: Run, rep: str, parts: [str]) -> long {
    let n = len(rep);
    let i = 0;
    while (i < n) {
        let j = i;
        if (byte_at(rep, i) == 36) { j = subst(re, r, rep, i, parts); };
        // subst's -1 means "this $ is a literal $ after all" — so anything that is
        // not further along the template than we are means one byte went by
        if (j <= i) {
            parts += chr(byte_at(rep, i));
            i = i + 1;
        } else {
            i = j;
        };
    };
    0
}

// The `$…` at i: what it means, appended to parts, and the index past it — or
// -1 when it is a literal $ after all, so tmpl copies the $ and moves on.
def subst(re: Re, r: Run, rep: str, i: long, parts: [str]) -> long {
    let n = len(rep);
    if (i + 1 >= n) { return 0 - 1; };
    let d = byte_at(rep, i + 1);
    if (d == 36) {
        parts += "$";
        return i + 2;
    };
    if (d == 123) {
        let j = i + 2;
        let name = "";
        while (j < n && byte_at(rep, j) != 125) {
            name += chr(byte_at(rep, j));
            j = j + 1;
        };
        if (j >= n) { return 0 - 1; };
        let num = group_num(re, name);
        if (num < 0) { return 0 - 1; };
        parts += group_of(r, num);
        return j + 1;
    };
    if (d >= 48 && d <= 57) {
        let j = i + 1;
        let v = 0;
        while (j < n && byte_at(rep, j) >= 48 && byte_at(rep, j) <= 57) {
            v = v * 10 + (byte_at(rep, j) - 48);
            j = j + 1;
        };
        if (v > re.groups) { return 0 - 1; };
        parts += group_of(r, v);
        return j;
    };
    0 - 1
};

// What $name names: a group number, or -1 when the pattern has no such group
// (a name it does not have, or a count past its last).
def group_num(re: Re, name: str) -> long {
    let digits = len(name) > 0;
    let i = 0;
    while (i < len(name)) {
        if (!is_digit_byte(byte_at(name, i))) { digits = false; };
        i = i + 1;
    };
    if (digits) {
        let v = tolong(name) !;
        if (v <= re.groups) { v } else { 0 - 1 }
    } else {
        let got = re.names[name];
        if (got == none) { 0 - 1 } else { got ! }
    }
};

// A group's text out of the captures of the run that just matched.
def group_of(r: Run, num: long) -> str {
    let st = r.hit[2 * num];
    if (st < 0) { "" } else { r.subject[st:r.hit[2 * num + 1]] }
};

// ── the Match accessors ───────────────────────────────────────────────────
// caps is public, so an offset needs no call: m.caps[2 * 1] is group 1's
// start. These are the checked spellings, and the two bounds answers are the
// tree's own: a count past the last group is a caller bug and traps like any
// index (struct's readers, struct.y:15), while a name the pattern does not have
// is a map read and gives none.

// What group n matched: none when it took no part, which is not the same as
// matching nothing — that is some("").
def group(m: Match, n: long) -> str? {
    let st = m.caps[2 * n];
    if (st < 0) { none } else { some(m.subject[st:m.caps[2 * n + 1]]) }
};

// The same by name; none when the pattern has no such group.
def named(m: Match, name: str) -> str? {
    let got = m.names[name];
    if (got == none) { none } else { group(m, got !) }
};

// Group n's start offset, -1 when it took no part.
def start(m: Match, n: long) -> long { m.caps[2 * n] };

// Group n's end offset, -1 when it took no part.
def end(m: Match, n: long) -> long { m.caps[2 * n + 1] };

export { compile, check, escape, match, match_at, full, search, search_at, is_match,
    find, split, replace, replace_with, group, named, start, end };
