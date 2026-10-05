// buf.y -- the document, the cursor, the viewport, the change log, the
// motions, the operator ranges and the ex commands, for examples/editor.
//
// A Vi-style editor has three layers. This file owns the bottom two:
//   * the TEXT      -- L, a [str] of lines, never zero of them
//   * the VIEW      -- CL/CC/WANT (cursor) and TOP/HCOL (scroll offsets)
//   * the HISTORY   -- UN/UP, snapshot stacks, plus the yank register
// The mode machine on top is modes.y and the painting is screen.y. Nothing
// here knows about a terminal, a key or an escape sequence, and nothing here
// allocates on a redraw path.
//
// ===========================================================================
// WHY EVERY COLUMN IS CLAMPED BY HAND
//
// Array and string indexing are bounds-checked, and the runtime trap is
// `runtime error: index out of bounds` printed on STDOUT (ORCHESTRATOR.md
// 2.6) -- so a trap in a redraw silently corrupts the very diff it is in
// rather than announcing itself. `byte_at(s, i)` traps too, while the *slice*
// s[0:99] clamps: verified against the pinned compiler, byte_at("hi", 9)
// traps and "hi"[0:99] is "hi". So nothing here indexes a line without first
// proving 0 <= i <= len(line), and check.y's (c) boundary safety drives the
// cursor at every edge and asserts the invariants rather than trusting them.
//
// ===========================================================================
// COLUMNS ARE BYTE OFFSETS, WITH UTF-8 AWARENESS AT THE EDGES
//
// A column is a byte offset into its line. Screen columns differ from byte
// columns exactly when a line holds multi-byte UTF-8, so every place that
// steps one character forward or back goes through adv() / prev_start(),
// which skip a whole code point instead of one byte. check.y's (f) asserts
// that those visit exactly the character starts.
//
// A tab is one byte and therefore one screen column. Real vi expands tabs to
// the next multiple of 8; this editor does not, and README.md says so. The
// trade is deliberate: identity between byte column and screen column is what
// makes the horizontal-scroll property checkable at all.
//
// ===========================================================================
// UNDO IS A SNAPSHOT STACK, AND ONE SNAPSHOT IS THE WHOLE FILE AS ONE STRING
//
// `text()` is "\n".join(L), so an undo entry is one string rather than an
// array of N string headers. INSERT keystrokes coalesce into a single entry
// (PENDING stays set until the mode machine calls end_change()), which is what
// vi does with an undo block: type "hello", press Escape, press u, and all
// five characters come back at once.
//
// "\n".join(...) is the separator-FIRST form (ORCHESTRATOR.md 2.12): join
// puts the separator first, so it is "\n".join(L) and never L.join("\n").
//
// ===========================================================================
// WHERE THIS DEVIATES FROM VI, AND WHY (all of it is in README.md too)
//   * `dw` never joins two lines. A charwise operator range is clamped to the
//     cursor's own line, so `d2w` on the last word of a line deletes that word
//     and leaves the newline alone. Real vi's `d2w` joins. Clamping keeps
//     `cw`, `yiw` and `dw` agreeing with each other, which is the property
//     that actually bites a reader.
//   * `/pattern` and `n` match a literal string; there is no regex.
//   * Tabs are one column (above).
//   * Saving always ends the file with a newline, as every text editor does.

// The one module import is fs, for read_file / write_file.  buf.y is the only
// file here that touches the filesystem.
import fs;

// ---- the document --------------------------------------------------------
let L: [str] = [""];

// ---- the cursor and the viewport ----------------------------------------
let CL = 0;                 // cursor line, 0-based
let CC = 0;                 // cursor column: a byte offset, 0 .. len(line)
let WANT = 0;               // the column j/k would like to return to
let TOP = 0;                // first visible line
let HCOL = 0;               // first visible byte column of the text area
let WROWS = 22;             // the text area's height, in rows
let WCOLS = 78;             // the whole screen's width, in columns
let GUT = 2;                // the gutter width, in cells (0 = no numbers)
let NUMS = true;           // show line numbers

// ---- file state ----------------------------------------------------------
let PATH = "";
let DIRTY = false;

// ---- the change log ------------------------------------------------------
const UNDO_MAX = 128;
let UN: [str] = [];
let UP: [str] = [];
let PENDING = false;        // an undo entry is open (INSERT coalescing)

// ---- the yank register ---------------------------------------------------
let REG = "";
let REG_LW = false;         // the register holds whole lines

// ---- the last search pattern --------------------------------------------
let SEARCH = "";
let SEARCH_BACK = false;

// ---- the message log -----------------------------------------------------
// Owned here rather than by the mode machine because every operation that can
// report one lives in this file.  Written from edit paths only, so a redraw
// never touches it.
let LOG: [str] = [];
const LOG_MAX = 64;
let LAST = "";

// ---- operator kinds ------------------------------------------------------
const OP_Y = 1;
const OP_D = 2;
const OP_C = 3;

// ---- motion ids ----------------------------------------------------------
const M_NONE = 0;
const M_H = 1;
const M_J = 2;
const M_K = 3;
const M_L = 4;
const M_W = 5;
const M_B = 6;
const M_E = 7;
const M_ZERO = 8;
const M_CARET = 9;
const M_DOLLAR = 10;
const M_GG = 11;
const M_G = 12;
const M_OBRACE = 13;
const M_CBRACE = 14;

// ---- text object ids -----------------------------------------------------
const T_IW = 1;
const T_AW = 2;
const T_IQ = 3;
const T_AQ = 4;

// A Pos is a cursor target.  A motion returns one WITHOUT moving; the mode
// machine decides whether to move the cursor or to turn it into a span.
type Pos = { line: long, col: long };

// A Span is the region an operator acts on.  Charwise: (lo_line,lo_col) to
// (hi_line,hi_col) with the hi column EXCLUSIVE.  Linewise: lo_line..hi_line
// both INCLUSIVE and the columns unused.  A span with lo_line < 0 means
// "nothing to do" -- the shape an unmatched text object returns.
type Span = { lo_line: long, lo_col: long, hi_line: long, hi_col: long, linewise: bool };

def no_span() -> Span { { lo_line: 0 - 1, lo_col: 0, hi_line: 0 - 1, hi_col: 0, linewise: false } };

def make_span(ll: long, lc: long, hl: long, hc: long, lw: bool) -> Span {
    { lo_line: ll, lo_col: lc, hi_line: hl, hi_col: hc, linewise: lw }
};

// ===========================================================================
// character classes
// ===========================================================================

// Every byte >= 128 is a keyword character, because in a UTF-8 locale they are
// all lead or continuation bytes of a code point that is not punctuation.  That
// is what makes `w` treat "hello" with an accent in it as ONE word instead of
// three, and it is why `cls_of` classifies a lead byte the same way as `o`.
def is_word(b: long) -> bool {
    (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b >= 128
};

def is_space(b: long) -> bool { b == 32 || b == 9 };

// 0 = space, 1 = keyword, 2 = everything else.  A byte >= 128 leads a
// multi-byte code point and classifies as "other", so a whole UTF-8 character
// is one run of class 2 and the word scanner never lands inside one.
def cls_of(b: long) -> long {
    if (is_word(b)) { 1 } else if (is_space(b)) { 0 } else { 2 }
};

def is_ctrl(b: long) -> bool { b < 32 || b == 127 };

// ===========================================================================
// UTF-8 stepping
// ===========================================================================

def cont(b: long) -> bool { (b & 192) == 128 };

// How many bytes the code point starting with `b` occupies.  A truncated tail
// reports 1 rather than running a step past the end of the line.
def ulen(b: long) -> long {
    if (b < 128) { 1 }
    else if ((b & 224) == 192) { 2 }
    else if ((b & 240) == 224) { 3 }
    else if ((b & 248) == 240) { 4 }
    else { 1 }
};

// The first byte at or after `i` that is not a continuation byte, clamped to
// [0, len(s)].  `i` may be len(s), may be past it, and may be a continuation
// byte: all three mean "the start of the code point covering i".
//
// The `k < n` in the guard is load-bearing.  Clamping `k` to len(s) leaves it at
// len(s), which is still one PAST the last index -- and byte_at traps there
// (`runtime error: index out of bounds`, on stdout).  check.y's (f) found it by
// asking for snapb(s, 99) on a 9-byte line, which is a question the rest of the
// program never asks and a reader would not spot.
def snapb(s: str, i: long) -> long {
    let n = len(s);
    let k = i;
    if (k < 0) { k = 0; };
    if (k > n) { k = n; };
    let go = k > 0 && k < n;
    while (go && cont(byte_at(s, k))) { k = k - 1; go = k > 0; };
    k
};

// One character forward from a character start.
def adv(s: str, i: long) -> long {
    let n = len(s);
    if (i < 0 || i >= n) { return n; };
    let j = i + ulen(byte_at(s, i));
    if (j > n) { j = n; };
    j
};

// One character backward: the start of the code point before `i`.
def prev_start(s: str, i: long) -> long {
    if (i <= 0) { return 0; };
    snapb(s, i - 1)
};

// The byte offset of the LAST character of `s` -- what $ lands on.
def last_start(s: str) -> long {
    let n = len(s);
    if (n == 0) { return 0; };
    snapb(s, n - 1)
};

// How many code points s[lo:hi] holds -- which is how many SCREEN COLUMNS it
// holds, and therefore how far the cursor is from the left edge once the line is
// scrolled.  For ASCII this is the subtraction, so it is cheap; only a line with
// multi-byte text costs a walk, and only when the cursor is on it.
def nchars(s: str, lo: long, hi: long) -> long {
    let a = lo;
    if (a < 0) { a = 0; };
    let b = hi;
    if (b > len(s)) { b = len(s) };
    let n = 0;
    let i = a;
    let go = i < b;
    while (go) {
        i = adv(s, i);
        n = n + 1;
        go = i < b
    };
    n
};

// The byte offset of the k-th code point at or after `from`, or len(s) when
// there are not that many.  The inverse of nchars over a prefix.
def char_at(s: str, from0: long, k: long) -> long {
    let i = from0;
    if (i < 0) { i = 0 };
    let n = 0;
    let go = n < k && i < len(s);
    while (go) {
        i = adv(s, i);
        n = n + 1;
        go = n < k && i < len(s)
    };
    i
};

// The first non-blank column, what ^ lands on.
def first_nonspace(s: str) -> long {
    let i = 0;
    let go = i < len(s);
    while (go) {
        if (is_space(byte_at(s, i))) { i = i + 1; } else { go = false; };
    };
    i
};

// ===========================================================================
// messages
// ===========================================================================

def msg(s: str) -> void {
    LAST = s;
    LOG += s;
    if (len(LOG) > LOG_MAX) { LOG = LOG[len(LOG) - LOG_MAX:] }
};

def last_msg() -> str { LAST };
def log() -> [str] { LOG };
def log_count() -> long { len(LOG) };
def log_text() -> str { "\n".join(LOG) };

// ===========================================================================
// the document's shape
// ===========================================================================

def nlines() -> long { len(L) };
def line_at(i: long) -> str { if (i >= 0 && i < len(L)) { L[i] } else { "" } };
def path() -> str { PATH };
def set_path(p: str) -> void { PATH = p };
def dirty() -> bool { DIRTY };
def gutter() -> long { GUT };
def numbers() -> bool { GUT > 0 };

// The whole document as one string, lines joined by LF.  This is what an undo
// entry stores and what the dump prints: a per-operation cost, never a
// per-redraw one.
def text() -> str { "\n".join(L) };

// The file's size on disk: the text plus the newline that ends every line but
// the last.
def nbytes() -> long {
    let n = 0 - 1 + len(L);
    let i = 0;
    while (i < len(L)) { n = n + len(L[i]); i = i + 1; };
    n
};

def replace_text(s: str) -> void {
    let xs = s.lines();
    if (len(xs) == 0) { xs = [""]; };
    L = xs
};

// ===========================================================================
// the cursor
// ===========================================================================

// Put the cursor inside the document.  `insert_ok` allows the one position
// normal mode has no business being in: one past the last character, which is
// where INSERT mode's cursor sits at the end of a line.
def clamp_cursor(insert_ok: bool) -> void {
    if (len(L) == 0) { L = [""]; };
    if (CL < 0) { CL = 0; };
    if (CL > len(L) - 1) { CL = len(L) - 1; };
    let s = L[CL];
    let n = len(s);
    let hi = n;
    if (!insert_ok && n > 0) { hi = n - 1; };
    if (CC > hi) { CC = hi; };
    if (CC < 0) { CC = 0; };
    if (WANT > n) { WANT = n; };
    if (WANT < 0) { WANT = 0; }
};

def cursor_line() -> long { CL };
def cursor_col() -> long { CC };
def top() -> long { TOP };
def hcol() -> long { HCOL };
def view_rows() -> long { WROWS };
def view_cols() -> long { WCOLS };

// The text area's width in cells: the screen minus the gutter.
def textw() -> long { if (WCOLS > GUT) { WCOLS - GUT } else { 1 } };

// Park the cursor at (ln, col) and pull the viewport after it.
def goto(ln: long, col: long, insert_ok: bool) -> void {
    CL = ln;
    CC = col;
    clamp_cursor(insert_ok);
    WANT = CC;
    scroll_fix()
};

// The viewport's shape, and the gutter's width.  The gutter is the line numbers
// plus one separating space, so its width follows the file: a 9-line file gets
// one digit of gutter and a 1000-line file gets four.  Computing it here rather
// than in screen.y keeps the text area's width -- which buf.scroll_fix() needs
// -- in step with what is actually painted.
def viewport(rows: long, cols: long) -> void {
    if (rows < 1) { rows = 1; };
    if (cols < 1) { cols = 1; };
    WROWS = rows;
    WCOLS = cols;
    if (NUMS) {
        GUT = digits_of(nlines()) + 1
    } else {
        GUT = 0
    };
    scroll_fix()
};

// Decimal digits of a count, minimum 1.  Duplicated from screen.y on purpose:
// three lines is cheaper than a cross-module call on every redraw, and both
// copies are asserted against each other by check.y's (e).
def digits_of(v: long) -> long {
    let n = v;
    if (n < 1) { return 1 };
    let k = 0;
    while (n > 0 && k < 18) { k = k + 1; n = n / 10 };
    k
};

def numbers_on(b: bool) -> void { NUMS = b };

// Keep the cursor on screen with the smallest scroll that does it.  Two rules
// make the offsets minimal, and check.y's (e) asserts both:
//   * vertically TOP moves only far enough to bring CL in;
//   * horizontally a cursor that fits inside the first screen forces HCOL to 0
//     -- otherwise the text would stay shifted left over from a longer line
//     that was on screen before, which is the classic "the whole file jumped
//     sideways" bug.
def scroll_fix() -> void {
    if (WROWS < 1) { WROWS = 1; };
    if (WCOLS < 1) { WCOLS = 1; };
    if (len(L) == 0) { L = [""]; };
    if (CL < 0) { CL = 0; };
    if (CL > len(L) - 1) { CL = len(L) - 1; };
    let last = len(L) - 1;
    if (TOP > last) { TOP = last; };
    if (TOP < 0) { TOP = 0; };
    if (CL < TOP) { TOP = CL; };
    if (CL > TOP + WROWS - 1) { TOP = CL - WROWS + 1; };
    if (TOP > last) { TOP = last; };
    if (TOP < 0) { TOP = 0; };
    // Horizontal, in CODE POINTS: a cursor that fits inside the first screen
    // forces HCOL to 0 (otherwise the text stays shifted left over from a longer
    // line that was on screen before), and otherwise HCOL is the smallest left
    // edge that still leaves the cursor inside the window -- which is the minimal
    // scroll, asserted by check.y's (e).
    let tw = textw();
    let s = L[CL];
    if (nchars(s, 0, CC) < tw) {
        HCOL = 0
    } else {
        if (CC < HCOL) { HCOL = CC; };
        let hc = nchars(s, HCOL, CC);
        if (hc >= tw) { HCOL = char_at(s, HCOL, hc - tw + 1) }
    };
    if (HCOL < 0) { HCOL = 0 }
};

// Ctrl-E / Ctrl-Y: move the window, then bring the CURSOR into view -- which is
// what vi does, and is the only way a half-page scroll is useful at the top of a
// file (pinned the other way, Ctrl-E at line 1 could never move the window).
// The cursor's column is re-derived because the line it lands on may be shorter
// than the one it left.
def scroll_by(delta: long) -> void {
    let nl = TOP + delta;
    if (nl < 0) { nl = 0; };
    if (nl > len(L) - 1) { nl = len(L) - 1; };
    TOP = nl;
    if (CL < TOP) { CL = TOP; CC = first_nonspace(L[CL]); };
    if (CL > TOP + WROWS - 1) { CL = TOP + WROWS - 1; CC = first_nonspace(L[CL]); };
    clamp_cursor(false);
    scroll_fix()
};

def scroll_page(dir: long) -> void {
    let half = WROWS / 2;
    if (half < 1) { half = 1; };
    scroll_by(half * dir)
};

// ===========================================================================
// the change log
// ===========================================================================

// Open an undo entry.  Every mutating primitive below calls this FIRST, so a
// keystroke that changes nothing never pushes an entry, and a run of INSERT
// keystrokes shares one because PENDING is not cleared until the mode machine
// calls end_change().
def begin_change() -> void {
    if (!PENDING) {
        UN += text();
        if (len(UN) > UNDO_MAX) { UN = UN[1:]; };
        UP = [];
        PENDING = true
    }
};

def end_change() -> void { PENDING = false };

// Throw the history away.  Used by check.y between phases, and by nothing else
// -- an editor that can silently forget its undo stack is not an editor.
def reset_history() -> void {
    UN = [];
    UP = [];
    PENDING = false;
    DIRTY = false
};

def undo_depth() -> long { len(UN) };
def undo_max() -> long { UNDO_MAX };
def redo_depth() -> long { len(UP) };

def undo() -> bool {
    if (len(UN) == 0) { return false; };
    UP += text();
    let s = UN[len(UN) - 1];
    UN = UN[0:len(UN) - 1];
    replace_text(s);
    PENDING = false;
    DIRTY = true;
    clamp_cursor(false);
    scroll_fix();
    true
};

def redo() -> bool {
    if (len(UP) == 0) { return false; };
    UN += text();
    let s = UP[len(UP) - 1];
    UP = UP[0:len(UP) - 1];
    replace_text(s);
    PENDING = false;
    DIRTY = true;
    clamp_cursor(false);
    scroll_fix();
    true
};

// ===========================================================================
// search -- a literal string, deliberately.  The scanner below is the naive
// one; check.y's (b) checks the global substitute against the std's KMP
// str.replace, and two independent implementations agreeing is the point.
// ===========================================================================

def find_from(s: str, pat: str, from: long) -> long {
    let n = len(s);
    let m = len(pat);
    let hit = 0 - 1;
    if (m > 0 && m <= n) {
        let i = from;
        if (i < 0) { i = 0; };
        let go = i <= n - m;
        while (go) {
            let j = 0;
            let same = true;
            while (j < m && same) {
                if (byte_at(s, i + j) != byte_at(pat, j)) { same = false; };
                j = j + 1;
            };
            if (same) { hit = i; go = false; } else { i = i + 1; go = i <= n - m; };
        };
    };
    hit
};

// Set the pattern `n` re-searches with, and report whether anything has one.
def set_search(pat: str, back: bool) -> void {
    SEARCH = pat;
    SEARCH_BACK = back
};

def search_pat() -> str { SEARCH };
def search_back() -> bool { SEARCH_BACK };

// The next line at or after `from` that contains `pat`, wrapping once.  -1
// when the pattern is nowhere.
def next_match(from: long, pat: str, backwards: bool) -> long {
    let n = len(L);
    let hit = 0 - 1;
    if (n == 0 || len(pat) == 0) { return hit; };
    let i = from;
    if (i < 0) { i = 0; };
    if (i > n - 1) { i = n - 1; };
    if (!backwards) {
        let k = i;
        let go = k < n;
        while (go) {
            if (find_from(L[k], pat, 0) >= 0) { hit = k; go = false; } else { k = k + 1; };
        };
        if (hit < 0) {
            let k = 0;
            let go = k < n;
            while (go) {
                if (find_from(L[k], pat, 0) >= 0) { hit = k; go = false; } else { k = k + 1; };
            };
        }
    } else {
        let k = i - 1;
        if (k > n - 1) { k = n - 1; };
        let go = k >= 0;
        while (go) {
            if (find_from(L[k], pat, 0) >= 0) { hit = k; go = false; } else { k = k - 1; };
        };
        if (hit < 0) {
            let k = n - 1;
            let go = k >= 0;
            while (go) {
                if (find_from(L[k], pat, 0) >= 0) { hit = k; go = false; } else { k = k - 1; };
            };
        }
    };
    hit
};

// ===========================================================================
// mutating primitives.  Every one opens an undo entry FIRST, so a keystroke
// that changes nothing never leaves a no-op entry behind.
// ===========================================================================

// Write one line outright.  No undo entry: the callers have opened one, and
// this is the raw write they build their result with.
def put_line(i: long, s: str) -> void {
    if (i >= 0 && i < len(L)) { L[i] = s }
};

def insert_str(ln: long, col: long, s: str) -> void {
    begin_change();
    if (ln < 0 || ln > len(L) - 1) { return; };
    let l = L[ln];
    let c = col;
    if (c < 0) { c = 0; };
    if (c > len(l)) { c = len(l); };
    L[ln] = l[0:c] + s + l[c:];
    DIRTY = true
};

def insert_byte(ln: long, col: long, b: long) {
    insert_str(ln, col, chr(b & 255))
};

// Delete [c0, c1) of one line.
def delete_cols(ln: long, c0: long, c1: long) -> void {
    begin_change();
    if (ln < 0 || ln > len(L) - 1) { return; };
    let l = L[ln];
    let a = c0;
    let b = c1;
    if (a < 0) { a = 0; };
    if (b > len(l)) { b = len(l); };
    if (b < a) { b = a; };
    L[ln] = l[0:a] + l[b:];
    DIRTY = true
};

// Delete [ln0,c0) .. [ln1,c1), which may cross lines: everything between the
// two lines goes with it and line ln0's head joins line ln1's tail.  The
// document always keeps at least one line.
def delete_span(ln0: long, c0: long, ln1: long, c1: long) -> void {
    begin_change();
    if (ln0 < 0 || ln0 > len(L) - 1) { return; };
    let hi = ln1;
    if (hi < ln0) { hi = ln0; };
    if (hi > len(L) - 1) { hi = len(L) - 1; };
    if (ln0 == hi) { delete_cols(ln0, c0, c1); return; };
    let a = L[ln0];
    let b = L[hi];
    let x = c0;
    let y = c1;
    if (x < 0) { x = 0; };
    if (x > len(a)) { x = len(a); };
    if (y < 0) { y = 0; };
    if (y > len(b)) { y = len(b); };
    let out: [str] = [];
    let i = 0;
    while (i < len(L)) {
        if (!(i > ln0 && i <= hi)) { out += L[i] };
        i = i + 1;
    };
    if (len(out) == 0) { out = [""]; };
    out[ln0] = a[0:x] + b[y:];
    L = out;
    DIRTY = true
};

// Delete whole lines [a, b] inclusive, keeping at least one.
def delete_lines(a0: long, b0: long) -> void {
    begin_change();
    let a = a0;
    let b = b0;
    if (a < 0) { a = 0; };
    if (b > len(L) - 1) { b = len(L) - 1; };
    if (a > b) { return; };
    let out: [str] = [];
    let i = 0;
    while (i < len(L)) {
        if (!(i >= a && i <= b)) { out += L[i] };
        i = i + 1;
    };
    if (len(out) == 0) { out = [""]; };
    L = out;
    DIRTY = true
};

// J: join line ln with the one below.  A space goes in unless the line already
// ends in whitespace or the next one starts with ')', which is vi's rule and
// stops "foo(" + ")" becoming "foo ( )".
def join_down(ln: long) -> bool {
    begin_change();
    if (ln < 0 || ln > len(L) - 2) { return false; };
    let a = L[ln];
    let b = L[ln + 1];
    let sep = " ";
    let n = len(a);
    if (n > 0 && is_space(byte_at(a, n - 1))) { sep = ""; };
    if (len(b) > 0 && byte_at(b, 0) == 41) { sep = ""; };
    L[ln] = a + sep + b;
    delete_lines(ln + 1, ln + 1);
    DIRTY = true;
    true
};

// Enter in INSERT: break the line at `col`, leaving the cursor after the break.
// The head replaces the line and the tail becomes the new one -- pushing the
// WHOLE line and then the tail (which is what this did first) duplicates the
// text instead of splitting it, and the model-vs-editor property check is what
// caught it: the editor said "epsilon zeta" where the model said "epsilon".
def split_at(ln: long, col: long) -> void {
    begin_change();
    if (ln < 0 || ln > len(L) - 1) { return; };
    let l = L[ln];
    let c = col;
    if (c < 0) { c = 0; };
    if (c > len(l)) { c = len(l); };
    let head = l[0:c];
    let tail = l[c:];
    let out: [str] = [];
    let i = 0;
    while (i < len(L)) {
        if (i == ln) {
            out += head;
            out += tail
        } else {
            out += L[i]
        };
        i = i + 1
    };
    L = out;
    DIRTY = true;
    CC = len(head);
    WANT = CC
};

// Backspace at the start of a line: pull it onto the end of the one above.
def backspace_join() -> void {
    begin_change();
    if (CL <= 0) { return; };
    let a = L[CL - 1];
    L[CL - 1] = a + L[CL];
    delete_lines(CL, CL);
    DIRTY = true;
    CL = CL - 1;
    CC = len(a);
    WANT = CC
};

// o / O: open an empty line below / above the cursor.
def open_line(below: bool) -> void {
    begin_change();
    let at = 0;
    if (below) { at = CL + 1; } else { at = CL; };
    let out: [str] = [];
    let i = 0;
    while (i < len(L)) {
        if (i == at) { out += ""; };
        out += L[i];
        i = i + 1;
    };
    if (at >= len(L)) { out += ""; };
    L = out;
    DIRTY = true;
    CL = at;
    CC = 0;
    WANT = 0
};

// ===========================================================================
// the yank register
// ===========================================================================

// The text a span covers, LF between the lines.
def span_text(sp: Span) -> str {
    if (sp.lo_line < 0) { return ""; };
    if (sp.linewise) {
        let out: [str] = [];
        let i = sp.lo_line;
        while (i <= sp.hi_line) {
            if (i >= 0 && i < len(L)) { out += L[i] };
            i = i + 1;
        };
        return "\n".join(out);
    };
    let a = L[sp.lo_line];
    let b = L[sp.hi_line];
    let x = sp.lo_col;
    let y = sp.hi_col;
    if (x < 0) { x = 0; };
    if (y > len(b)) { y = len(b); };
    if (sp.lo_line == sp.hi_line) { return a[x:y]; };
    let mid: [str] = [];
    let i = sp.lo_line + 1;
    while (i < sp.hi_line) {
        if (i >= 0 && i < len(L)) { mid += L[i] };
        i = i + 1;
    };
    a[x:] + "\n".join(mid) + b[0:y]
};

def yank(sp: Span) -> void {
    if (sp.lo_line < 0) { return; };
    REG = span_text(sp);
    REG_LW = sp.linewise
};

def reg() -> str { REG };
def reg_lw() -> bool { REG_LW };
def reg_set(s: str, lw: bool) -> void { REG = s; REG_LW = lw };

// p / P.  A linewise register goes back as whole lines; a charwise one goes
// back at the cursor (before) or just after the character under it (after),
// which is the one asymmetry vi has here.
def put(before: bool, count: long) -> bool {
    if (len(REG) == 0) { msg("E353: nothing in the register"); return false; };
    begin_change();
    let n = count;
    if (n < 1) { n = 1; };
    if (REG_LW) {
        let pieces = REG.lines();
        if (len(pieces) == 0) { pieces = [""]; };
        let at = 0;
        if (before) { at = CL; } else { at = CL + 1; };
        let out: [str] = [];
        let i = 0;
        while (i < len(L)) {
            if (i == at) {
                let k = 0;
                while (k < n) {
                    let j = 0;
                    while (j < len(pieces)) { out += pieces[j]; j = j + 1 };
                    k = k + 1
                }
            };
            out += L[i];
            i = i + 1
        };
        if (at >= len(L)) {
            let k = 0;
            while (k < n) {
                let j = 0;
                while (j < len(pieces)) { out += pieces[j]; j = j + 1 };
                k = k + 1
            }
        };
        L = out;
        CL = at;
        CC = first_nonspace(L[CL]);
        WANT = CC;
        DIRTY = true;
        return true
    };
    // charwise
    let s = L[CL];
    let at = 0;
    if (before) { at = CC; } else { at = adv(s, CC); };
    let ins = "";
    let k = 0;
    while (k < n) { ins += REG; k = k + 1 };
    L[CL] = s[0:at] + ins + s[at:];
    DIRTY = true;
    CC = at;
    if (n > 0 && len(ins) > 0) { CC = prev_start(L[CL], at + len(ins)); };
    WANT = CC;
    true
};

// ===========================================================================
// motions
// ===========================================================================

// One `w` step.  Moves to the next run of a different class, over any
// whitespace in between, and on to the NEXT LINE when this one runs out of
// words -- which is what vi does and what makes `w` useful for crossing short
// lines.  On the last line it stops on the last character.
def w_step(ln: long, col: long) -> Pos {
    let s = L[ln];
    let n = len(s);
    if (n == 0) {
        if (ln < len(L) - 1) { return { line: ln + 1, col: 0 }; };
        return { line: ln, col: 0 }
    };
    let i = col;
    if (i > n - 1) { i = n - 1; };
    if (i < 0) { i = 0; };
    let c = cls_of(byte_at(s, i));
    while (i < n && cls_of(byte_at(s, i)) == c) { i = i + 1; };
    while (i < n && is_space(byte_at(s, i))) { i = i + 1; };
    if (i < n) { return { line: ln, col: snapb(s, i) }; };
    if (ln < len(L) - 1) { return { line: ln + 1, col: 0 }; };
    { line: ln, col: snapb(s, n - 1) }
};

// One `b` step: the start of the previous run.
def b_step(ln: long, col: long) -> Pos {
    if (col <= 0) {
        if (ln > 0) { return { line: ln - 1, col: last_start(L[ln - 1]) }; };
        return { line: 0, col: 0 }
    };
    let s = L[ln];
    let i = col - 1;
    if (i > len(s) - 1) { i = len(s) - 1; };
    while (i > 0 && is_space(byte_at(s, i))) { i = i - 1; };
    if (i <= 0) { return { line: ln, col: 0 }; };
    let c = cls_of(byte_at(s, i));
    while (i > 0 && cls_of(byte_at(s, i - 1)) == c) { i = i - 1; };
    { line: ln, col: snapb(s, i) }
};

// One `e` step: the last character of the next run.
def e_step(ln: long, col: long) -> Pos {
    let s = L[ln];
    let n = len(s);
    if (n == 0) {
        if (ln < len(L) - 1) { return { line: ln + 1, col: 0 }; };
        return { line: ln, col: 0 }
    };
    let i = col;
    if (i < 0) { i = 0; };
    if (i > n - 1) { i = n - 1; };
    while (i < n && is_space(byte_at(s, i))) { i = i + 1; };
    if (i >= n) {
        if (ln < len(L) - 1) { return { line: ln + 1, col: 0 }; };
        return { line: ln, col: n - 1 }
    };
    let c = cls_of(byte_at(s, i));
    while (i + 1 < n && cls_of(byte_at(s, i + 1)) == c) { i = i + 1; };
    { line: ln, col: snapb(s, i) }
};

// Is `m` one of the motions an operator makes linewise?  Only the ones that
// name a line rather than a character: j k gg G { }.
def motion_is_linewise(m: long) -> bool {
    m == M_J || m == M_K || m == M_GG || m == M_G || m == M_OBRACE || m == M_CBRACE
};

// Is `m` an INCLUSIVE motion -- one whose target character is part of the
// operator's range?  `$` and `e` are; the rest are not.
def motion_is_inclusive(m: long) -> bool { m == M_DOLLAR || m == M_E };

// Where motion `m`, repeated `count` times, lands.  `count` is the raw count:
// 0 means "none given", which matters for G (last line) and gg (first line).
// The cursor is NOT moved.
def target(m: long, count: long) -> Pos {
    let c = count;
    let n = len(L);
    let last = n - 1;
    if (last < 0) { last = 0; };
    let ln = CL;
    let col = CC;
    if (m == M_H) {
        let k = c;
        if (k < 1) { k = 1; };
        let i = col;
        let j = 0;
        while (j < k && i > 0) { i = prev_start(L[ln], i); j = j + 1; };
        return { line: ln, col: i }
    };
    if (m == M_L) {
        let k = c;
        if (k < 1) { k = 1; };
        let i = col;
        let j = 0;
        while (j < k && i < len(L[ln]) - 1) { i = adv(L[ln], i); j = j + 1; };
        return { line: ln, col: i }
    };
    if (m == M_J || m == M_K) {
        let k = c;
        if (k < 1) { k = 1; };
        let step = 1;
        if (m == M_K) { step = 0 - 1; };
        let i = ln + k * step;
        if (i < 0) { i = 0; };
        if (i > last) { i = last; };
        // j and k return to the column they wanted, clamped to the new line.
        let want = WANT;
        if (want > len(L[i]) - 1 && len(L[i]) > 0) { want = len(L[i]) - 1; };
        if (want < 0) { want = 0; };
        if (len(L[i]) == 0) { want = 0; };
        return { line: i, col: want }
    };
    if (m == M_W || m == M_B || m == M_E) {
        let k = c;
        if (k < 1) { k = 1; };
        let j = 0;
        while (j < k) {
            let nl = ln;
            let nc = col;
            if (m == M_W) {
                let p = w_step(ln, col);
                nl = p.line;
                nc = p.col
            };
            if (m == M_B) {
                let p = b_step(ln, col);
                nl = p.line;
                nc = p.col
            };
            if (m == M_E) {
                let p = e_step(ln, col);
                nl = p.line;
                nc = p.col
            };
            ln = nl;
            col = nc;
            j = j + 1
        };
        return { line: ln, col: col }
    };
    if (m == M_ZERO) { return { line: ln, col: 0 } };
    if (m == M_CARET) { return { line: ln, col: first_nonspace(L[ln]) } };
    if (m == M_DOLLAR) { return { line: ln, col: last_start(L[ln]) } };
    if (m == M_GG) {
        let i = c - 1;
        if (i < 0) { i = 0; };
        if (i > last) { i = last; };
        return { line: i, col: first_nonspace(L[i]) }
    };
    if (m == M_G) {
        let i = last;
        if (c > 0) { i = c - 1; };
        if (i < 0) { i = 0; };
        if (i > last) { i = last; };
        return { line: i, col: first_nonspace(L[i]) }
    };
    if (m == M_OBRACE) {
        let k = c;
        if (k < 1) { k = 1; };
        let i = ln - k;
        if (i < 0) { i = 0; };
        return { line: i, col: first_nonspace(L[i]) }
    };
    if (m == M_CBRACE) {
        let k = c;
        if (k < 1) { k = 1; };
        let i = ln + k;
        if (i > last) { i = last; };
        return { line: i, col: first_nonspace(L[i]) }
    };
    { line: ln, col: col }
};

// Move the cursor to where motion `m` lands.
def goto_motion(m: long, count: long) -> void {
    let p = target(m, count);
    goto(p.line, p.col, false)
};

// The motion a normal-mode key names, or M_NONE.  Count matters for `0`: with
// a count in hand it is a digit, not the first-column motion.
// `G` is NOT here, and that is deliberate: `G` and `1G` mean different things
// (last line, first line), so the mode machine has to pass the RAW count -- 0 for
// "none typed" -- and it cannot do that through a function that also answers for
// h, j, k, l, w, b, e, which want "at least one".
def motion_id(k: long, counting: bool) -> long {
    if (k == ord("h")) { return M_H; };
    if (k == ord("j")) { return M_J; };
    if (k == ord("k")) { return M_K; };
    if (k == ord("l")) { return M_L; };
    if (k == ord("w")) { return M_W; };
    if (k == ord("b")) { return M_B; };
    if (k == ord("e")) { return M_E; };
    if (k == ord("$")) { return M_DOLLAR; };
    if (k == ord("^")) { return M_CARET; };
    if (k == ord("{")) { return M_OBRACE; };
    if (k == ord("}")) { return M_CBRACE; };
    if (k == ord("0") && !counting) { return M_ZERO; };
    M_NONE
};

// A word, for the status line: a short name for a motion id.
def motion_name(m: long) -> str {
    if (m == M_H) { "h" }
    else if (m == M_J) { "j" }
    else if (m == M_K) { "k" }
    else if (m == M_L) { "l" }
    else if (m == M_W) { "w" }
    else if (m == M_B) { "b" }
    else if (m == M_E) { "e" }
    else if (m == M_ZERO) { "0" }
    else if (m == M_CARET) { "^" }
    else if (m == M_DOLLAR) { "$" }
    else if (m == M_GG) { "gg" }
    else if (m == M_G) { "G" }
    else if (m == M_OBRACE) { "{" }
    else { "}" }
};


// ===========================================================================
// operator ranges
// ===========================================================================

// The span motion `m` repeated `count` times selects, seen from the cursor.
// A charwise span is always clamped to the cursor's own line -- see the header
// on `dw`.
def op_range(m: long, count: long) -> Span {
    let p = target(m, count);
    if (motion_is_linewise(m)) {
        let a = CL;
        let b = p.line;
        if (b < a) { let t = a; a = b; b = t };
        return make_span(a, 0, b, 0, true)
    };
    let a_col = CC;
    let b_col = p.col;
    if (b_col > len(L[CL]) - 1 && len(L[CL]) > 0) { b_col = len(L[CL]) - 1; };
    if (b_col < 0) { b_col = 0; };
    let lo = a_col;
    let hi = b_col;
    if (b_col < a_col) {
        // backward: the character under the cursor survives, the range is
        // [target, cursor)
        lo = b_col;
        hi = a_col;
        if (hi <= lo) { return no_span() };
        return make_span(CL, lo, CL, hi, false)
    };
    hi = b_col;
    if (motion_is_inclusive(m)) { hi = b_col + 1; };
    if (hi <= lo) { hi = lo + 1; };
    make_span(CL, lo, CL, hi, false)
};

// The span a text object selects.  `kind` is one of T_IW / T_AW / T_IQ / T_AQ.
// A quote object with no closing quote on the line returns no_span(), which the
// mode machine turns into a message rather than into a silent nothing.
def textobj_range(kind: long) -> Span {
    if (kind == T_IW || kind == T_AW) { return word_obj(kind == T_AW) };
    quote_obj(kind == T_AQ)
};

// `iw` is the maximal run of one class under the cursor -- a word, a run of
// punctuation, or a run of whitespace.  `aw` is that plus one side's worth of
// whitespace, and when the cursor is ON whitespace it is the whitespace run plus
// the word after it (or the word before, when there is no word after) -- which is
// vi's rule, and the difference is visible: `daw` on the space in "lazy dog"
// removes " dog", not just the space.
def word_obj(around: bool) -> Span {
    let s = L[CL];
    let n = len(s);
    if (n == 0) { return make_span(CL, 0, CL, 0, false) };
    let i = CC;
    if (i > n - 1) { i = n - 1; };
    if (i < 0) { i = 0; };
    let c = cls_of(byte_at(s, i));
    if (c == 0) {
        let a = i;
        while (a > 0 && is_space(byte_at(s, a - 1))) { a = a - 1; };
        let b = i;
        while (b < n && is_space(byte_at(s, b))) { b = b + 1; };
        if (!around) { return make_span(CL, a, CL, b, false) };
        if (b < n) {
            let e = b;
            let cc = cls_of(byte_at(s, e));
            while (e < n && cls_of(byte_at(s, e)) == cc) { e = e + 1; };
            return make_span(CL, a, CL, e, false)
        };
        if (a > 0) {
            let f = a - 1;
            let cc = cls_of(byte_at(s, f));
            while (f > 0 && cls_of(byte_at(s, f - 1)) == cc) { f = f - 1; };
            return make_span(CL, f, CL, b, false)
        };
        return make_span(CL, a, CL, b, false)
    };
    let a = i;
    while (a > 0 && cls_of(byte_at(s, a - 1)) == c) { a = a - 1; };
    let b = i;
    while (b < n && cls_of(byte_at(s, b)) == c) { b = b + 1; };
    if (!around) { return make_span(CL, a, CL, b, false) };
    let t = b;
    while (t < n && is_space(byte_at(s, t))) { t = t + 1; };
    if (t > b) { return make_span(CL, a, CL, t, false) };
    let u = a;
    while (u > 0 && is_space(byte_at(s, u - 1))) { u = u - 1; };
    make_span(CL, u, CL, b, false)
};

// The quote pairs on the cursor's line, as a [long] of byte offsets.
def quote_positions() -> [long] {
    let s = L[CL];
    let out: [long] = [];
    let i = 0;
    while (i < len(s)) {
        if (byte_at(s, i) == 34) { out += i };
        i = i + 1
    };
    out
};

// `i"` / `a"` -- the pair the cursor is inside, or else the first pair at or
// after it.  Double quotes only; there is no regex and no escaping.
def quote_obj(around: bool) -> Span {
    let p = quote_positions();
    if (len(p) < 2) { return no_span() };
    let o = 0 - 1;
    let cl = 0 - 1;
    let k = 0;
    while (k + 1 < len(p)) {
        if (o < 0 && CC > p[k] && CC < p[k + 1]) { o = p[k]; cl = p[k + 1]; };
        k = k + 1
    };
    if (o < 0) {
        let j = 0;
        while (j + 1 < len(p)) {
            if (p[j] >= CC) { o = p[j]; cl = p[j + 1]; j = len(p); } else { j = j + 2; }
        }
    };
    if (o < 0) { return no_span() };
    if (around) { make_span(CL, o, CL, cl + 1, false) };
    make_span(CL, o + 1, CL, cl, false)
};

// ===========================================================================
// applying a span
// ===========================================================================

// Apply `op` to `sp`.  Returns 0 when something happened and 1 when the span
// was empty, so the mode machine can report it.
def apply_span(sp: Span, op: long) -> long {
    if (sp.lo_line < 0) { return 1; };
    if (sp.linewise) { return op_linewise(op, sp.hi_line - sp.lo_line + 1) };
    if (sp.hi_line == sp.lo_line && sp.hi_col <= sp.lo_col) { return 1; };
    if (sp.hi_col > len(L[sp.lo_line])) { return 1; };
    if (op == OP_Y) {
        yank(sp);
        CL = sp.lo_line;
        CC = sp.lo_col;
        clamp_cursor(false);
        scroll_fix();
        return 0
    };
    let want_insert = op == OP_C;
    let keep_line = sp.lo_line;
    let keep_col = sp.lo_col;
    delete_span(sp.lo_line, sp.lo_col, sp.hi_line, sp.hi_col);
    CL = keep_line;
    CC = keep_col;
    clamp_cursor(want_insert);
    scroll_fix();
    0
};

// `dd` / `yy` / `cc` and everything else that works on whole lines.  `count` is
// how many, from the current line down.
def op_linewise(op: long, count: long) -> long {
    let n = count;
    if (n < 1) { n = 1; };
    let last = len(L) - 1;
    let hi = CL + n - 1;
    if (hi > last) { hi = last; };
    if (hi < CL) { hi = CL; };
    if (op == OP_Y) {
        yank(make_span(CL, 0, hi, 0, true));
        CC = first_nonspace(L[CL]);
        clamp_cursor(false);
        scroll_fix();
        return 0
    };
    if (op == OP_D) {
        delete_lines(CL, hi);
        clamp_cursor(false);
        scroll_fix();
        return 0
    };
    // OP_C: the lines collapse to one empty line at the cursor.
    delete_lines(CL, hi);
    if (len(L) == 0) { L = [""]; };
    if (CL > len(L) - 1) { CL = len(L) - 1; };
    put_line(CL, "");
    DIRTY = true;
    CC = 0;
    WANT = 0;
    scroll_fix();
    0
};

// ===========================================================================
// single-key operations
// ===========================================================================

// x: delete `count` characters at the cursor, stopping at the end of the line.
// A line never disappears, which is what stops `x` at the end of a one-line
// file from turning the buffer into nothing.
def delete_chars(count: long) -> long {
    let s = L[CL];
    let n = len(s);
    let at = CC;
    if (n == 0) { return 1; };
    let k = count;
    if (k < 1) { k = 1; };
    let last = n;
    let j = 0;
    while (j < k && at < last) {
        at = adv(s, at);
        j = j + 1
    };
    delete_cols(CL, CC, at);
    clamp_cursor(false);
    scroll_fix();
    0
};

// X: the same, backwards.
def backspace_char() -> long {
    let s = L[CL];
    if (CC == 0) { return 1; };
    delete_cols(CL, prev_start(s, CC), CC);
    clamp_cursor(false);
    scroll_fix();
    0
};

// Backspace in INSERT mode, where the cursor may sit one past the last byte.
def backspace_insert() -> bool {
    if (CC > 0) {
        delete_cols(CL, prev_start(L[CL], CC), CC);
        clamp_cursor(true);
        scroll_fix();
        return true
    };
    if (CL == 0) { return false };
    backspace_join();
    clamp_cursor(true);
    scroll_fix();
    true
};

// ~ : swap the case of the character under the cursor and step right.
def tilde_case(count: long) -> long {
    let s = L[CL];
    if (len(s) == 0) { return 1; };
    let n = count;
    if (n < 1) { n = 1; };
    let i = CC;
    let j = 0;
    while (j < n && i < len(s) - 1) {
        let b = byte_at(s, i);
        let up = b;
        if (b >= 97 && b <= 122) { up = b - 32; };
        if (b >= 65 && b <= 90) { up = b + 32; };
        let ins = chr(up);
        let nxt = adv(s, i);
        delete_cols(CL, i, nxt);
        insert_str(CL, i, ins);
        i = nxt;
        j = j + 1
    };
    CC = i;
    clamp_cursor(false);
    scroll_fix();
    0
};

// ===========================================================================
// substitute
// ===========================================================================

// :s -- replace `pat` on line `ln`.  With `glob` every non-overlapping
// occurrence goes, without it the first one only, which is vi's rule.  The
// return value is the number of replacements ACTUALLY MADE, and check.y's (b)
// holds it against an independent count.  Returns -1 and leaves the buffer
// alone when the pattern is empty.
def substitute_line(ln: long, pat: str, rep: str, glob: bool) -> long {
    if (ln < 0 || ln > len(L) - 1) { return 0 - 1; };
    if (len(pat) == 0) { msg("E35: no previous regular expression"); return 0 - 1; };
    let s = L[ln];
    let out = "";
    let at = 0;
    let count = 0;
    let more = true;
    let hit = find_from(s, pat, 0);
    while (more && hit >= 0) {
        out += s[at:hit];
        out += rep;
        at = hit + len(pat);
        count = count + 1;
        if (glob) { hit = find_from(s, pat, at); } else { more = false; hit = 0 - 1; }
    };
    out += s[at:];
    if (count > 0) {
        begin_change();
        L[ln] = out;
        DIRTY = true
    };
    count
};

// ===========================================================================
// files
// ===========================================================================

// `fs.read_file` answers `str?`, and a path that is not there -- or that cannot
// be opened -- is `none`: not a trap, and not an error the std reports.  So the
// WHOLE optional is settled here, once, with the campaign's idiom -- `is_some`
// decides and `unwrap` takes the value -- and the caller is handed a plain
// `bool` it can branch on plus a buffer it can trust.  Nothing downstream is
// allowed to assume the file was there.
//
// The `none` arm still installs a one-line empty buffer, because an editor has
// to have SOMETHING to draw, but the `false` it returns is the load's verdict
// and the caller has to honour it.  Honouring it is the caller's half; see
// editor.y's load, where not honouring it was a silent success.
def load(p: str) -> bool {
    let got = fs_read(p);
    let ok = false;
    let body = "";
    if (is_some(got)) {
        body = unwrap(got);
        ok = true
    };
    if (ok) { replace_text(body); } else { L = [""]; };
    PATH = p;
    DIRTY = false;
    CL = 0;
    CC = 0;
    WANT = 0;
    TOP = 0;
    HCOL = 0;
    clamp_cursor(false);
    scroll_fix();
    ok
};

// A one-file indirection so `load` above reads as one idea.  fs.read_file
// answers str?, and a missing or unreadable file is none -- not an error and
// not a trap -- so the caller gets an empty buffer and a message.
def fs_read(p: str) -> str? { fs.read_file(p) };

// Save.  An empty path means "the file this buffer came from".  The text
// always ends with a newline, as every text file should.
def save(p: str) -> bool {
    let target = p;
    if (len(target) == 0) { target = PATH; };
    if (len(target) == 0) { return false; };
    let body = text();
    if (len(L) > 0) { body += "\n"; };
    let ok = fs.write_file(target, body);
    if (ok) {
        DIRTY = false;
        PATH = target
    };
    ok
};

def clear_dirty() -> void { DIRTY = false };

export {
    // operator and motion ids, as the mode machine speaks them
    OP_Y, OP_D, OP_C,
    M_NONE, M_H, M_J, M_K, M_L, M_W, M_B, M_E, M_ZERO, M_CARET, M_DOLLAR,
    M_GG, M_G, M_OBRACE, M_CBRACE,
    T_IW, T_AW, T_IQ, T_AQ,
    // types the mode machine names
    Pos, Span, make_span,
    // the document
    text, nbytes, nlines, line_at, replace_text, path, set_path, dirty, gutter,
    // the cursor and the viewport
    cursor_line, cursor_col, clamp_cursor, goto, viewport, textw, scroll_page,
    top, hcol, view_rows,
    // the change log
    begin_change, end_change, reset_history, undo, redo, undo_depth, redo_depth,
    undo_max,
    // the register
    reg, reg_lw, reg_set, put,
    // messages
    msg, last_msg, log,
    // text helpers
    is_word, is_ctrl, cls_of, ulen, snapb, adv, prev_start, last_start,
    first_nonspace, nchars,
    // motions
    target, goto_motion, motion_id,
    // spans and operators
    op_range, textobj_range, apply_span, op_linewise,
    // single-key operations
    delete_chars, backspace_char, backspace_insert, tilde_case, join_down,
    split_at, open_line, insert_str, insert_byte, delete_span, delete_lines,
    // substitute and search
    substitute_line, set_search, search_pat, next_match,
    // files
    load, save
};