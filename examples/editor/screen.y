// screen.y -- the painter: a zero-allocation cell grid, an ANSI emitter that
// writes the whole frame with one write(2), and a plain-text emitter for the
// `--no-tty` dump.
//
// ===========================================================================
// WHY A CELL GRID AND TWO EMITTERS
//
// The ANSI stream and the `--no-tty` dump have to agree about what is on the
// screen, or the golden file checks a rendering nobody ever sees.  So both are
// emitted from the SAME grid: build_grid() fills a cell array once, and
// emit_ansi() / emit_plain() walk it.  There is no second copy of the layout
// logic to drift.
//
// ===========================================================================
// ZERO ALLOCATION PER REDRAW -- the discipline, and why
//
// The heap is an arena and nothing is ever freed (ORCHESTRATOR.md 2.7), so
// every byte a redraw allocates is a byte lost for the life of the process.
// Nothing in build_grid() or in either emitter allocates:
//
//   * CH / AT / OUT / PBUF / SBUF are module-level FIXED [byte; N].  A local
//     `let b: [byte; 64] = [0; 64];` inside a function costs a 64-byte heap
//     block on EVERY call (SUGGESTIONS.md item 7, measured at 64 B per array
//     literal per iteration) -- 768 bytes a redraw at 80x24, which is a slow
//     death under the campaign's 3.5 GiB cap rather than an obvious one.
//   * Numbers are rendered by num_to() into a module-level NBUF and copied, not
//     by tostring(), which allocates.
//   * String bytes are copied with byte_at(s, i), documented as no-copy, rather
//     than through s[i:] -- a slice of a str may build a new string, and a
//     status line is built on every single frame.
//   * The status line is assembled in one module-level SBUF with byte-at-a-time
//     appends, so there is no `str` concatenation in the frame path.
//
// `./editor --bench` measures the result with heap_used() either side of 2000
// redraws; the README carries the number.
//
// ===========================================================================
// WHY winsize() IS WRITTEN HERE AND term.size() IS NOT CALLED
//
// term.size() builds a FRESH {rows, cols} record on every call -- about 40
// bytes, measured by heap_used().  An editor calls the window-size query once
// per redraw to notice a resize, which makes it a 40-byte-per-frame leak with
// nothing printed anywhere.  winsize() below does the TIOCGWINSZ ioctl into a
// module-level [byte; 8] and assigns two module-level longs, so it costs zero
// allocations however often it runs.  term.y stays vendored byte-identical and
// term.size() is simply not on this path -- see README.md.

import buf;
import modes;
import term;

// ---- the grid ------------------------------------------------------------
// The stride is MAXC, not the live width, so a resize changes which cells are
// read without moving anything.
const MAXR = 60;
const MAXC = 200;
const NCELLS = MAXR * MAXC;

// ONE CELL IS ONE SCREEN COLUMN, and the glyph in it may be up to four bytes.
// Four parallel byte planes plus a length is what makes that true: the first
// version stored one byte per cell and let a multi-byte character borrow the
// cells after it, which made a two-byte character two columns wide and pushed
// everything to its right one column along.  check.y's (f) caught it.
let C0: [byte; 12000] = [0; 12000];
let C1: [byte; 12000] = [0; 12000];
let C2: [byte; 12000] = [0; 12000];
let C3: [byte; 12000] = [0; 12000];
let AT: [byte; 12000] = [0; 12000];      // its attribute
let GL: [byte; 12000] = [0; 12000];      // 1..4 bytes
let ROWS = 24;
let COLS = 80;

// ---- attributes ----------------------------------------------------------
const A_TEXT = 0;      // ordinary text
const A_CUR = 1;       // the cursor's cell, drawn in reverse video
const A_EOF = 2;       // the ~ filler past the end of the buffer
const A_GUT = 3;       // the line-number gutter
const A_STAT = 4;      // the status line
const A_STATB = 5;     // the status line while INSERT or VISUAL is live

// ---- scratch, all module level and all fixed ---------------------------
const OUT_MAX = 262144;
let OUT: [byte; 262144] = [0; 262144];
let OUTLEN = 0;
let PBUF: [byte; 12000] = [0; 12000];
let PLEN = 0;
let RS: [long; 61] = [0; 61];          // where each plain row starts
let RE: [long; 61] = [0; 61];          // and how long it is
const NBUF_MAX = 24;
let NBUF: [byte; 24] = [0; 24];
const SBUF_MAX = 320;
let SBUF: [byte; 320] = [0; 320];
let SLEN = 0;
let WS: [byte; 8] = [0; 8];

def rows() -> long { ROWS };
def cols() -> long { COLS };

// ===========================================================================
// the window size
// ===========================================================================

// TIOCGWINSZ (0x5413) fills WS with {ws_row, ws_col, ws_xpixel, ws_ypixel} as
// four 16-bit little-endian values, ROW FIRST.  Clamped to the grid's shape and
// to a floor that keeps one text row plus the status row -- a pty from
// pty.fork() with nobody having set TIOCSWINSZ reports 0x0, and a zero row
// would otherwise divide by nothing in the first frame.  Returns 0 on success.
def winsize() -> long {
    let i = 0;
    while (i < 8) { WS[i] = 0; i = i + 1 };
    let ok = syscall(16, 1, 0x5413, &WS[0]) >= 0;
    let r = 24;
    let c = 80;
    if (ok) {
        let b0: long = WS[0];
        let b1: long = WS[1];
        let b2: long = WS[2];
        let b3: long = WS[3];
        r = b0 | (b1 << 8);
        c = b2 | (b3 << 8)
    };
    if (r < 3) { r = 3 };
    if (c < 20) { c = 20 };
    if (r > MAXR) { r = MAXR };
    if (c > MAXC) { c = MAXC };
    ROWS = r;
    COLS = c;
    if (ok) { 0 } else { 0 - 1 }
};

// ===========================================================================
// byte helpers -- no allocation, no tostring, no slices
// ===========================================================================

// Decimal digits of a non-negative v, into NBUF, least significant first then
// reversed in place.  Returns the length.  This is the whole reason the frame
// path never calls tostring().
def num_to(v: long) -> long {
    let n = v;
    if (n < 0) { n = 0 };
    let k = 0;
    let more = true;
    while (more && k < NBUF_MAX) {
        NBUF[k] = 48 + n % 10;
        k = k + 1;
        n = n / 10;
        more = n > 0
    };
    let i = 0;
    let j = k - 1;
    while (i < j) {
        let t: long = NBUF[i];
        NBUF[i] = NBUF[j];
        NBUF[j] = t;
        i = i + 1;
        j = j - 1
    };
    k
};

def digits_of(v: long) -> long {
    let n = v;
    if (n < 1) { return 1 };
    let k = 0;
    while (n > 0 && k < 18) { k = k + 1; n = n / 10 };
    k
};

def ob(b: long) -> void {
    if (OUTLEN < OUT_MAX) {
        OUT[OUTLEN] = b & 255;
        OUTLEN = OUTLEN + 1
    }
};

def ob_num(v: long) -> void {
    let k = num_to(v);
    let i = 0;
    while (i < k) { ob(NBUF[i]); i = i + 1 }
};

// ESC [ n ; m H -- move to a 1-based row and column.
def ob_cup(row: long, col: long) -> void {
    ob(27);
    ob(91);
    ob_num(row);
    ob(59);
    ob_num(col);
    ob(72)
};

// The SGR for an attribute.  Emitted only when the attribute CHANGES, which is
// what keeps a frame to a few hundred bytes rather than a few thousand.
def ob_attr(a: long) -> void {
    ob(27);
    ob(91);
    if (a == A_CUR) {
        ob(48); ob(59); ob(48);          // 0;7
        ob(109)
    } else if (a == A_EOF || a == A_GUT) {
        ob(48); ob(59); ob(57); ob(48); ob(59); ob(57); ob(48);  // 0;90;90
        ob(109)
    } else if (a == A_STAT) {
        ob(48); ob(59); ob(49);           // 0;1
        ob(109)
    } else if (a == A_STATB) {
        ob(48); ob(59); ob(49); ob(59); ob(55);  // 0;1;7
        ob(109)
    } else {
        ob(48);                           // 0
        ob(109)
    }
};

def sb_byte(b: long) -> void {
    if (SLEN < SBUF_MAX) {
        SBUF[SLEN] = b & 255;
        SLEN = SLEN + 1
    }
};

def sb_num(v: long) -> void {
    let k = num_to(v);
    let i = 0;
    while (i < k) { sb_byte(NBUF[i]); i = i + 1 }
};

def sb_str(s: str) -> void {
    let i = 0;
    while (i < len(s)) { sb_byte(byte_at(s, i)); i = i + 1 }
};

// ===========================================================================
// building the grid
// ===========================================================================

// One ASCII character: one cell, one byte.
def cell(r: long, c: long, b: long, a: long) -> void {
    let i = r * MAXC + c;
    if (i >= 0 && i < NCELLS) {
        C0[i] = b & 255;
        C1[i] = 0;
        C2[i] = 0;
        C3[i] = 0;
        GL[i] = 1;
        AT[i] = a
    }
};

// A whole code point in ONE cell: up to four bytes out of the line, GL saying
// how many are real.
def glyph(r: long, c: long, s: str, at: long, w: long, a: long) -> void {
    let i = r * MAXC + c;
    if (i < 0 || i >= NCELLS) { return; };
    let b0 = 0;
    let b1 = 0;
    let b2 = 0;
    let b3 = 0;
    if (w > 0 && at < len(s)) { b0 = byte_at(s, at) };
    if (w > 1 && at + 1 < len(s)) { b1 = byte_at(s, at + 1) };
    if (w > 2 && at + 2 < len(s)) { b2 = byte_at(s, at + 2) };
    if (w > 3 && at + 3 < len(s)) { b3 = byte_at(s, at + 3) };
    C0[i] = b0;
    C1[i] = b1;
    C2[i] = b2;
    C3[i] = b3;
    GL[i] = w;
    AT[i] = a
};

// Byte j of the glyph in cell i, 0 past its end.
def gbyte(i: long, j: long) -> long {
    if (j == 0) { C0[i] } else if (j == 1) { C1[i] } else if (j == 2) { C2[i] } else { C3[i] }
};

def mark_cursor(r: long, c: long) -> void {
    let i = r * MAXC + c;
    if (i >= 0 && i < NCELLS) { AT[i] = A_CUR }
};

// The status line.  Built into SBUF as
//     -- MODE -- [count] [op] ......... "path" NL, NB [+]
// with the left part's length recorded so the padding can be computed without
// a second buffer.  In COMMAND mode the whole line is the command line, which
// is what makes the mode visible as well as the typed text.
def build_status(r: long, cols0: long) -> long {
    let m = modes.mode();
    SLEN = 0;
    if (m == modes.COMMAND) {
        sb_byte(58);                              // ':'
        let i = 0;
        while (i < modes.cmd_len()) { sb_byte(modes.cmd_byte(i)); i = i + 1 };
        let l0 = SLEN;
        let c = 0;
        while (c < cols0) {
            let b = 32;
            if (c < l0) { b = SBUF[c] };
            cell(r, c, b, A_STAT);
            c = c + 1
        };
        return 0
    };
    sb_byte(45); sb_byte(45); sb_byte(32);        // "-- "
    sb_str(modes.mode_name(m));
    sb_byte(32); sb_byte(45); sb_byte(45); sb_byte(32);
    let c0 = modes.count_now();
    let op = modes.pending_op();
    if (c0 > 1 || op > 0) {
        sb_byte(40);
        if (c0 > 1) { sb_num(c0); if (op > 0) { sb_byte(32) } };
        if (op > 0) { sb_str(modes.op_char(op)) };
        sb_byte(41); sb_byte(32)
    };
    let left = SLEN;
    sb_byte(34);                                  // '"'
    sb_str(buf.path());
    sb_byte(34); sb_byte(32);
    sb_num(buf.nlines());
    sb_byte(76); sb_byte(44); sb_byte(32);        // "L, "
    sb_num(buf.nbytes());
    sb_byte(66);                                  // 'B'
    if (buf.dirty()) { sb_str(" [+]") };
    let total = SLEN;
    let pad = cols0 - total;
    // If the right part does not fit, drop it rather than wrapping into the
    // next line: a status line that wraps is worse than one that is short.
    let start = left;
    if (pad < 0) { start = cols0; total = 0 };
    let a = A_STAT;
    if (m == modes.INSERT || m == modes.VISUAL) { a = A_STATB };
    let c = 0;
    while (c < cols0 && c < left) { cell(r, c, SBUF[c], a); c = c + 1 };
    while (c < start) { cell(r, c, 32, a); c = c + 1 };
    let i = start;
    while (i < total && c < cols0) { cell(r, c, SBUF[i], a); c = c + 1; i = i + 1 };
    while (c < cols0) { cell(r, c, 32, a); c = c + 1 };
    0
};

// One text row.  The cursor's cell is marked afterwards rather than inline, so
// the reverse-video attribute cannot be lost to a later plain cell.
def build_row(r: long, bi: long, cols0: long) -> void {
    let g = buf.gutter();
    let c = 0;
    if (g > 0) {
        let k = num_to(bi + 1);
        let pad = (g - 1) - k;
        let j = 0;
        while (j < pad) { cell(r, c, 32, A_GUT); c = c + 1; j = j + 1 };
        let m = 0;
        while (m < k) { cell(r, c, NBUF[m], A_GUT); c = c + 1; m = m + 1 };
        cell(r, c, 32, A_GUT);
        c = c + 1
    };
    if (bi >= buf.nlines()) {
        if (c < cols0) { cell(r, c, 126, A_EOF); c = c + 1 };
        while (c < cols0) { cell(r, c, 32, A_EOF); c = c + 1 };
        return
    };
    let s = buf.line_at(bi);
    let i = buf.hcol();
    while (c < cols0) {
        if (i >= len(s)) {
            cell(r, c, 32, A_TEXT);
            c = c + 1
        } else {
            let b = byte_at(s, i);
            if (buf.is_ctrl(b)) {
                // ^X notation for a control byte, in two cells -- what vi does,
                // and it keeps a tab or a CR from moving the cursor around the
                // screen behind the editor's back.
                cell(r, c, 94, A_TEXT);
                c = c + 1;
                if (c < cols0) {
                    let show = 0;
                    if (b == 127) { show = 63 } else { show = b + 64 };
                    cell(r, c, show, A_TEXT);
                    c = c + 1
                };
                i = i + 1
            } else {
                // A code point is ONE screen column wide however many bytes it
                // is: glyph() writes the bytes into consecutive cells and marks
                // them as one glyph, so the emitters step over the whole thing
                // and nothing to its right moves.
                glyph(r, c, s, i, buf.ulen(b), A_TEXT);
                c = c + 1;
                i = i + buf.ulen(b)
            }
        }
    };
    let sc = buf.nchars(s, buf.hcol(), buf.cursor_col()) + g;
    if (bi == buf.cursor_line() && sc >= 0 && sc < cols0) { mark_cursor(r, sc) }
};

// Fill the whole grid for a `rows` x `cols` screen.  buf.viewport() is called
// first so the gutter width and the scroll offsets are settled before a single
// cell is placed -- which is why the redraw can never paint a cursor it does not
// have.
def build_grid(rows0: long, cols0: long) -> void {
    let rows = rows0;
    let cols = cols0;
    if (rows < 2) { rows = 2 };
    if (rows > MAXR) { rows = MAXR };
    if (cols < 1) { cols = 1 };
    if (cols > MAXC) { cols = MAXC };
    let trows = rows - 1;
    buf.viewport(trows, cols);
    ROWS = rows;
    COLS = cols;
    let top = buf.top();
    let r = 0;
    while (r < rows) {
        if (r < trows) {
            build_row(r, top + r, cols)
        } else {
            build_status(r, cols)
        };
        r = r + 1
    }
};

// ===========================================================================
// the two emitters
// ===========================================================================

// The ANSI stream: one CUP per row, an SGR only where the attribute changes, and
// the hardware cursor parked on the cell the grid marked.  Every row is filled
// to the full width, so no stale character from the previous frame can survive
// behind a shorter line.
def emit_ansi(rows0: long, cols0: long) -> long {
    let rows = rows0;
    let cols = cols0;
    OUTLEN = 0;
    let cur = 0 - 1;
    let r = 0;
    while (r < rows) {
        ob_cup(r + 1, 1);
        let base = r * MAXC;
        let c = 0;
        while (c < cols) {
            let a = AT[base + c];
            if (a != cur) {
                ob_attr(a);
                cur = a
            };
            let w = GL[base + c];
            let j = 0;
            while (j < w) { ob(gbyte(base + c, j)); j = j + 1 };
            c = c + 1
        };
        r = r + 1
    };
    // Park the real cursor where the grid says the cell is, so a terminal that
    // shows the hardware cursor puts it in the right place even though the
    // cursor cell is also drawn in reverse video.
    let cr = buf.cursor_line() - buf.top();
    if (cr < 0) { cr = 0 };
    if (cr > rows - 2) { cr = rows - 2 };
    let cc = buf.nchars(buf.line_at(buf.cursor_line()), buf.hcol(), buf.cursor_col()) + buf.gutter() + 1;
    if (cc < 1) { cc = 1 };
    if (cc > cols) { cc = cols };
    ob(27); ob(91); ob(63); ob(50); ob(53); ob(104);   // ESC [ ? 2 5 h -- show it
    ob_attr(A_CUR);
    ob_cup(cr + 1, cc);
    OUTLEN
};

// Plain text: exactly the characters on the screen, no escapes, no separator
// between rows.  The dumper walks it row by row.  This and emit_ansi() read the
// same grid, which is what makes `diff EXPECTED` a check on the rendering and
// not just on one of two renderings.
// Plain text: exactly the glyphs on each row, in order, with no escapes and no
// fixed stride -- a multi-byte character contributes several bytes, so a row is
// `cols` bytes only when the text is ASCII.  The dumper pads each row out to
// `cols` when it draws the box, which is exact for ASCII and honest for the rest.
// Row r's bytes are at plain_row_start(r) .. + plain_row_len(r).
def emit_plain(rows0: long, cols0: long) -> long {
    let rows = rows0;
    let cols = cols0;
    PLEN = 0;
    let r = 0;
    while (r < rows) {
        RS[r] = PLEN;
        let base = r * MAXC;
        let c = 0;
        while (c < cols) {
            let w = GL[base + c];
            let j = 0;
            while (j < w) {
                if (PLEN < 12000) {
                    PBUF[PLEN] = gbyte(base + c, j);
                    PLEN = PLEN + 1
                };
                j = j + 1
            };
            c = c + 1
        };
        RE[r] = PLEN - RS[r];
        r = r + 1
    };
    PLEN
};

def plain_row_start(r: long) -> long { if (r >= 0 && r < 61) { RS[r] } else { 0 } };
def plain_row_len(r: long) -> long { if (r >= 0 && r < 61) { RE[r] } else { 0 } };

// The attribute of one cell, for the property checks to assert which cell the
// cursor actually landed on.  0xFFFFFFFF-free: out of range is -1.
def cell_attr(r: long, c: long) -> long {
    let i = r * MAXC + c;
    if (i >= 0 && i < NCELLS) { let v: long = AT[i]; v } else { 0 - 1 }
};

def plain_at(i: long) -> long {
    if (i >= 0 && i < PLEN) { let v: long = PBUF[i]; v } else { 32 }
};
def plain_len() -> long { PLEN };

// ===========================================================================
// the frame
// ===========================================================================

// Build and write one frame with ONE write(2).  Returns the byte count.
def render(rows: long, cols: long) -> long {
    build_grid(rows, cols);
    emit_ansi(rows, cols);
    if (OUTLEN > 0) { syscall(1, 1, &OUT[0], OUTLEN); };
    OUTLEN
};

// Build the frame but do not write it -- for --bench, which measures the cost of
// building rather than of the terminal.
def render_capture(rows: long, cols: long) -> long {
    build_grid(rows, cols);
    emit_ansi(rows, cols)
};

def last_frame_len() -> long { OUTLEN };

export {
    MAXR, MAXC, A_CUR,
    winsize, rows, cols, render, render_capture, emit_plain, plain_at,
    plain_len, plain_row_start, plain_row_len, digits_of, build_grid, cell_attr
};