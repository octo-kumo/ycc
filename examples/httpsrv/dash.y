// dash.y -- the dashboard: turns one Stats record into a frame of bytes.
//
//   import dash;
//
//   let n = dash.render(st, true);       // plain text into dash.out
//   syscall(1, 1, &dash.out[0], n);      // or dash.paint(st, false) live
//
// The frame goes into a module-level buffer and the caller writes it, so
// drawing a frame costs **zero bytes of heap**: there is no string to
// build, no f-string to format, no record to make. That matters because
// the heap is an arena with no free (ORCHESTRATOR.md 2.7) and this is a
// frame loop -- a bar chart rebuilt with `+=` each tick leaks 64 bytes a
// bar. `plain` gives the transcript (no escapes, byte-diffable); false
// gives the terminal its SGR.
//
// ── its own window size, not term.size() ──────────────────────────────
//
// `term.size()` answers a **fresh record** every call (~40 bytes), so
// polling it once a frame leaks 40 bytes a frame. winsize() below does the
// TIOCGWINSZ ioctl into one module-level buffer and leaves rows/cols in
// module globals: the same answer for free. (The ioctl is
// syscall(16, fd, REQUEST, arg) -- kernel register order, so the request
// is the *third* argument; see ORCHESTRATOR.md 2.1.)

const TIOCGWINSZ = 0x5413;
const WIDTH = 78;           // the frame is WIDTH + 2 bytes wide
const ROWS = 8;             // bar rows; plus one axis row
const OUTSZ = 8192;
const RAMP = " .:-=+*#%@";  // the sparkline's ten levels

// ── the data ───────────────────────────────────────────────────────────

type Stats = {
    served: long, ticks: long, arrived: long, rate: long, avg: long,
    peak: long, trough: long, errors: long, bytes: long, up_ms: long,
    nwin: long, win: [long; 32], label: str, source: str
};

let out: [byte; 8192] = [0; 8192];
let out_len = 0;
let prev: [byte; 8192] = [0; 8192];
let prev_len = 0;
let painted = false;
let colour = false;

let ws: [byte; 64] = [0; 64];
let rows = 24;
let cols = 80;
let sb: [byte; 24] = [0; 24];
let esc_len = 0;
let line_at = 0;

// The cursor escape for a repainted row is built at ESC_AT, past the end
// of any frame: 21 rows of 81 bytes is 1701, so 4096 is unreachable and
// one write_all() serves both. (A second buffer would have to be another
// exact fixed size, and Y has no generics to share the writer with.)
const ESC_AT = 4096;

// ── writing ────────────────────────────────────────────────────────────

def s(p: long, t: str) -> long {
    let n0 = len(t);
    let i = 0;
    while (i < n0) { out[p + i] = t[i]; i = i + 1; };
    p + n0
};

def n(p: long, v: long) -> long {
    let k = 0;
    let x = v;
    let neg = x < 0;
    if (neg) { x = 0 - x; };
    if (x == 0) { sb[0] = 48; k = 1; };
    while (x > 0) {
        sb[k] = 48 + (x % 10);
        k = k + 1;
        x = x / 10;
    };
    if (neg) { out[p] = 45; p = p + 1; };
    let i = 0;
    while (i < k) { out[p + i] = sb[k - 1 - i]; i = i + 1; };
    p + k
};

// v right-aligned in w0 columns
def rpad(p: long, v: long, w0: long) -> long {
    let d = 0;
    let x = v;
    if (x < 0) { x = 0 - x; d = 1; };
    if (x == 0) { d = d + 1; };
    while (x > 0) { d = d + 1; x = x / 10; };
    let pad = w0 - d;
    let i = 0;
    while (i < pad) { out[p] = 32; p = p + 1; i = i + 1; };
    n(p, v)
};

// NB: index by p + i and advance i only. Advancing p as well writes every
// other byte one further along and leaves NULs in between -- which is what
// the first version of this did, and what the border of the first frame
// looked like.
def rep(p: long, c: long, k: long) -> long {
    let i = 0;
    while (i < k) { out[p + i] = c; i = i + 1; };
    p + k
};

// "\x1b[<code>m", and nothing at all in plain mode
def sgr(p: long, code: long) -> long {
    if (!colour) { return p; };
    p = s(p, "\x1b[");
    p = n(p, code);
    p = s(p, "m");
    p
};

def reset(p: long) -> long {
    sgr(p, 0)
};

// open a "|...|" line: ol() remembers where the bar went, cl() uses it, so
// the padding cannot come out one byte wrong.
def ol(p: long) -> long {
    line_at = p;
    s(p, "|")
};

def cl(p: long) -> long {
    // pad to the border's width. A negative pad means the content was
    // wider than WIDTH: leave the line alone rather than write a negative
    // number of spaces (rep() would take p backwards).
    let pad = WIDTH - (p - line_at - 1);
    if (pad > 0) { p = rep(p, 32, pad); };
    s(p, "|\n")
};

def rule(p: long) -> long {
    p = s(p, "+");
    p = sgr(p, 34);
    p = rep(p, 45, WIDTH);
    p = reset(p);
    p = s(p, "+\n");
    p
};

// "  label 123 unit", the number in its own colour
def field(p: long, label: str, v: long, unit: str, w0: long) -> long {
    p = s(p, "  ");
    p = s(p, label);
    p = s(p, " ");
    p = sgr(p, 36);
    p = rpad(p, v, w0);
    p = reset(p);
    p = s(p, unit);
    p
};

// ── the window size ────────────────────────────────────────────────────

def rd16(at0: long) -> long {
    ws[at0] + ws[at0 + 1] * 256
};

// the terminal's size, into the module globals rows/cols. No record, no
// allocation, and no fresh buffer either -- one ws, reused for ever.
def winsize() {
    ws[0] = 0;
    ws[1] = 0;
    ws[2] = 0;
    ws[3] = 0;
    if (syscall(16, 1, TIOCGWINSZ, &ws[0]) >= 0) {
        rows = rd16(0);
        cols = rd16(2);
    };
    // a zero would divide by zero in the first bar that computes a scale,
    // and is also what a pty nobody sized looks like
    if (rows < 1) { rows = 24; };
    if (cols < 1) { cols = 80; };
    if (rows > 1000) { rows = 1000; };
    if (cols > 1000) { cols = 1000; };
};

// ── the frame ──────────────────────────────────────────────────────────

// one bar-chart row: the value at its top on the left, one column per
// sample. Row ROWS is the axis.
def bar_row(p: long, st: Stats, row: long, hi: long) -> long {
    p = ol(p);
    if (row == ROWS) {
        p = s(p, "    0 ");
        p = sgr(p, 34);
        p = s(p, "+");
        p = rep(p, 45, 32 + 8);
        p = reset(p);
    } else {
        p = rpad(p, hi * (ROWS - 1 - row) / (ROWS - 1), 4);
        p = s(p, " |");
        let i = 0;
        while (i < st.nwin) {
            let h = st.win[i] * ROWS / hi;
            if (h >= ROWS - row) {
                p = sgr(p, 33);
                p = s(p, "#");
                p = reset(p);
            } else {
                p = s(p, " ");
            };
            i = i + 1;
        };
    };
    cl(p)
};

// the ten-level ramp over the same samples, on one line: exactly one glyph
// per sample, 32 columns. (An earlier version padded each sample with `lvl`
// dots as well, which made the line 300-odd bytes wide -- cl() then
// truncated it and the peak/trough labels never reached the screen.)
def spark(p: long, st: Stats) -> long {
    p = ol(p);
    p = s(p, "  spark ");
    let hi = st.peak;
    let j = 0;
    while (j < st.nwin) {
        let lvl = 0;
        if (hi > 0) { lvl = st.win[j] * 9 / hi; };
        // clamped at BOTH ends: RAMP[lvl] is an index, and a negative
        // sample (a hand-built Stats record, say) would be an index out of
        // bounds -- a trap, which lands on stdout in the middle of a frame
        if (lvl > 9) { lvl = 9; };
        if (lvl < 0) { lvl = 0; };
        // RAMP[lvl] is a **byte** (a str index gives one), and `str + byte`
        // segfaults, so the glyph goes into the frame straight from the
        // byte -- no chr(), which would allocate a string per level.
        out[p] = RAMP[lvl];
        p = p + 1;
        j = j + 1;
    };
    p = s(p, "| ");
    p = s(p, "peak ");
    p = sgr(p, 36);
    p = n(p, st.peak);
    p = reset(p);
    p = s(p, "  trough ");
    p = sgr(p, 36);
    p = n(p, st.trough);
    p = reset(p);
    p = s(p, "  n ");
    p = n(p, st.nwin);
    cl(p)
};

// render(st, plain) -> the frame's length; the bytes are in dash.out.
def render(st: Stats, plain: bool) -> long {
    colour = !plain;
    let p = 0;
    p = rule(p);
    p = ol(p);
    p = s(p, "  httpsrv  ");
    p = sgr(p, 36);
    p = s(p, st.label);
    p = reset(p);
    p = s(p, "   ");
    p = s(p, st.source);
    p = s(p, "   frame ");
    p = n(p, st.ticks);
    p = cl(p);
    p = rule(p);

    // two rows of tiles
    p = ol(p);
    p = field(p, "served", st.served, "", 8);
    p = field(p, "rate", st.rate, "/s", 7);
    p = field(p, "avg", st.avg, "/s", 7);
    p = field(p, "peak", st.peak, "/s", 7);
    p = cl(p);
    p = ol(p);
    p = field(p, "arrived", st.arrived, "", 8);
    p = field(p, "trough", st.trough, "/s", 7);
    p = field(p, "errors", st.errors, "", 7);
    p = field(p, "bytes", st.bytes, "", 7);
    p = cl(p);
    p = ol(p);
    p = s(p, "  uptime ");
    p = sgr(p, 36);
    p = rpad(p, st.up_ms, 8);
    p = reset(p);
    p = s(p, " ms");
    p = cl(p);
    p = rule(p);

    // the chart
    p = ol(p);
    p = s(p, "  rate, the last ");
    p = n(p, st.nwin);
    p = s(p, " samples, one every 10 ms");
    p = cl(p);
    let hi = ((st.peak + 99) / 100) * 100;
    if (hi < 1000) { hi = 1000; };
    let r = 0;
    while (r <= ROWS) {
        p = bar_row(p, st, r, hi);
        r = r + 1;
    };
    p = ol(p);
    p = s(p, "        oldest");
    p = rep(p, 32, WIDTH - 6 - (p - line_at - 1));
    p = s(p, "newest");
    p = cl(p);
    p = rule(p);
    p = spark(p, st);
    p = rule(p);
    out_len = p;
    p
};

// ── putting it on the screen ───────────────────────────────────────────

def write_all(b: [byte; 8192], off: long, k: long) {
    let left = off;
    while (left < off + k) {
        let w = syscall(1, 1, &b[left], off + k - left);
        if (w <= 0) { left = off + k; } else { left = left + w; };
    };
};

// the offset row r starts at in a frame of k bytes (0-based)
def rowspan(b: [byte; 8192], k: long, r: long) -> long {
    let i = 0;
    let row = 0;
    let at0 = 0;
    while (i < k && row < r) {
        if (b[i] == 10) {
            at0 = i + 1;
            row = row + 1;
        };
        i = i + 1;
    };
    at0
};

def rowend(b: [byte; 8192], k: long, a0: long) -> long {
    let e = a0;
    while (e < k && b[e] != 10) { e = e + 1; };
    e
};

// does row r differ from row r of the last frame painted?
def row_changed(a: [byte; 8192], ak: long, b: [byte; 8192], bk: long, r: long) -> bool {
    let s0 = rowspan(a, ak, r);
    let s1 = rowspan(b, bk, r);
    let e0 = rowend(a, ak, s0);
    let e1 = rowend(b, bk, s1);
    if (e0 - s0 != e1 - s1) { return true; };
    let i = 0;
    let same = true;
    while (i < e0 - s0) {
        if (a[s0 + i] != b[s1 + i]) { same = false; };
        i = i + 1;
    };
    !same
};

// paint(st, plain) -> bytes written: the whole frame the first time, then
// only the rows that changed. Repainting a full 78-column frame at 10 fps
// flickers; repainting four rows does not.
def paint(st: Stats, plain: bool) -> long {
    let k = render(st, plain);
    let wrote = 0;
    if (!painted) {
        write_all(out, 0, k);
        wrote = k;
    } else {
        let rowsn = 0;
        let i = 0;
        while (i < k) {
            if (out[i] == 10) { rowsn = rowsn + 1; };
            i = i + 1;
        };
        let r = 0;
        while (r < rowsn) {
            if (row_changed(out, k, prev, prev_len, r)) {
                // ESC [ row ; 1 H, into its own buffer -- poking it into
                // the row itself would eat the '|' the row starts with
                esc_len = s(ESC_AT, "\x1b[");
                esc_len = n(esc_len, r + 1);
                esc_len = s(esc_len, ";1H");
                write_all(out, ESC_AT, esc_len - ESC_AT);
                let s0 = rowspan(out, k, r);
                let e0 = rowend(out, k, s0);
                write_all(out, s0, e0 - s0);
                wrote = wrote + esc_len + (e0 - s0);
            };
            r = r + 1;
        };
    };
    // remember this frame, so the next one can diff against it
    let j = 0;
    while (j < k) { prev[j] = out[j]; j = j + 1; };
    prev_len = k;
    painted = true;
    wrote
};

export { TIOCGWINSZ, WIDTH, ROWS, RAMP, Stats, out, out_len, rows, cols, render, paint, winsize };