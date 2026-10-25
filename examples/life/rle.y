// rle.y -- a parser for the Run-Length Encoded pattern format.
//
// ===========================================================================
// WHAT RLE IS
//
// The format Conway patterns travel in.  A pattern is a run of counts and
// run characters:
//
//     bo$2bo$3o!            <- b = dead, o = live, $ = end of row, ! = end
//     x = 3, y = 3, bo$2bo$3o!
//
// `bo2bo` means: dead, live, live, live, dead, live -- the number in front
// multiplies whatever character follows it.  `$` moves to the start of the
// next row (it also implies "the rest of this row is dead"), and `!` ends the
// pattern.  A leading `x = W, y = H,` header is optional and, as here, only
// checked for shape: the grid it is placed on comes from --size.
//
// ===========================================================================
// WHY THIS PARSER RETURNS A RESULT INSTEAD OF EXITING
//
// A parser that can fail has two ways to say so, and this program needs the
// one that cannot take the terminal down with it: `life.y` prints the message
// and exits 1.  So every failure here comes back as `{ ok: false, msg }` and
// nothing is written into a grid on the way out.  Requirement: no input, not
// even `99999999999999999999o`, may produce a trap.
//
// The two traps this format invites, and what happens instead:
//
//   * a run count with no upper bound.  Counts are accumulated and checked
//     against MAXRUN *before* they are used to place anything, so
//     `99999999999o` is a diagnostic, not an index far off the end of the
//     grid.  The accumulation itself cannot overflow: it stops growing the
//     moment it passes MAXRUN, so the largest value it ever holds is
//     MAXRUN * 10 + 9.
//   * a run that walks off the right edge of a row, or off the bottom.
//     Cells are collected as (x, y) pairs and bounds-checked by the caller
//     (sim.place_cell), which reports the offending coordinate.
//
// Whitespace anywhere is skipped, because real RLE files are wrapped across
// lines.  Anything after the closing `!` other than whitespace is an error --
// being strict here is what makes "--rle 'bo$2bo!garbage'" a diagnostic
// rather than a silent truncation.

// The cell list is a growable array of records, so a Cell type alias is
// required: writing the shape out twice warns ("the type { ... } is written
// out N times; name it with `type`").
type Cell = { x: long, y: long };

// What parse() answers.  w and h are the header's claims, or 0 when the
// header did not carry them; cells is the pattern, in order.
type Rle = {
    ok: bool,
    msg: str,
    w: long,
    h: long,
    cells: [Cell]
};

// Any run longer than this cannot fit in the largest grid, so it is rejected
// before it is used.  262144 is sim.MAXCELLS.
const MAXRUN = 262144;

def blank() -> Rle {
    let r: Rle = { ok: false, msg: "", w: 0, h: 0, cells: [] };
    r
};

// A byte is one of RLE's whitespace characters.
def ws(c: long) -> bool {
    c == 32 || c == 9 || c == 10 || c == 13
};

def is_digit(c: long) -> bool { c >= 48 && c <= 57 };

def is_alpha(c: long) -> bool {
    (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
};

// at(s, i) -- byte i of s, or -1 past the end.  -1 cannot be a real byte
// value, so every loop below can use it as "no more input" without a second
// bound test.
def at(s: str, i: long) -> long {
    if (i < 0 || i >= len(s)) { return 0 - 1; };
    s[i]
};

// parse(src) -> Rle -- the whole format.  `src` is the --rle argument.
def parse(src: str) -> Rle {
    let n = len(src);
    let cells: [Cell] = [];
    let rw = 0;
    let rh = 0;
    let i = 0;

    if (n == 0) {
        let e = blank();
        e.msg = "the RLE string is empty";
        return e
    };

    // ── the optional `x = W, y = H, rule = ...` header ────────────────────
    // A header key is a letter (or a word for `rule`) followed by `=`.  The
    // width and height are read and reported; `rule` is skipped by name,
    // because B3/S23 is the only rule this program implements and accepting
    // `rule = B3/S23` while ignoring `rule = B36/S23` silently would be a lie
    // -- so a rule that is not B3/S23 is refused below.
    let go = true;
    while (go) {
        // skip whitespace
        while (i < n && ws(at(src, i))) { i = i + 1; };
        if (i >= n) { go = false; } else {
            // A header key is a letter run FOLLOWED BY `=`.  That test has to
            // look ahead, because the pattern data can start with a letter
            // too -- `bo$2bo!` begins with `b`, which is a run character and
            // not the key `b`.  Anything that is not `letters =` is data.
            let k0 = i;
            let j = i;
            while (j < n && is_alpha(at(src, j))) { j = j + 1; };
            let m = j;
            while (m < n && ws(at(src, m))) { m = m + 1; };
            if (j == k0 || at(src, m) != 61) {
                go = false
            } else {
                let key = src[k0:j].lower();
                i = m + 1;
                while (i < n && ws(at(src, i))) { i = i + 1; };
                // `x` and `y` are read; `rule` is checked, because running
                // B3/S23 on a pattern that asks for B36/S23 would be a lie;
                // every other key (`name`, `author`, ...) is skipped and
                // ignored, which is what a pattern file expects.
                if (key == "x" || key == "y") {
                    let d0 = i;
                    while (i < n && is_digit(at(src, i))) { i = i + 1; };
                    if (i == d0) {
                        let e = blank();
                        e.msg = "the header key '" + key + "' wants a number";
                        return e
                    };
                    let v = tolong(src[d0:i])!;
                    if (key == "x") { rw = v; };
                    if (key == "y") { rh = v; }
                } else if (key == "rule") {
                    // A rule never contains a space, so it is one token: stop
                    // at the comma, the whitespace or the end.
                    let r0 = i;
                    while (i < n && at(src, i) != 44 && !ws(at(src, i))) { i = i + 1; };
                    let rule = src[r0:i];
                    if (rule != "B3/S23") {
                        let e = blank();
                        e.msg = "unsupported rule '" + rule + "': life.y implements Conway's B3/S23";
                        return e
                    }
                } else {
                    // name = Gosper glider gun, author = ..., so to the comma.
                    while (i < n && at(src, i) != 44) { i = i + 1; }
                };
                while (i < n && ws(at(src, i))) { i = i + 1; };
                if (at(src, i) == 44) { i = i + 1; }   // ',' separates keys
            }
        }
    };

    // ── the runs ─────────────────────────────────────────────────────────
    let x = 0;
    let y = 0;
    let done = false;
    while (!done && i < n) {
        let c = at(src, i);
        if (ws(c)) {
            i = i + 1
        } else {
            // An optional count, then exactly one run character.
            let cnt = 1;
            if (is_digit(c)) {
                cnt = 0;
                while (i < n && is_digit(at(src, i))) {
                    cnt = cnt * 10 + (at(src, i) - 48);
                    i = i + 1;
                    // Stop growing the moment it is too big: this is what
                    // keeps `999999999999999999999o` from overflowing a long
                    // and then from indexing somewhere impossible.
                    if (cnt > MAXRUN) {
                        let e = blank();
                        e.msg = "a run count over " + tostring(MAXRUN) + " cells";
                        return e
                    }
                }
            };
            let ch = at(src, i);
            if (ch == 33) {                 // '!'
                done = true;
                i = i + 1
            } else if (ch == 36) {          // '$' end of row
                x = 0;
                y = y + 1;
                i = i + 1
            } else if (ch == 98 || ch == 111) {   // 'b' dead, 'o' alive
                if (ch == 111) {
                    let k = 0;
                    while (k < cnt) {
                        let cell: Cell = { x: x, y: y };
                        cells += cell;
                        k = k + 1;
                        x = x + 1
                    }
                } else {
                    x = x + cnt
                };
                i = i + 1
            } else {
                let e = blank();
                let got = "end of string";
                if (ch >= 32 && ch < 127) { got = "'" + chr(ch) + "'"; };
                e.msg = "expected 'b', 'o', '$' or '!' at offset "
                      + tostring(i) + ", got " + got;
                return e
            }
        }
    };

    if (!done) {
        let e = blank();
        e.msg = "the RLE string ends without a '!' terminator";
        return e
    };
    // Only whitespace may follow the '!'.  Real files put comments there and
    // this parser refuses them, which is deliberate: a strict reader reports
    // a mistyped pattern instead of quietly dropping half of it.
    while (i < n && ws(at(src, i))) { i = i + 1; };
    if (i < n) {
        let e = blank();
        e.msg = "unexpected text after '!' at offset " + tostring(i);
        return e
    };
    if (len(cells) == 0) {
        let e = blank();
        e.msg = "the RLE string has no live cells";
        return e
    };

    let out: Rle = { ok: true, msg: "", w: rw, h: rh, cells: cells };
    out
};

// extent(r) -> str -- "W x H" for the summary, or "unheadered" when the
// string carried no x/y header.
def extent(r: Rle) -> str {
    if (r.w <= 0 || r.h <= 0) { return "unheadered"; };
    tostring(r.w) + " x " + tostring(r.h)
};

export { Cell, Rle, MAXRUN, parse, extent };
