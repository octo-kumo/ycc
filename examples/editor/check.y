// check.y -- the property checks.  No golden file is involved in any of this.
//
// WHY THIS FILE EXISTS AT ALL
//
// A golden file proves determinism, not correctness: a golden file that
// encodes a defect is deterministically reproduced and passes for ever.  `examples/cube` shipped that way -- eight of eight gate
// items, and a wireframe that filled regions.  So `EXPECTED` here proves the
// renderer is reproducible, and this file proves the editor is RIGHT.
//
// The four checks the brief asks for, and how each avoids being a restatement of
// the code it tests:
//
//   (a) UNDO INVARIANT.  N edits, N undos, the text must come back BYTE FOR
//       BYTE -- compared as text and printed as a hash, never as a count of
//       "things that happened".
//   (b) SUBSTITUTE CORRECTNESS.  The reported count must equal the number of
//       replacements actually made.  The ORACLE for the global case is the
//       std's own `str.replace` / `str.count`, which is KMP and shares no code
//       with buf.y's naive scan -- so this is not the editor agreeing with
//       itself.
//   (c) BOUNDARY SAFETY.  ~150 hostile keys driven through the real mode
//       machine with the invariants asserted after EVERY key, plus a sweep of
//       every screen geometry through the painter.  Surviving is part of the
//       assertion -- an out-of-bounds index traps on STDOUT and would show up
//       as a missing line of output -- but the invariants are what make it a
//       check rather than an observation.
//   (d) INDEPENDENT MODEL.  The same edit sequence applied to a reference model
//       kept in a DIFFERENT representation -- one flat string with LF splices,
//       against buf.y's array of per-line strings -- and the two texts compared
//       after every single step.  Two mechanisms, one specification.
//
//   (e) viewport minimality and (f) UTF-8 column algebra, both of which a
//       golden file cannot see: the horizontal scroll offset is invisible in a dump
//       that only ever scrolls one way, and a byte/column mixup only shows up on text
//       the demo file happens not to contain.
//   (g) THE INPUT FILE'S ERROR PATH, and a key count that can be wrong.  This one
//       is about a SILENT SUCCESS and it cannot be done in process: the claim is
//       about an exit code and about which stream a message came out of, so it
//       runs the built binary.  See the comment above p_missing.

import buf;
import fs;
import modes;
import random;
import screen;

// ===========================================================================
// the report
// ===========================================================================

let CHECKS = 0;
let FAILED = 0;
let GROUP = "";

def group(name: str) -> void { GROUP = name };
def mark() -> long { CHECKS };

def note(s: str) -> void { puts("        " + s + "\n") };

def ok(cond: bool, what: str) -> void {
    CHECKS = CHECKS + 1;
    if (!cond) {
        FAILED = FAILED + 1;
        puts("  FAIL [" + GROUP + "] " + what)
    }
};

def eq_long(got: long, want: long, what: str) -> void {
    CHECKS = CHECKS + 1;
    if (got != want) {
        FAILED = FAILED + 1;
        puts("  FAIL [" + GROUP + "] " + what);
        puts("        got  " + tostring(got));
        puts("        want " + tostring(want));
        puts("        text [" + buf.text() + "]");
    }
};

def eq_str(got: str, want: str, what: str) -> void {
    CHECKS = CHECKS + 1;
    if (got != want) {
        FAILED = FAILED + 1;
        puts("  FAIL [" + GROUP + "] " + what);
        puts("        got  [" + got + "]");
        puts("        want [" + want + "]");
    }
};

// ===========================================================================
// the independent model
// ===========================================================================
//
// One flat string, no per-line array, no per-line slicing.  Its only operation
// is "replace N bytes at an offset with this text", which is the specification
// of an edit; buf.y works the other way round, by rewriting one line of an
// array.  Offsets are found by counting LFs in the flat string.

let M_TEXT = "";
let M_LINES = 0;
let M_TAIL = 0;         // the length of the last line

// The line count comes from COUNTING LFs, not from `str.lines()`: "a\n".lines()
// is ["a"], so a document whose last line is empty -- text ending in a newline,
// which is every file this editor saves -- would be one line short of the
// editor's, and every offset after it would be wrong.  Counting is also the
// model's own mechanism rather than a borrowing of the std's.
def md_set(s: str) -> void {
    M_TEXT = s;
    let n = 0;
    let lastlf = 0 - 1;
    let i = 0;
    while (i < len(s)) {
        if (byte_at(s, i) == 10) {
            n = n + 1;
            lastlf = i
        };
        i = i + 1
    };
    M_LINES = n + 1;
    if (lastlf < 0) { M_TAIL = len(s); } else { M_TAIL = len(s) - lastlf - 1 }
};

def md_get() -> str { M_TEXT };
def md_lines() -> long { M_LINES };

// The byte offset line `ln` starts at, found by counting LFs.  The last line has
// no LF after it, so the length of the final line is remembered instead -- the
// one piece of derived state the flat model needs.
def md_start(ln: long) -> long {
    let want = ln;
    if (want < 0) { want = 0 };
    let i = 0;
    let seen = 0;
    let go = want > 0 && i < len(M_TEXT);
    while (go) {
        if (byte_at(M_TEXT, i) == 10) { seen = seen + 1 };
        i = i + 1;
        go = seen < want && i < len(M_TEXT)
    };
    let at = 0;
    if (seen >= want) { at = i; } else { at = len(M_TEXT) - M_TAIL; };
    at
};

def md_llen(ln: long) -> long {
    let o = md_start(ln);
    let n = 0;
    let i = o;
    let go = i < len(M_TEXT);
    while (go) {
        if (byte_at(M_TEXT, i) == 10) { go = false } else { n = n + 1; i = i + 1; go = i < len(M_TEXT) }
    };
    n
};

// The byte offset of (ln, col), with the column clamped to the line.  The clamp
// is part of the specification -- "a column is a byte offset into ITS line" --
// so both implementations have to honour it, and the fuzz below passes
// deliberately out-of-range columns to keep them honest about it.
def md_offs(ln: long, col: long) -> long {
    let o = md_start(ln);
    let n = md_llen(ln);
    let c = col;
    if (c < 0) { c = 0 };
    if (c > n) { c = n };
    o + c
};

// Replace `n` bytes at `off` with `s`.  The model's one primitive.
def md_splice(off: long, n: long, s: str) -> void {
    let lo = off;
    if (lo < 0) { lo = 0 };
    let hi = lo + n;
    if (hi > len(M_TEXT)) { hi = len(M_TEXT) };
    md_set(M_TEXT[0:lo] + s + M_TEXT[hi:])
};

def md_ins(off: long, s: str) -> void { md_splice(off, 0, s) };
// A negative length means the editor clamped the pair to empty (it does:
// delete_cols raises a reversed pair to an empty range), so the model must too.
// Splicing with n < 0 would instead give M_TEXT[hi:] a start BEFORE lo and
// DUPLICATE the text between them -- which is what the first run of the model
// fuzz found, 431 steps in.
def md_del(lo: long, hi: long) -> void {
    let n = hi - lo;
    if (n < 0) { n = 0 };
    md_splice(lo, n, "")
};

def md_line(ln: long) -> str {
    let o = md_start(ln);
    let n = md_llen(ln);
    M_TEXT[0:0] + M_TEXT[o:o + n]
};

// The model's own character tests, so it does not borrow buf.y's.
def md_space(b: long) -> bool { b == 32 || b == 9 };

// ===========================================================================
// shared setup
// ===========================================================================

// Put the editor and the model on the same document, with an empty history and
// the mode machine back in NORMAL.  The mode matters: without resetting it, the
// first group to run after a test that left INSERT mode has its next `d` typed
// as a "d" -- which is exactly what the first run of these checks did, and why
// it cheerfully reported a buffer containing "ddonly".
def reset(doc: str) -> void {
    modes.set_mode(modes.NORMAL);
    buf.replace_text(doc);
    buf.reset_history();
    buf.goto(0, 0, false);
    buf.viewport(8, 40);
    buf.scroll_fix();
    md_set(doc)
};

// FNV-1a over two 16-bit lanes: no shift past bit 63 and no float anywhere.
def hash16(s: str) -> str {
    let h0 = 0;
    let h1 = 0;
    let i = 0;
    while (i < len(s)) {
        h0 = (h0 ^ byte_at(s, i)) & 65535;
        h1 = (h1 + h0 * 16777619) & 65535;
        i = i + 1
    };
    tostring(h1) + "." + tostring(h0)
};

// The fuzz stream is std's (import random above): this was a hand-rolled
// Park-Miller, `RS = (RS * 16807) % 2147483647`, seeded by `seed_rng` with
// `v % 2147483647` (a negative or zero seed folded up to 1).  Nothing else
// changes: the three fuzzes below still seed explicitly and deterministically,
// and they ask for UNIFORMITY under a modulus, which is what they get -- the
// particular bit stream was never part of any assertion here.  --check does not
// read --seed at all; it names its own three (1, 7, 20261004).

// ===========================================================================
// one scripted edit, in the editor AND in the model
// ===========================================================================
//
// Each is a single undo entry -- buf.begin_change() / buf.end_change() around
// exactly one operation, which is what the interactive paths do.  The model's
// offset is always computed BEFORE the editor is touched: reading buf.line_at()
// afterwards reads the already-EDITED line, which is the other mistake the first
// run of these checks made.

def do_insert(ln: long, col: long, s: str) -> void {
    let at = md_offs(ln, col);
    buf.begin_change();
    buf.insert_str(ln, col, s);
    buf.end_change();
    md_ins(at, s)
};

def do_delete(ln0: long, c0: long, ln1: long, c1: long) -> void {
    let lo = md_offs(ln0, c0);
    let hi = md_offs(ln1, c1);
    buf.begin_change();
    buf.delete_span(ln0, c0, ln1, c1);
    buf.end_change();
    md_del(lo, hi)
};

def do_split(ln: long, col: long) -> void {
    let at = md_offs(ln, col);
    buf.begin_change();
    buf.split_at(ln, col);
    buf.end_change();
    md_ins(at, "\n")
};

// J: remove one LF and put in the separator the rule asks for.  The separator
// comes from the MODEL's own pre-edit view, from the same rule stated twice.
// The join only happens in the model when the editor actually joined one -- J on
// the LAST line is a no-op, and splicing regardless is exactly the sort of thing
// that makes a model agree with itself instead of with the specification.
def do_join(ln: long) -> bool {
    let line = md_line(ln);
    let sep = " ";
    if (len(line) > 0 && md_space(byte_at(line, len(line) - 1))) { sep = "" };
    let nxt = md_line(ln + 1);
    if (len(nxt) > 0 && byte_at(nxt, 0) == 41) { sep = "" };
    let at = md_offs(ln, len(line));
    buf.begin_change();
    let made = buf.join_down(ln);
    buf.end_change();
    if (made) { md_splice(at, 1, sep) };
    made
};

// Delete one line and the newline that belongs to it: the one AFTER it, or --
// when it is the last line -- the one BEFORE it.  The second case is the one a
// range formula gets wrong, because a document whose last line is empty has its
// text ending in the separator with nothing after it to delete.
def md_del_line(ln: long) -> void {
    let lo = md_start(ln);
    let hi = len(M_TEXT);
    if (ln < md_lines() - 1) { hi = md_start(ln + 1) } else { if (ln > 0) { lo = lo - 1 } };
    md_splice(lo, hi - lo, "")
};

// Done one line at a time, from the top down, so every offset is recomputed
// against the text as it now stands rather than against a stale one.
def do_del_lines(a: long, b: long) -> void {
    buf.begin_change();
    buf.delete_lines(a, b);
    buf.end_change();
    // From the BOTTOM up: deleting from the top shifts every later line down,
    // so deleting a..b one at a time from the top deletes the wrong lines.
    let i = b;
    let go = i >= a;
    while (go) {
        md_del_line(i);
        i = i - 1;
        go = i >= a
    }
};

// The model substitutes with the std's own replace, which is the entire point.
def do_sub(ln: long, pat: str, rep: str, glob: bool) -> long {
    let off = md_offs(ln, 0);
    let line = md_line(ln);
    let n = len(line);
    buf.begin_change();
    let c = buf.substitute_line(ln, pat, rep, glob);
    buf.end_change();
    md_set(M_TEXT[0:off] + line.replace(pat, rep) + M_TEXT[off + n:]);
    c
};

// ===========================================================================
// (a) the undo invariant
// ===========================================================================

def p_undo() -> long {
    group("a undo invariant");
    let m0 = mark();
    let orig = "alpha beta\ngamma delta\nepsilon zeta\neta theta";
    reset(orig);

    // --- a scripted sequence: ten single-entry edits ---------------------
    do_insert(0, 5, " ");
    do_delete(1, 0, 1, 6);
    do_split(2, 7);
    do_join(0);
    do_del_lines(1, 2);
    do_insert(0, 0, "hello ");
    do_delete(0, 0, 0, 6);
    do_split(0, 3);
    do_join(0);
    do_insert(0, 0, "z");
    eq_str(buf.text(), md_get(), "scripted: the editor matches the model after ten edits");
    let after = buf.text();
    note("after 10 edits: " + tostring(len(after)) + " bytes, hash " + hash16(after));
    eq_long(buf.undo_depth(), 10, "ten undo entries, one per edit -- not one per keystroke");

    // --- N undos must return the ORIGINAL text, byte for byte -----------
    let i = 0;
    let n = buf.undo_depth();
    while (i < n) {
        buf.undo();
        i = i + 1
    };
    eq_str(buf.text(), orig, "after ten undos the text is the original, byte for byte");
    eq_str(hash16(buf.text()), hash16(orig), "... and the hashes agree");
    note("original hash " + hash16(buf.text()));
    eq_long(buf.undo_depth(), 0, "the undo stack is empty afterwards");
    ok(!buf.undo(), "one more undo is refused rather than trapping");

    // --- and N redos must put it all back -------------------------------
    let j = 0;
    while (j < n) {
        buf.redo();
        j = j + 1
    };
    eq_str(buf.text(), after, "N redos restore the edited text");
    eq_long(buf.redo_depth(), 0, "the redo stack is empty afterwards");
    ok(!buf.redo(), "one more redo is refused");

    // --- a typed run is ONE entry, which is vi's undo block --------------
    reset("base");
    modes.feed(ord("i"));
    let t = 0;
    while (t < 5) {
        modes.feed(ord("x"));
        t = t + 1
    };
    modes.feed(27);
    eq_str(buf.text(), "xxxxxbase", "five keystrokes in INSERT mode typed five x");
    eq_long(buf.undo_depth(), 1, "... and they are ONE undo entry, not five");
    buf.undo();
    eq_str(buf.text(), "base", "one u takes back the whole run of typing");

    // --- the same, fuzzed ------------------------------------------------
    // N edits then N undos with N inside the stack's bound, so this is about
    // undo and not about the bound.  The bound gets its own assertion below,
    // because "the stack is capped" is a property worth holding too.
    reset("fuzz me\nplease\nnow");
    random.seed(1);
    let steps = 100;
    let i2 = 0;
    while (i2 < steps) {
        let n1 = md_lines();
        let ln = random.below(n1);
        let c1 = buf.line_at(ln);
        let col = random.below(len(c1) + 1);
        let op = random.below(8);
        if (op == 0) { do_insert(ln, col, "x") }
        else if (op == 1) {
            let nx = buf.adv(c1, col);
            if (nx > col) { do_delete(ln, col, ln, nx) } else { do_insert(ln, col, "y") }
        } else if (op == 2) { do_split(ln, col) }
        else if (op == 3 && n1 > 1) { do_join(ln) }
        else if (op == 4 && n1 > 1) {
            let a = random.below(n1);
            let b = a + random.below(n1 - a);
            do_del_lines(a, b)
        } else if (op == 5) { do_insert(ln, col, "ab") }
        else if (op == 6 && len(c1) > 0) { do_sub(ln, "a", "Z", random.below(2) == 0) }
        else { do_insert(ln, col, " ") };
        eq_str(buf.text(), md_get(), "fuzz step " + tostring(i2) + " (op " + tostring(op) + ")");
        i2 = i2 + 1
    };
    let dn = buf.undo_depth();
    eq_long(dn, steps, "one undo entry per fuzzed edit");
    let k = 0;
    while (k < dn) {
        buf.undo();
        k = k + 1
    };
    eq_str(buf.text(), "fuzz me\nplease\nnow", "100 fuzzed edits then 100 undos: byte-for-byte the original");
    note("fuzz: " + tostring(steps) + " edits, " + tostring(dn) + " undo entries, hash " + hash16(buf.text()));

    // --- and the bound itself -------------------------------------------
    reset("bound\nit");
    random.seed(7);
    let many = 0;
    while (many < 400) {
        let ln3 = random.below(md_lines());
        do_insert(ln3, random.below(len(buf.line_at(ln3)) + 1), "Q");
        many = many + 1
    };
    eq_long(buf.undo_depth(), buf.undo_max(), "400 edits leave exactly the capped number of undo entries");
    note("bound: 400 edits, undo depth capped at " + tostring(buf.undo_max()));
    CHECKS - m0
};

// ===========================================================================
// (b) substitute correctness
// ===========================================================================

def p_substitute() -> long {
    group("b substitute");
    let m0 = mark();
    let lines: [str] = ["", "a", "abc", "aaa", "aa", "xaxax", "hello world hello",
                        "aa bb aa", "  spaced  ", "ABCabc", "aaaa", "no-match-here"];
    let pats: [str] = ["a", "aa", "z", "hello", "  ", "abc"];
    let reps: [str] = ["Q", "", "hello"];

    let li = 0;
    while (li < len(lines)) {
        let pi = 0;
        while (pi < len(pats)) {
            let ri = 0;
            while (ri < len(reps)) {
                let glob = (li + pi + ri) % 2 == 0;
                let before = lines[li];
                reset(before);
                let got = buf.substitute_line(0, pats[pi], reps[ri], glob);
                // The oracle.  Global goes to the std's own KMP replace/count,
                // which shares no code with buf.y's naive scan.  First-only is
                // the specification written out, because no std spells it.
                let want_text = "";
                let want = 0;
                if (glob) {
                    want_text = before.replace(pats[pi], reps[ri]);
                    want = before.count(pats[pi])
                } else {
                    let at0 = before.index_of(pats[pi]);
                    if (at0 < 0) {
                        want_text = before
                    } else {
                        want_text = before[0:at0] + reps[ri] + before[at0 + len(pats[pi]):];
                        want = 1
                    }
                };
                let tag = " [" + before + "] / [" + pats[pi] + "] -> [" + reps[ri] + "]" + (glob ? " g" : "");
                eq_long(got, want, "substitute count" + tag);
                eq_str(buf.text(), want_text, "substitute text" + tag);
                ri = ri + 1
            };
            pi = pi + 1
        };
        li = li + 1
    };

    // adjacent occurrences must not overlap: "aaa" with "aa" globally is ONE
    // replacement, and the std agrees
    reset("aaa");
    eq_long(buf.substitute_line(0, "aa", "b", true), 1, "adjacent occurrences do not overlap");
    eq_str(buf.text(), "ba", "\"aaa\" s/aa/b/g leaves \"ba\"");

    // an empty pattern is refused, and refuses WITHOUT changing the buffer
    reset("keep me");
    eq_long(buf.substitute_line(0, "", "x", true), 0 - 1, "an empty pattern is an error, not a zero");
    eq_str(buf.text(), "keep me", "an empty pattern leaves the buffer alone");

    // a pattern longer than the line: no match, count 0, buffer unchanged
    reset("ab");
    eq_long(buf.substitute_line(0, "abcdef", "x", true), 0, "a pattern longer than the line matches nothing");
    eq_str(buf.text(), "ab", "... and changes nothing");

    // the whole-file form, through the ex command line, and the message
    reset("cat\ndog\ncat again");
    eq_long(modes.ex("%s/cat/CAT/g"), modes.ACT_CONTINUE, "%s///g runs and stays in NORMAL");
    eq_str(buf.text(), "CAT\ndog\nCAT again", "%s///g replaced both lines and only those");
    ok(buf.last_msg().starts_with("2 substitutions"), "the reported count is the number of replacements made: [" + buf.last_msg() + "]");

    reset("cat\ndog\ncat cat");
    modes.ex("%s/cat/CAT/");
    eq_str(buf.text(), "CAT\ndog\nCAT cat", "without g, only the FIRST occurrence on each line");
    ok(buf.last_msg().starts_with("2 substitutions"), "and it reports two, not one");

    reset("cat\ndog\ncat again");
    modes.ex("s/cat/CAT/");
    eq_str(buf.text(), "CAT\ndog\ncat again", "a bare s/// works on the cursor's line only");
    ok(buf.last_msg().starts_with("1 substitution"), "and reports one");

    reset("nothing here");
    modes.ex("s/zzz/Q/");
    ok(buf.last_msg().starts_with("E486"), "a pattern that is nowhere is diagnosed, not ignored");
    eq_str(buf.text(), "nothing here", "... and changes nothing");

    // `\/` is a literal slash, which is what makes a URL or a path substitutable
    reset("a/b/c");
    modes.ex("s/b/x\\/y/g");
    eq_str(buf.text(), "a/x/y/c", "an escaped / inside the replacement is a literal slash");
    reset("a/b/c");
    eq_long(buf.substitute_line(0, "a/b", "Z", true), 1, "an escaped / inside the pattern is a literal slash too");
    eq_str(buf.text(), "Z/c", "... and it replaced the whole two-character match");

    // with the closing delimiter there is no ambiguity about a replacement that
    // happens to end in a flag letter
    reset("hit big");
    modes.ex("s/hit/big/");
    eq_str(buf.text(), "big big", "s/hit/big/ replaces hit with big, not with bi");
    reset("hit big");
    modes.ex("s/hit/X");
    eq_str(buf.text(), "X big", "with no closing delimiter and no flag letter, it still substitutes");
    // The documented wart, asserted so it cannot change silently: with no closing
    // delimiter a trailing run of g/c/i/I is read as flags, so `big` is read as
    // the replacement "bi" with flag "g".
    reset("hit big");
    modes.ex("s/hit/big");
    eq_str(buf.text(), "b big", "with no closing delimiter, a trailing g is a flag (documented)");
    note("the closing delimiter is what removes that ambiguity: s/hit/big/ -> \"big big\"");
    CHECKS - m0
};

// ===========================================================================
// (c) boundary safety
// ===========================================================================

// Every invariant the cursor and the viewport must hold, checked after every key.
def invariants(where: str) -> void {
    let good = true;
    let n = buf.nlines();
    let cl = buf.cursor_line();
    let cc = buf.cursor_col();
    let s = buf.line_at(cl);
    let rows = buf.view_rows();
    let tw = buf.textw();
    let top = buf.top();
    let h = buf.hcol();
    if (n < 1) { good = false; note(where + ": the buffer has no lines at all") };
    if (cl < 0 || cl > n - 1) { good = false; note(where + ": cursor line " + tostring(cl) + " of " + tostring(n)) };
    if (cc < 0 || cc > len(s)) {
        good = false;
        note(where + ": cursor col " + tostring(cc) + " of a line " + tostring(len(s)) + " long")
    };
    if (modes.mode() == modes.NORMAL && len(s) > 0 && cc > len(s) - 1) {
        good = false;
        note(where + ": a NORMAL cursor sits past the last character")
    };
    if (top < 0 || top > n - 1) { good = false; note(where + ": top " + tostring(top) + " of " + tostring(n)) };
    if (cl < top || cl > top + rows - 1) { good = false; note(where + ": the cursor line is off screen") };
    if (h < 0) { good = false; note(where + ": hcol is negative") };
    let hc = buf.nchars(s, h, cc);
    if (!(hc >= 0 && hc <= tw - 1)) {
        good = false;
        note(where + ": cursor " + tostring(hc) + " characters from the left edge, window " + tostring(tw))
    };
    // Minimality: HCOL is zero EXACTLY when the cursor would fit inside the first
    // screen.  Not "hc < tw and h == 0" -- that is the same thing stated the
    // other way round and it is wrong, because a scrolled line legitimately has a
    // visible cursor with a non-zero HCOL.
    let fits = buf.nchars(s, 0, cc) < tw;
    if (fits && h != 0) {
        good = false;
        note(where + ": hcol " + tostring(h) + " but the cursor fits from column 0")
    };
    if (!fits && h == 0) {
        good = false;
        note(where + ": hcol 0 but the cursor does not fit from column 0")
    };
    CHECKS = CHECKS + 1;
    if (!good) {
        FAILED = FAILED + 1;
        puts("  FAIL [" + GROUP + "] " + where + ": an invariant is broken")
    }
};

// ~150 bytes of hostile keys: every motion, every operator, every text object,
// every ex command, the visual mode, both scrolling keys, both CR and Backspace,
// and the control characters a terminal actually sends.
def hostile_script() -> str {
    "jJkkkk999999j999999klllllllll0$ggGGddxXdDpPoOu<18>" +
    "VjdcyVdcyYYiwiwaq\"ci\"dia\"a\"AIX~J:g g0$wbeBSBS<Del>" +
    ":q:q!:wq:n999999:0:s/a/b/:s/a/b/g:u:redo/nG99G2dd" +
    "ddGddyypPxXoO<Left><Right><Up><Down><Home><End><PgUp><PgDn>" +
    "ggihello<Esc>0A!<Esc>o more<Esc>Oeven<Esc><CR><CR>J" +
    ":%s/o/0/g:%s/zz/1/:%s/^$/E/:nosuch:Gggdaq"
};

def p_boundary() -> long {
    group("c boundary safety");
    let m0 = mark();

    // --- the empty buffer, the single hardest case -----------------------
    reset("");
    eq_long(buf.nlines(), 1, "an empty document is one empty line, not zero");
    eq_str(buf.text(), "", "... and its text is the empty string");
    eq_long(buf.cursor_col(), 0, "its only column is 0");

    // --- the hostile script, invariants after every single key ------------
    let script = hostile_script();
    reset("");
    let n = len(script);
    let i = 0;
    while (i < n) {
        let c = byte_at(script, i);
        modes.feed(c);
        invariants("empty buffer, key " + tostring(i) + " [" + chr(c) + "]");
        i = i + 1
    };

    // --- the same sequence on content, in a window too small for it ------
    reset("short\na very much longer line that will not fit in forty columns\n\nx");
    buf.viewport(4, 20);
    buf.scroll_fix();
    let j = 0;
    while (j < n) {
        let c = byte_at(script, j);
        modes.feed(c);
        invariants("narrow window, key " + tostring(j) + " [" + chr(c) + "]");
        j = j + 1
    };

    // --- the named escape sequences, decoded and driven too --------------
    reset("esc keys\nsecond");
    modes.script_decode("<Up><Down><Left><Right><Home><End><PgDn><PgUp><Del>");
    let more = modes.script_more();
    let t = 0;
    while (more) {
        modes.feed(modes.script_take());
        invariants("named key " + tostring(t));
        more = modes.script_more();
        t = t + 1
    };

    // --- specific behaviours, asserted rather than merely survived --------
    reset("only");
    modes.feed(ord("d"));
    modes.feed(ord("d"));
    eq_long(buf.nlines(), 1, "dd on a one-line buffer leaves one line");
    eq_str(buf.text(), "", "... and empties it");
    modes.feed(ord("x"));
    eq_str(buf.text(), "", "x on an empty line changes nothing");
    eq_long(buf.undo_depth(), 1, "x on an empty line pushed no undo entry");

    reset("a\nb");
    modes.feed(ord("G"));
    modes.feed(ord("J"));
    ok(buf.last_msg().starts_with("only one line"), "J on the last line is diagnosed");
    eq_long(buf.nlines(), 2, "... and joins nothing");

    reset("one line");
    modes.feed(ord("d"));
    modes.feed(ord("G"));
    eq_long(buf.nlines(), 1, "dG on the last line leaves one line");
    eq_str(buf.text(), "", "... empty");

    reset("abc");
    modes.feed(ord("X"));
    eq_str(buf.text(), "abc", "X at column 0 changes nothing");
    eq_long(buf.cursor_col(), 0, "... and the cursor stays put");

    reset("abc");
    modes.feed(ord("p"));
    ok(buf.last_msg().starts_with("E353"), "p with an empty register is diagnosed");

    reset("abc");
    modes.feed(ord("u"));
    ok(buf.last_msg().starts_with("E1"), "u at the bottom of the history is diagnosed");
    modes.feed(18);
    ok(buf.last_msg().starts_with("E35"), "Ctrl-R at the top of the history is diagnosed");

    reset("abc");
    modes.feed(ord("d"));
    modes.feed(ord("~"));
    ok(buf.last_msg().starts_with("operator d cancelled"), "an operator followed by junk cancels visibly");
    eq_str(buf.text(), "abc", "... and changes nothing");

    reset("keep");
    modes.feed(ord("i"));
    modes.feed(ord("z"));
    modes.feed(27);
    ok(buf.dirty(), "a change marks the buffer modified");
    modes.feed(ord(":"));
    modes.feed(ord("q"));
    eq_long(modes.feed(13), modes.ACT_CONTINUE, "q on a modified buffer refuses to quit");
    ok(buf.last_msg().starts_with("E37"), "... and says why, with vi's own message");
    modes.feed(ord(":"));
    modes.feed(ord("q"));
    modes.feed(ord("!"));
    eq_long(modes.feed(13), modes.ACT_QUIT, "q! on a modified buffer quits anyway");
    reset("clean");
    modes.feed(ord(":"));
    modes.feed(ord("q"));
    eq_long(modes.feed(13), modes.ACT_QUIT, "q on an unmodified buffer quits");

    // An operator + change must leave the cursor exactly where the replacement
    // is typed, not one character to its left.  The text alone cannot see this:
    // the first version of set_mode() closed the undo block and stepped left on
    // the way IN to INSERT, so `caw` typed "X" before the word -- "cawX" on
    // "the lazy dog" produced "the lazXy" and every text comparison passed.
    reset("the lazy dog");
    buf.goto(0, 8, false);
    modes.feed(ord("c"));
    modes.feed(ord("a"));
    modes.feed(ord("w"));
    eq_str(buf.text(), "the lazy", "caw on a space takes the space AND the word after it");
    eq_long(buf.cursor_col(), 8, "... and leaves the cursor at the end of what is left");
    eq_long(modes.mode(), modes.INSERT, "... in INSERT mode");
    modes.feed(ord("X"));
    modes.feed(27);
    eq_str(buf.text(), "the lazyX", "cawX replaces that with X exactly");
    eq_long(buf.cursor_col(), 8, "... and the cursor ends up on the X");

    reset("the lazy dog");
    buf.goto(0, 10, false);
    modes.feed(ord("c"));
    modes.feed(ord("i"));
    modes.feed(ord("w"));
    eq_str(buf.text(), "the lazy ", "ciw on a word removes the word only, keeping the space");
    eq_long(buf.cursor_col(), 9, "... with the cursor where the word was");
    modes.feed(ord("Z"));
    modes.feed(27);
    eq_str(buf.text(), "the lazy Z", "ciwZ replaces just the word");
    eq_long(buf.cursor_col(), 9, "... and leaves the cursor on the Z");

    reset("one two three");
    buf.goto(0, 0, false);
    modes.feed(ord("d"));
    modes.feed(ord("i"));
    modes.feed(ord("w"));
    eq_str(buf.text(), " two three", "diw removes the word, not the space after it");
    eq_long(buf.cursor_col(), 0, "... and leaves the cursor at column 0");
    reset("one two three");
    modes.feed(ord("d"));
    modes.feed(ord("a"));
    modes.feed(ord("w"));
    eq_str(buf.text(), "two three", "daw removes the word and the space after it");
    reset("one two three");
    modes.feed(ord("d"));
    modes.feed(ord("a"));
    modes.feed(ord("w"));
    eq_long(buf.undo_depth(), 1, "daw at column 0 is one undo entry");

    reset("a\"quoted\" b");    reset("a\"quoted\" b");
    modes.feed(ord("c"));
    modes.feed(ord("i"));
    modes.feed(ord("q"));
    eq_str(buf.text(), "a\"\" b", "ci\" empties the text between the quotes");
    modes.feed(27);
    reset("a \"open b");
    modes.feed(ord("c"));
    modes.feed(ord("i"));
    modes.feed(ord("q"));
    ok(buf.last_msg().starts_with("E486"), "ci\" with no closing quote is diagnosed");
    eq_str(buf.text(), "a \"open b", "... and changes nothing");

    // --- every geometry through the painter ------------------------------
    let r = 2;
    while (r <= 14) {
        let c = 12;
        while (c <= 44) {
            reset("héllo wörld\nsecond line here\n\nfourth");
            buf.goto(1, 20, false);
            screen.build_grid(r, c);
            screen.emit_plain(r, c);
            ok(screen.plain_len() >= r && screen.plain_len() <= r * c * 4,
               "grid " + tostring(r) + "x" + tostring(c) + " holds at most that many bytes");
            let rl = buf.view_rows();
            let tw = buf.textw();
            ok(buf.cursor_line() >= buf.top() && buf.cursor_line() <= buf.top() + rl - 1,
               "the cursor line is on screen at " + tostring(r) + "x" + tostring(c));
            let hc = buf.nchars(buf.line_at(buf.cursor_line()), buf.hcol(), buf.cursor_col());
            ok(hc >= 0 && hc <= tw - 1,
               "the cursor column is visible at " + tostring(r) + "x" + tostring(c));
            c = c + 7
        };
        r = r + 3
    };
    CHECKS - m0
};

// ===========================================================================
// (d) the independent model, step by step
// ===========================================================================

def p_model() -> long {
    group("d independent model");
    let m0 = mark();

    reset("first line\nsecond line\nthird line");
    do_insert(0, 0, ">> ");
    eq_str(buf.text(), md_get(), "insert at the very start");
    do_insert(2, len("third line"), "!");
    eq_str(buf.text(), md_get(), "insert at the very end");
    do_delete(0, 0, 0, 3);
    eq_str(buf.text(), md_get(), "delete at the very start");
    do_delete(0, 5, 1, 6);
    eq_str(buf.text(), md_get(), "delete across a line boundary");
    do_split(1, 0);
    eq_str(buf.text(), md_get(), "split at column 0");
    do_del_lines(0, 2);
    eq_str(buf.text(), md_get(), "delete every line");
    do_insert(0, 0, "back");
    eq_str(buf.text(), md_get(), "and put something back");
    do_split(0, 0);
    eq_str(buf.text(), md_get(), "split an empty line");
    do_join(0);
    eq_str(buf.text(), md_get(), "join it back");

    // out-of-range columns: the clamp is part of the specification and both
    // implementations have to agree about it
    reset("abc\nde");
    do_insert(0, 999, "X");
    eq_str(buf.text(), md_get(), "an insert past the end of a line lands at its end");
    do_delete(0, 0, 0, 999);
    eq_str(buf.text(), md_get(), "a delete past the end of a line is clamped");

    // 500 fuzzed edits, the model compared after EVERY one, with the cursor
    // driven at random too so the viewport is under the same scrutiny
    reset("alpha\nbeta\ngamma\ndelta\nepsilon");
    buf.viewport(3, 16);
    buf.scroll_fix();
    random.seed(20261004);
    let steps = 500;
    let i = 0;
    let mismatches = 0;
    while (i < steps) {
        let n1 = md_lines();
        let ln = random.below(n1);
        let s = buf.line_at(ln);
        let col = random.below(len(s) + 1);
        let op = random.below(11);
        if (op == 0) { do_insert(ln, col, "w") }
        else if (op == 1) {
            let nx = buf.adv(s, col);
            if (nx > col) { do_delete(ln, col, ln, nx) } else { do_insert(ln, col, "v") }
        } else if (op == 2) {
            let l2 = random.below(n1);
            if (l2 < ln) {
                do_delete(l2, 0, ln, col)
            } else {
                let c2 = random.below(len(buf.line_at(l2)) + 1);
                do_delete(ln, col, l2, c2)
            }
        } else if (op == 3) { do_split(ln, col) }
        else if (op == 4 && n1 > 1) { do_join(ln) }
        else if (op == 5 && n1 > 1) {
            let a = random.below(n1);
            do_del_lines(a, a + random.below(n1 - a))
        } else if (op == 6) { do_insert(ln, col, "qrs") }
        else if (op == 7) { do_sub(ln, "a", "A", false) }
        else if (op == 8) { do_sub(ln, "a", "A", true) }
        else if (op == 9) { do_insert(ln, col, " ") }
        else { do_delete(ln, col, ln, col) };
        let cl = random.below(md_lines());
        let cc2 = random.below(len(buf.line_at(cl)) + 1);
        buf.goto(cl, cc2, false);
        invariants("model fuzz step " + tostring(i) + " (op " + tostring(op) + ")");
        if (buf.text() != md_get()) { mismatches = mismatches + 1 };
        i = i + 1
    };
    eq_long(mismatches, 0, "500 fuzzed edits: the editor and the model never diverged");
    eq_str(buf.text(), md_get(), "the final texts are identical");
    note("model: " + tostring(steps) + " edits, final " + tostring(buf.nlines()) + " lines " + tostring(buf.nbytes()) + " bytes, hash " + hash16(buf.text()));
    CHECKS - m0
};

// ===========================================================================
// (e) viewport minimality -- what a dump cannot see
// ===========================================================================

def p_viewport() -> long {
    group("e viewport");
    let m0 = mark();
    reset("a short line\n0123456789012345678901234567890123456789\nthird\nfourth\nfifth");
    buf.viewport(4, 16);
    buf.scroll_fix();

    eq_long(buf.gutter(), 2, "a 5-line file gets a 1-digit gutter plus a space");
    ok(buf.digits_of(buf.nlines()) + 1 == buf.gutter(), "the gutter width is the digit count plus one");
    ok(screen.digits_of(buf.nlines()) + 1 == buf.gutter(), "buf.y and screen.y agree on the digit count");

    // walking right through the long line: HCOL must be minimal, and must be 0
    // while the cursor fits inside the first screen
    let s = buf.line_at(1);
    let bad = 0;
    let i = 0;
    while (i <= 12) {
        buf.goto(1, i, false);
        if (i < buf.textw() && buf.hcol() != 0) { bad = bad + 1 };
        if (i >= buf.textw() && buf.hcol() != i - buf.textw() + 1) { bad = bad + 1 };
        i = i + 1
    };
    eq_long(bad, 0, "hcol is minimal at every column of the long line");
    eq_long(buf.hcol(), 13 - buf.textw() + 1, "... and at the far right of the line it is exactly that");
    eq_str(s, "0123456789012345678901234567890123456789", "the long line is the one we think it is");

    // walking down: TOP must be minimal too
    let bad2 = 0;
    let l = 0;
    while (l < 5) {
        buf.goto(l, 0, false);
        let want = 0;
        if (l > 3) { want = l - 3 };
        if (buf.top() != want) { bad2 = bad2 + 1 };
        l = l + 1
    };
    eq_long(bad2, 0, "top is minimal at every line");

    // G on a file taller than the window puts the last line on the last row
    buf.goto(0, 0, false);
    modes.feed(ord("G"));
    eq_long(buf.cursor_line(), 4, "G goes to the last line");
    eq_long(buf.top(), 1, "... and the window scrolls so the last line is on the last row");
    eq_long(buf.top() + buf.view_rows() - 1, 4, "... exactly");

    // a line that fits must not leave the window shifted left over from a
    // longer one: this is the "the whole file jumped sideways" bug
    buf.goto(1, 30, false);
    ok(buf.hcol() == 30 - buf.textw() + 1, "hcol follows the cursor into the long line");
    buf.goto(1, 39, false);
    ok(buf.hcol() == 39 - buf.textw() + 1, "... and to the end of the line");
    buf.goto(0, 2, false);
    eq_long(buf.hcol(), 0, "moving to a line that fits resets hcol to 0");

    // Ctrl-E / Ctrl-Y move the window and bring the cursor into view
    buf.goto(0, 0, false);
    buf.scroll_page(1);
    eq_long(buf.top(), 2, "Ctrl-E in a four-row window scrolls two rows");
    eq_long(buf.cursor_line(), 2, "... and brings the cursor with it");
    buf.scroll_page(0 - 1);
    eq_long(buf.top(), 0, "Ctrl-Y scrolls back two rows");
    eq_long(buf.cursor_line(), 2, "... and leaves the cursor where it fits");

    // a taller file: the window can scroll away from the cursor's end
    reset("l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12");
    buf.viewport(4, 40);
    buf.goto(0, 0, false);
    modes.feed(5);                       // ^E
    eq_long(buf.top(), 2, "^E from line 1 shows lines 3..6");
    eq_long(buf.cursor_line(), 2, "... with the cursor on the first of them");
    modes.feed(4);                       // ^Y
    eq_long(buf.top(), 0, "^Y scrolls back");
    buf.goto(11, 0, false);
    eq_long(buf.top(), 8, "the last line is on the last row");
    modes.feed(ord("1"));
    modes.feed(ord("G"));
    eq_long(buf.cursor_line(), 0, "1G goes to line 1");
    modes.feed(ord("5"));
    modes.feed(ord("G"));
    eq_long(buf.cursor_line(), 4, "5G goes to line 5");

    // the window must never degenerate
    reset("x");
    buf.viewport(0, 0);
    ok(buf.view_rows() >= 1, "a zero-height viewport is raised to 1");
    ok(buf.textw() >= 1, "a zero-width viewport still has one text column");
    invariants("degenerate viewport");
    CHECKS - m0
};

// ===========================================================================
// (f) UTF-8 column algebra
// ===========================================================================

def p_utf8() -> long {
    group("f utf8 columns");
    let m0 = mark();
    // 9 bytes, 6 characters: h e-acute l l o euro-sign
    let s = "héllo€";
    eq_long(len(s), 9, "the test line is 9 bytes");
    eq_long(buf.adv(s, 0), 1, "adv past h is 1");
    eq_long(buf.adv(s, 1), 3, "adv past the two-byte e-acute is 3");
    eq_long(buf.adv(s, 3), 4, "adv past l is 4");
    eq_long(buf.adv(s, 5), 6, "adv past o is 6");
    eq_long(buf.adv(s, 6), 9, "adv past the three-byte euro sign is 9");
    eq_long(buf.adv(s, 9), 9, "adv at the end stays at the end");
    eq_long(buf.snapb(s, 2), 1, "snapb off the e-acute goes back to its lead byte");
    eq_long(buf.snapb(s, 8), 6, "snapb off the euro sign goes back to its lead byte");
    eq_long(buf.snapb(s, 99), 9, "snapb past the end clamps to the length");
    eq_long(buf.snapb(s, 0 - 5), 0, "snapb before the start clamps to 0");
    eq_long(buf.last_start(s), 6, "$ lands on the euro sign, not inside it");
    eq_long(buf.prev_start(s, 9), 6, "prev_start before the end is the euro sign");
    eq_long(buf.prev_start(s, 6), 5, "prev_start before that is o");
    eq_long(buf.prev_start(s, 0), 0, "prev_start at the start stays at the start");
    eq_long(buf.ulen(65), 1, "a plain byte is one byte");
    eq_long(buf.ulen(195), 2, "a two-byte lead is two bytes");
    eq_long(buf.ulen(226), 3, "a three-byte lead is three bytes");
    eq_long(buf.ulen(240), 4, "a four-byte lead is four bytes");
    eq_long(buf.cls_of(195), 1, "a byte >= 128 is a keyword byte, so an accented word is one word");

    // $ and l must walk characters, not bytes
    reset(s);
    buf.goto(0, 0, false);
    buf.goto_motion(buf.M_DOLLAR, 1);
    eq_long(buf.cursor_col(), 6, "$ lands on the euro sign");
    buf.goto(0, 0, false);
    let w1 = buf.target(buf.M_W, 1);
    eq_long(w1.col, 6, "w from h jumps the whole accented word and lands on the euro sign");
    eq_long(buf.nchars(s, 0, w1.col), 5, "... five characters in, not five bytes");

    // with the accents separated by spaces, each accented word is one step
    let ts = "a é b";
    reset(ts);
    buf.goto(0, 0, false);
    let t1 = buf.target(buf.M_W, 1);
    eq_long(t1.col, 2, "w from a lands on the e-acute");
    buf.goto(0, t1.col, false);
    let t2 = buf.target(buf.M_W, 1);
    eq_long(t2.col, 5, "w again steps over BOTH bytes of it and lands on b");
    eq_long(len(ts), 6, "that line is 6 bytes");
    eq_long(buf.nchars(ts, 0, 5), 4, "... and 4 characters");

    reset(s);
    let i = 0;
    while (i < 5) {
        buf.goto_motion(buf.M_L, 1);
        i = i + 1
    };
    eq_long(buf.cursor_col(), 6, "five l presses from column 0 reach the last character");

    // x must delete exactly one character, i.e. all of its bytes
    reset(s);
    buf.goto(0, 6, false);
    buf.delete_chars(1);
    eq_str(buf.text(), "héllo", "x on the euro sign removes all three of its bytes");

    // And the painter must give a code point ONE screen column.  The check that
    // this was wrong is the plain dump: 9 bytes went into 9 cells, so the euro
    // sign sat one column right of where the cursor was.
    reset(s);
    buf.goto(0, 0, false);
    buf.viewport(2, 20);
    screen.build_grid(2, 20);
    screen.emit_plain(2, 20);
    // The plain stream is the text verbatim -- nine bytes -- so it is indexed by
    // BYTE.  The screen-column claim is about the grid, so it is asserted through
    // cell_attr below.
    let g = buf.gutter();
    let at0 = screen.plain_row_start(0);
    eq_long(screen.plain_at(at0 + g), 104, "the line starts at the gutter");
    eq_long(screen.plain_at(at0 + g + 1), 195, "the e-acute is two bytes, in order");
    eq_long(screen.plain_at(at0 + g + 2), 169, "... its second byte follows");
    eq_long(screen.plain_at(at0 + g + 8), 172, "the euro sign's third byte is the last of the text");
    eq_long(screen.plain_at(at0 + g + 9), 32, "and then blanks");
    eq_long(screen.plain_row_len(0), g + 9 + 12, "the row is the gutter, nine bytes of text and blanks");
    eq_long(buf.nchars(s, 0, buf.cursor_col()), 0, "the cursor is at column 0");
    buf.goto(0, 6, false);
    screen.build_grid(2, 20);
    eq_long(screen.cell_attr(0, g + 5), screen.A_CUR, "the cursor lands on the euro sign, at screen column 5");
    eq_long(screen.cell_attr(0, g + 4), 0, "... and the cell before it is ordinary text");
    CHECKS - m0
};

// ===========================================================================
// (g) the input file's error path, and a key count that can be wrong
// ===========================================================================
//
// This is the only group that runs the BUILT BINARY instead of driving the
// buffer in process, and it exists because of a SILENT SUCCESS.
//
// What was wrong, measured: with `data/demo.txt` removed from a copy of this
// folder, `./editor --no-tty --keys '<96 keys>' --rows 10 --cols 44
// data/demo.txt` printed an empty buffer, said
//
//     --- keys 96 of 96 ---
//     modified  no
//
// and exited 0. All 96 keys had been fed to a buffer that held nothing, and
// the last line of the report claimed every one of them had been applied. The
// read that could not happen returned something indistinguishable from a
// legitimately empty read, and the success report was built on top of it.
//
// So three things are asserted here, and the first is the anti-vacuity guard
// for the other two: the SAME invocation on a file that IS there must succeed
// and must report a key count. Without it, "exit 1, nothing on stdout" would
// also be what a program which refused to run at all would produce.
//
// 1. a named file that cannot be read  -> non-zero exit, one line on STDERR
//    naming it, NOTHING on stdout, and no index trap anywhere;
// 2. the same file, present            -> exit 0, the file's own text in the
//    dump, and the key count the script really ran;
// 3. a script cut short by a command   -> the count says how many keys ran, and
//    does NOT claim the whole script. That is the "96 of 96" line again, in
//    the only shape where it can be observed from the outside.

const TDIR = "/tmp/editor_selfcheck";
let SELF = "";                            // ./editor, from argv()[0]

// The two key scripts. Neither writes: the check must not touch golden/ or
// data/, and `:q!` rather than `:q` so a dirty buffer cannot turn the quit into
// E37 and leave the rest of the script running -- that would make the expected
// key count depend on whether the edit landed.
const KS_FULL = "gg0ciwone<Esc>:q!<CR>";          // 14 keys, all of them run
const KS_SHORT = KS_FULL + "x9x9x9";              // 20 decoded, 14 run

def slurp(p: str) -> str {
    let r = fs.read_file(p);
    if (is_some(r)) { return unwrap(r) };
    ""
};

// Run the built binary on `path` with the key script `ks`, capturing stdout and
// stderr SEPARATELY and its exit status in a file.  `> f 2> g` and not `2>&1`
// first: the point of these assertions is which stream a message came out of,
// so the two cannot be merged.  Returns the shell's own status, which is 0
// whenever the redirection and the `echo` worked -- it says nothing about the
// editor, whose status lands in rc.txt.
def run_editor(ks: str, path: str) -> long {
    exec(SELF + " --no-tty --keys '" + ks + "' --rows 10 --cols 44 " + path +
         " > " + TDIR + "/out.txt 2> " + TDIR + "/err.txt; echo $? > " + TDIR + "/rc.txt")
};

// The child's exit status, or 0 -1 if it was never captured -- which the caller
// treats as a failure rather than as a pass, so a broken harness cannot make
// these assertions vacuous.
def child_rc() -> long {
    let s = slurp(TDIR + "/rc.txt");
    if (len(s) < 1) { return 0 - 1 };
    tolong(s)!
};

def p_missing() -> long {
    group("g input file errors");
    let m0 = mark();

    // ---- in process: the verdict itself, before anything shells out --------
    // The control comes FIRST.  A `false` from buf.load is only evidence if a
    // `true` is reachable from the same call on a file that exists, or "the
    // load always fails" would satisfy the rest of this group.
    let here = fs.read_file("data/demo.txt");
    ok(is_some(here), "the demo file is where the gate runs it");
    ok(buf.load("data/demo.txt"), "a file that IS there loads");
    ok(buf.nlines() > 1, "... and it brought its lines with it: " + tostring(buf.nlines()));
    eq_str(buf.line_at(0), "the quick brown fox jumps over the lazy dog",
           "... the first one is the file's own first line");
    // And the missing one: a bool, an empty buffer, and no trap.  The name is
    // under a directory this check never creates, and it is removed first, so
    // a leftover from an earlier run cannot make this pass vacuously.
    let gone = TDIR + "/absent/demo.txt";
    exec("rm -f " + gone);
    ok(fs.read_file(gone) == none, "the path under test really is not there");
    ok(!buf.load(gone), "a file that is NOT there does not load");
    eq_long(buf.nlines(), 1, "... and leaves one empty line to draw rather than garbage");
    eq_str(buf.line_at(0), "", "... which really is empty");

    // ---- out of process: the three things the brief asks for ---------------
    // SELF is argv()[0], handed in by editor.y.  If it is empty the rest of
    // this group would compare two absences and pass, so that is a failure.
    if (len(SELF) < 1) {
        ok(false, "the path of this program is known, so it can be run");
        return CHECKS - m0
    };
    if (!fs.make_dirs(TDIR)) {
        ok(fs.is_dir(TDIR), "the scratch directory " + TDIR + " is usable");
        return CHECKS - m0
    };
    exec("rm -f " + TDIR + "/out.txt " + TDIR + "/err.txt " + TDIR + "/rc.txt");

    // 1. the missing file, the whole case this group is for
    ok(run_editor(KS_FULL, gone) == 0, "the harness itself ran");
    let rc = child_rc();
    let out = slurp(TDIR + "/out.txt");
    let err = slurp(TDIR + "/err.txt");
    ok(rc > 0, "a named input file that cannot be read exits NON-ZERO, got " + tostring(rc));
    ok(len(err) > 0, "... and says so: [" + trim(err) + "]");
    ok(err.index_of(gone) >= 0, "... naming the file it could not read");
    // The load-bearing one.  A diagnostic on stdout would satisfy "it printed
    // something" while corrupting every diff the dump is ever compared in, and
    // a trap prints there too -- so an empty stdout is the claim, not a
    // cosmetic one: no golden bytes, no key count, nothing.
    ok(len(out) == 0, "... and prints NOTHING on stdout, got " + tostring(len(out)) + "B: [" + trim(out) + "]");
    ok(out.index_of("--- keys") < 0, "... so no key count is claimed at all");
    ok(err.index_of("runtime error:") < 0, "... and the diagnostic is not an index trap reported as one");

    // 2. the same invocation with the file there.  Two things have to be true or
    // the assertions above mean nothing: it must succeed, and it must report
    // text that came out of the file -- so "empty stdout" above is a decision
    // about a missing file, not about a program that never reads one.
    ok(run_editor(KS_FULL, "data/demo.txt") == 0, "the harness itself ran with the file present");
    let rc2 = child_rc();
    let out2 = slurp(TDIR + "/out.txt");
    ok(rc2 == 0, "with the file present the same script exits 0, got " + tostring(rc2));
    ok(out2.index_of("the quick brown fox jumps over the lazy dog") >= 0,
       "... and the dump carries the file's own text, so the empty stdout above was a decision");
    ok(out2.index_of("--- keys 14 of 14 ---") >= 0,
       "... and the count is 14 of 14, every key of that script applied");

    // 3. a script a command cuts short.  This is the "96 of 96" line, in the
    // one shape where it can be observed: the trailing x9x9x9 is never reached,
    // so a count that reported the script's length would say 20 of 20.
    ok(run_editor(KS_SHORT, "data/demo.txt") == 0, "the harness itself ran on the cut-short script");
    let rc3 = child_rc();
    let out3 = slurp(TDIR + "/out.txt");
    ok(rc3 == 0, "a script that quits early still exits 0, got " + tostring(rc3));
    ok(out3.index_of("--- keys 14 of 20 ---") >= 0,
       "... and reports the keys it actually applied, not the keys it was handed");
    ok(out3.index_of("--- keys 20 of 20 ---") < 0,
       "... and specifically does not claim the six it never reached");
    CHECKS - m0
};

// ===========================================================================
// the runner
// ===========================================================================

def run(seed: long, self: str) -> long {
    SELF = self;
    CHECKS = 0;
    FAILED = 0;
    puts("property checks -- seven groups, no reference file involved\n");
    note("seed " + tostring(seed));
    // The wording is deliberate: it must NOT contain the trap text itself.
    // A harness greps the whole output for that string, so a note explaining that
    // traps print on stdout made it report "a runtime trap fired" about a
    // run in which every check passed.
    note("an index trap prints its message on STDOUT, so it would show up here");
    note("as a MISSING line rather than an error; surviving is part of the check\n");
    puts("");
    let t0 = p_undo();
    let t1 = p_substitute();
    let t2 = p_boundary();
    let t3 = p_model();
    let t4 = p_viewport();
    let t5 = p_utf8();
    let t6 = p_missing();
    puts("\n");
    puts("  (a) undo invariant                    " + tostring(t0) + " checks\n");
    puts("  (b) substitute correctness            " + tostring(t1) + " checks\n");
    puts("  (c) boundary safety                   " + tostring(t2) + " checks\n");
    puts("  (d) independent model                  " + tostring(t3) + " checks\n");
    puts("  (e) viewport minimality               " + tostring(t4) + " checks\n");
    puts("  (f) utf-8 column algebra              " + tostring(t5) + " checks\n");
    puts("  (g) input file error path             " + tostring(t6) + " checks");
    puts("");
    if (FAILED == 0) {
        puts("\n== " + tostring(CHECKS) + " checks, " + tostring(CHECKS) + " ok, 0 failed ==\n");
        return 0
    };
    puts("\n== " + tostring(CHECKS) + " checks, " + tostring(FAILED) + " FAILED ==\n");
    1
};

// Only run() is reached from editor.y; everything else here is the
// check's own business, and the helpers it drives are deliberately not part
// of any module's surface.
export { run };