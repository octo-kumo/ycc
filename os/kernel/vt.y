// vt -- the text terminal on the display: a cell grid, an xterm-style parser, a renderer.
//
// The tty writes every output byte to `vt_putc` (through console.y). The bytes are UTF-8
// text and escape sequences (the C0 controls, CSI cursor movement, erase, insert/delete,
// scroll regions, SGR with the 16 colours, the 256-colour cube and 24-bit colour, the
// alternate screen, DSR/DA replies, DEC line drawing) -- what `tui.y`, the shell and the
// usual curses programs emit under TERM=xterm-256color.
//
// The grid is the truth: `vt_putc` changes cells and marks their rows dirty, nothing
// more, so a flood of output costs one redraw a frame, not one per byte. `vt_flush`
// renders the dirty rows into the display's VT buffer and shows them (fb.y); it runs
// when a frame is due (about every 16 ms: `vt_tick` counts, boot.y's clock handler calls
// `vt_flush_some` with a time budget, so a redraw never costs the 1 kHz clock a tick).
//
// A cell is two longs. a = code point (21 bits) | attributes << 21 | foreground RGB << 29;
// b = background RGB. Attributes: 1 bold, 2 dim, 4 underline, 8 reverse, 16 italic (drawn
// plain), 32 strike. A wide character (CJK, emoji) takes two cells, the second code point 0.
import kernel;
import font from "./font.y";
import fb from "./fb.y";
import console from "./console.y";

const VT_MAXC = 480;
const VT_MAXR = 135;
const VT_CELLS = 64800;

const DEF_FG = 13553358;
const DEF_BG = 1052692;

let vt_on = false;
let vt_cols = 80;
let vt_rows = 25;
let vt_cx = 0;
let vt_cy = 0;
let vt_wrapnext = false;
let vt_fg = 13553358;
let vt_bg = 1052692;
let vt_attr = 0;
let vt_top = 0;
let vt_bot = 24;
let vt_cur_vis = true;
let vt_autowrap = true;
let vt_appkeys = false;
let vt_alt = false;
let vt_g0_dec = false;
let vt_last_cp = 32;
// mouse reporting (DECSET 1000 / 1002 / 1003, encoding 1006) and the pointer's cell
let vt_mouse = 0;
let vt_msgr = false;
let vt_pshow = false;
let vt_pr = 0;
let vt_pc = 0;

let vt_a: [long; 64800] = [0; 64800];
let vt_b: [long; 64800] = [0; 64800];
let vt_sa: [long; 64800] = [0; 64800];
let vt_sb: [long; 64800] = [0; 64800];
let vt_ta: [long; 64800] = [0; 64800];
let vt_tb: [long; 64800] = [0; 64800];
let vt_dirty: [byte; 135] = [0; 135];
// scrollback: the rows that scrolled off the top of the main screen, a ring of VT_SB rows (each as wide
// as the screen was when it left), and how many rows back the view is (0: the live screen)
const VT_SB = 1000;
let vt_sba: [long; 480000] = [0; 480000];
let vt_sbb: [long; 480000] = [0; 480000];
let vt_sbw: [long; 1000] = [0; 1000];
let vt_sb_head = 0;
let vt_sb_n = 0;
let vt_view = 0;
let vt_any = false;
let vt_flushing = false;
let vt_frame_due = false;
let vt_full = false;
let vt_tick_n = 0;
let vt_tabs: [byte; 480] = [0; 480];
let vt_pal16: [long; 16] = [0; 16];

// saved cursor (DECSC)
let vt_scx = 0;
let vt_scy = 0;
let vt_sfg = 13553358;
let vt_sbg = 1052692;
let vt_sattr = 0;
// the main screen's cursor while the alternate screen is up
let vt_mcx = 0;
let vt_mcy = 0;

// parser
let vt_state = 0;
let vt_params: [long; 16] = [0; 16];
let vt_np = 0;
let vt_have = false;
let vt_prefix = 0;
let vt_inter = 0;
let vt_u_need = 0;
let vt_u_cp = 0;

let vt_reply = "";

// ── colours ─────────────────────────────────────────────────────────────
def vt_rgb(r: long, g: long, b: long) -> long { ((r & 255) << 16) | ((g & 255) << 8) | (b & 255) };

/** xterm palette entry `n` (0..255). */
def vt_pal(n: long) -> long {
    if (n < 16) { return vt_pal16[n]; };
    if (n < 232) {
        let i = n - 16;
        let r = i / 36;
        let g = (i / 6) % 6;
        let b = i % 6;
        let rl = 0;
        let gl = 0;
        let bl = 0;
        if (r > 0) { rl = 55 + 40 * r; };
        if (g > 0) { gl = 55 + 40 * g; };
        if (b > 0) { bl = 55 + 40 * b; };
        return vt_rgb(rl, gl, bl);
    };
    let v = 8 + 10 * (n - 232);
    vt_rgb(v, v, v)
};

def vt_init_pal() -> void {
    vt_pal16[0] = 0;
    vt_pal16[1] = 13369344;
    vt_pal16[2] = 5151238;
    vt_pal16[3] = 12886016;
    vt_pal16[4] = 3433892;
    vt_pal16[5] = 7688315;
    vt_pal16[6] = 432282;
    vt_pal16[7] = 13883343;
    vt_pal16[8] = 5592915;
    vt_pal16[9] = 15673641;
    vt_pal16[10] = 9101876;
    vt_pal16[11] = 16574799;
    vt_pal16[12] = 7512015;
    vt_pal16[13] = 11370408;
    vt_pal16[14] = 3465954;
    vt_pal16[15] = 15658732;
};

// ── cells ───────────────────────────────────────────────────────────────
def vt_a_of(cp: long, attr: long, fg: long) -> long { cp | (attr << 21) | (fg << 29) };

def vt_mark(r: long) -> void {
    if (r >= 0 && r < vt_rows) {
        vt_dirty[r] = 1;
        vt_any = true;
    };
};

def vt_mark_all() -> void {
    let r = 0;
    while (r < vt_rows) {
        vt_dirty[r] = 1;
        r = r + 1;
    };
    vt_any = true;
};

/** A blank cell in the current background. */
def vt_blank(r: long, c: long) -> void {
    let i = r * vt_cols + c;
    vt_a[i] = vt_a_of(32, 0, vt_fg);
    vt_b[i] = vt_bg;
};

def vt_clear_range(r: long, c0: long, c1: long) -> void {
    let c = c0;
    while (c <= c1) {
        vt_blank(r, c);
        c = c + 1;
    };
    vt_mark(r);
};

def vt_clear_rows(r0: long, r1: long) -> void {
    let r = r0;
    while (r <= r1) {
        vt_clear_range(r, 0, vt_cols - 1);
        r = r + 1;
    };
};

def vt_copy_row(dst: long, src: long) -> void {
    let c = 0;
    let d = dst * vt_cols;
    let s = src * vt_cols;
    while (c < vt_cols) {
        vt_a[d + c] = vt_a[s + c];
        vt_b[d + c] = vt_b[s + c];
        c = c + 1;
    };
    vt_mark(dst);
};

def gfx_min(a: long, b: long) -> long { if (a < b) { a } else { b } };

/** Keep screen row `r` in the scrollback ring (it is about to scroll off the top). */
def vt_sb_push(r: long) -> void {
    let slot = vt_sb_head;
    let base = slot * 480;
    let c = 0;
    while (c < vt_cols) {
        vt_sba[base + c] = vt_a[r * vt_cols + c];
        vt_sbb[base + c] = vt_b[r * vt_cols + c];
        c = c + 1;
    };
    vt_sbw[slot] = vt_cols;
    vt_sb_head = (vt_sb_head + 1) % VT_SB;
    if (vt_sb_n < VT_SB) { vt_sb_n = vt_sb_n + 1; };
};

/** Cell (r, c) of what the screen shows: the live grid, or a row of the scrollback when the view is back in time.
Word `which` 0: the cell's a, 1: its background. */
def vt_shown(r: long, c: long, which: long) -> long {
    if (vt_view > 0) {
        let l = vt_sb_n - vt_view + r;
        if (l < vt_sb_n) {
            let slot = (vt_sb_head - vt_sb_n + l + 2 * VT_SB) % VT_SB;
            if (c >= vt_sbw[slot]) {
                if (which == 0) { return vt_a_of(32, 0, DEF_FG); };
                return DEF_BG;
            };
            if (which == 0) { return vt_sba[slot * 480 + c]; };
            return vt_sbb[slot * 480 + c];
        };
        let lr = l - vt_sb_n;
        if (which == 0) { return vt_a[lr * vt_cols + c]; };
        return vt_b[lr * vt_cols + c];
    };
    if (which == 0) { vt_a[r * vt_cols + c] } else { vt_b[r * vt_cols + c] }
};

/** Move the view `d` rows back in time (negative: forward); 0 is the live screen. */
def vt_scrollback(d: long) -> void {
    if (!vt_on || vt_alt) { return; };
    let v = vt_view + d;
    if (v < 0) { v = 0; };
    if (v > vt_sb_n) { v = vt_sb_n; };
    if (v == vt_view) { return; };
    vt_view = v;
    vt_mark_all();
    vt_frame_due = true;
};

/** Back to the live screen (a key was typed). */
def vt_live() -> void {
    if (vt_view > 0) {
        vt_view = 0;
        vt_mark_all();
        vt_frame_due = true;
    };
};

/** Scroll the region [top, bot] up by n rows (text moves up, blank rows enter at the bottom). */
def vt_scroll_up(top: long, bot: long, n: long) -> void {
    if (n > bot - top + 1) { n = bot - top + 1; };
    if (n <= 0) { return; };
    if (top == 0 && !vt_alt) {
        let k = 0;
        while (k < n) {
            vt_sb_push(k);
            k = k + 1;
        };
        if (vt_view > 0) { vt_view = gfx_min(vt_view + n, vt_sb_n); };
    };
    let r = top;
    while (r + n <= bot) {
        vt_copy_row(r, r + n);
        r = r + 1;
    };
    vt_clear_rows(bot - n + 1, bot);
};

def vt_scroll_down(top: long, bot: long, n: long) -> void {
    if (n > bot - top + 1) { n = bot - top + 1; };
    if (n <= 0) { return; };
    let r = bot;
    while (r - n >= top) {
        vt_copy_row(r, r - n);
        r = r - 1;
    };
    vt_clear_rows(top, top + n - 1);
};

// ── cursor ──────────────────────────────────────────────────────────────
def vt_goto(r: long, c: long) -> void {
    vt_mark(vt_cy);
    if (r < 0) { r = 0; };
    if (r >= vt_rows) { r = vt_rows - 1; };
    if (c < 0) { c = 0; };
    if (c >= vt_cols) { c = vt_cols - 1; };
    vt_cy = r;
    vt_cx = c;
    vt_wrapnext = false;
    vt_mark(vt_cy);
};

/** Down one row, scrolling the region at its bottom margin. */
def vt_index() -> void {
    if (vt_cy == vt_bot) {
        vt_scroll_up(vt_top, vt_bot, 1);
    } else if (vt_cy < vt_rows - 1) {
        vt_mark(vt_cy);
        vt_cy = vt_cy + 1;
        vt_mark(vt_cy);
    };
};

def vt_rev_index() -> void {
    if (vt_cy == vt_top) {
        vt_scroll_down(vt_top, vt_bot, 1);
    } else if (vt_cy > 0) {
        vt_mark(vt_cy);
        vt_cy = vt_cy - 1;
        vt_mark(vt_cy);
    };
};

// ── printing ────────────────────────────────────────────────────────────
/** Columns a code point takes: 0 (combining, zero width), 1 or 2. */
def vt_wcwidth(cp: long) -> long {
    if (cp < 768) { return 1; };
    if (cp >= 768 && cp <= 879) { return 0; };
    if (cp >= 8203 && cp <= 8207) { return 0; };
    if (cp >= 65024 && cp <= 65039) { return 0; };
    if (cp == 65279) { return 0; };
    if (cp >= 4352 && cp <= 4447) { return 2; };
    if (cp >= 11904 && cp <= 42191) { return 2; };
    if (cp >= 44032 && cp <= 55203) { return 2; };
    if (cp >= 63744 && cp <= 64255) { return 2; };
    if (cp >= 65072 && cp <= 65135) { return 2; };
    if (cp >= 65280 && cp <= 65376) { return 2; };
    if (cp >= 65504 && cp <= 65510) { return 2; };
    if (cp >= 127744 && cp <= 128591) { return 2; };
    if (cp >= 129280 && cp <= 129535) { return 2; };
    if (cp >= 131072 && cp <= 262141) { return 2; };
    1
};

/** DEC special graphics: the code point drawn for byte `c` while G0 is the line-drawing set. */
def vt_dec_map(c: long) -> long {
    if (c == 106) { return 9496; };
    if (c == 107) { return 9488; };
    if (c == 108) { return 9484; };
    if (c == 109) { return 9492; };
    if (c == 110) { return 9532; };
    if (c == 113) { return 9472; };
    if (c == 116) { return 9500; };
    if (c == 117) { return 9508; };
    if (c == 118) { return 9524; };
    if (c == 119) { return 9516; };
    if (c == 120) { return 9474; };
    if (c == 97) { return 9618; };
    if (c == 96) { return 9670; };
    if (c == 102) { return 176; };
    if (c == 103) { return 177; };
    if (c == 126) { return 183; };
    if (c == 111 || c == 112) { return 9472; };
    if (c == 114 || c == 115) { return 9472; };
    c
};

def vt_set_cell(c: long, cp: long) -> void {
    let i = vt_cy * vt_cols + c;
    vt_a[i] = vt_a_of(cp, vt_attr, vt_fg);
    vt_b[i] = vt_bg;
};

/** Put one character at the cursor and advance it. */
def vt_print(cp: long) -> void {
    let w = vt_wcwidth(cp);
    if (w == 0) { return; };
    if (vt_wrapnext && vt_autowrap) {
        vt_cx = 0;
        vt_index();
    };
    vt_wrapnext = false;
    if (w == 2 && vt_cx == vt_cols - 1) {
        if (vt_autowrap) {
            vt_blank(vt_cy, vt_cx);
            vt_cx = 0;
            vt_index();
        } else {
            w = 1;
        };
    };
    vt_last_cp = cp;
    vt_set_cell(vt_cx, cp);
    if (w == 2) { vt_set_cell(vt_cx + 1, 0); };
    vt_mark(vt_cy);
    vt_cx = vt_cx + w;
    if (vt_cx >= vt_cols) {
        vt_cx = vt_cols - 1;
        vt_wrapnext = true;
    };
};

// ── sequences ───────────────────────────────────────────────────────────
def vt_param(i: long, dflt: long) -> long {
    if (i >= vt_np) { return dflt; };
    let v = vt_params[i];
    if (v == 0) { dflt } else { v }
};

def vt_reply_add(s: str) -> void { vt_reply += s; };

/** The replies a query asked for (DSR, DA), for the tty to type back; empties the buffer. */
def vt_take_reply() -> str {
    let r = vt_reply;
    vt_reply = "";
    r
};

def vt_erase_display(mode: long) -> void {
    if (mode == 0) {
        vt_clear_range(vt_cy, vt_cx, vt_cols - 1);
        if (vt_cy + 1 < vt_rows) { vt_clear_rows(vt_cy + 1, vt_rows - 1); };
    } else if (mode == 1) {
        if (vt_cy > 0) { vt_clear_rows(0, vt_cy - 1); };
        vt_clear_range(vt_cy, 0, vt_cx);
    } else {
        vt_clear_rows(0, vt_rows - 1);
        if (mode == 3) {
            vt_sb_n = 0;
            vt_view = 0;
        };
    };
};

def vt_erase_line(mode: long) -> void {
    if (mode == 0) { vt_clear_range(vt_cy, vt_cx, vt_cols - 1); }
    else if (mode == 1) { vt_clear_range(vt_cy, 0, vt_cx); }
    else { vt_clear_range(vt_cy, 0, vt_cols - 1); };
};

def vt_insert_chars(n: long) -> void {
    if (n > vt_cols - vt_cx) { n = vt_cols - vt_cx; };
    let base = vt_cy * vt_cols;
    let c = vt_cols - 1;
    while (c - n >= vt_cx) {
        vt_a[base + c] = vt_a[base + c - n];
        vt_b[base + c] = vt_b[base + c - n];
        c = c - 1;
    };
    vt_clear_range(vt_cy, vt_cx, vt_cx + n - 1);
};

def vt_delete_chars(n: long) -> void {
    if (n > vt_cols - vt_cx) { n = vt_cols - vt_cx; };
    let base = vt_cy * vt_cols;
    let c = vt_cx;
    while (c + n < vt_cols) {
        vt_a[base + c] = vt_a[base + c + n];
        vt_b[base + c] = vt_b[base + c + n];
        c = c + 1;
    };
    vt_clear_range(vt_cy, vt_cols - n, vt_cols - 1);
};

def vt_sgr() -> void {
    if (vt_np == 0) {
        vt_fg = DEF_FG;
        vt_bg = DEF_BG;
        vt_attr = 0;
        return;
    };
    let i = 0;
    while (i < vt_np) {
        let p = vt_params[i];
        if (p == 0) { vt_fg = DEF_FG; vt_bg = DEF_BG; vt_attr = 0; }
        else if (p == 1) { vt_attr = vt_attr | 1; }
        else if (p == 2) { vt_attr = vt_attr | 2; }
        else if (p == 3) { vt_attr = vt_attr | 16; }
        else if (p == 4) { vt_attr = vt_attr | 4; }
        else if (p == 7) { vt_attr = vt_attr | 8; }
        else if (p == 9) { vt_attr = vt_attr | 32; }
        else if (p == 22) { vt_attr = vt_attr & ~3; }
        else if (p == 23) { vt_attr = vt_attr & ~16; }
        else if (p == 24) { vt_attr = vt_attr & ~4; }
        else if (p == 27) { vt_attr = vt_attr & ~8; }
        else if (p == 29) { vt_attr = vt_attr & ~32; }
        else if (p >= 30 && p <= 37) { vt_fg = vt_pal(p - 30); }
        else if (p == 39) { vt_fg = DEF_FG; }
        else if (p >= 40 && p <= 47) { vt_bg = vt_pal(p - 40); }
        else if (p == 49) { vt_bg = DEF_BG; }
        else if (p >= 90 && p <= 97) { vt_fg = vt_pal(p - 90 + 8); }
        else if (p >= 100 && p <= 107) { vt_bg = vt_pal(p - 100 + 8); }
        else if (p == 38 || p == 48) {
            let col = 0;
            let ok = false;
            if (i + 2 < vt_np && vt_params[i + 1] == 5) {
                col = vt_pal(vt_params[i + 2] & 255);
                ok = true;
                i = i + 2;
            } else if (i + 4 < vt_np && vt_params[i + 1] == 2) {
                col = vt_rgb(vt_params[i + 2], vt_params[i + 3], vt_params[i + 4]);
                ok = true;
                i = i + 4;
            };
            if (ok) {
                if (p == 38) { vt_fg = col; } else { vt_bg = col; };
            };
        };
        i = i + 1;
    };
};

def vt_save_cursor() -> void {
    vt_scx = vt_cx;
    vt_scy = vt_cy;
    vt_sfg = vt_fg;
    vt_sbg = vt_bg;
    vt_sattr = vt_attr;
};

def vt_restore_cursor() -> void {
    vt_goto(vt_scy, vt_scx);
    vt_fg = vt_sfg;
    vt_bg = vt_sbg;
    vt_attr = vt_sattr;
};

/** Enter (on) or leave (off) the alternate screen. */
def vt_set_alt(on: bool) -> void {
    if (on == vt_alt) { return; };
    vt_view = 0;
    let i = 0;
    let n = vt_rows * vt_cols;
    if (on) {
        while (i < n) {
            vt_sa[i] = vt_a[i];
            vt_sb[i] = vt_b[i];
            i = i + 1;
        };
        vt_mcx = vt_cx;
        vt_mcy = vt_cy;
        vt_alt = true;
        vt_fg = DEF_FG;
        vt_bg = DEF_BG;
        vt_attr = 0;
        vt_clear_rows(0, vt_rows - 1);
    } else {
        while (i < n) {
            vt_a[i] = vt_sa[i];
            vt_b[i] = vt_sb[i];
            i = i + 1;
        };
        vt_alt = false;
        vt_goto(vt_mcy, vt_mcx);
        vt_mark_all();
    };
};

def vt_mode(on: bool) -> void {
    let i = 0;
    while (i < vt_np) {
        let p = vt_params[i];
        if (vt_prefix == 63) {
            if (p == 1) { vt_appkeys = on; }
            else if (p == 7) { vt_autowrap = on; }
            else if (p == 25) { vt_cur_vis = on; vt_mark(vt_cy); }
            else if (p == 1000 || p == 1002 || p == 1003) { if (on) { vt_mouse = p; } else if (vt_mouse == p) { vt_mouse = 0; }; }
            else if (p == 1006) { vt_msgr = on; }
            else if (p == 47 || p == 1047) { vt_set_alt(on); }
            else if (p == 1049) {
                if (on) { vt_save_cursor(); vt_set_alt(true); } else { vt_set_alt(false); vt_restore_cursor(); };
            };
        };
        i = i + 1;
    };
};

def vt_set_margins() -> void {
    let t = vt_param(0, 1) - 1;
    let b = vt_param(1, vt_rows) - 1;
    if (b >= vt_rows) { b = vt_rows - 1; };
    if (t < b) {
        vt_top = t;
        vt_bot = b;
    } else {
        vt_top = 0;
        vt_bot = vt_rows - 1;
    };
    vt_goto(0, 0);
};

def vt_csi(f: long) -> void {
    let n = vt_param(0, 1);
    if (f == 65) { vt_goto(vt_cy - n, vt_cx); }
    else if (f == 66 || f == 101) { vt_goto(vt_cy + n, vt_cx); }
    else if (f == 67 || f == 97) { vt_goto(vt_cy, vt_cx + n); }
    else if (f == 68) { vt_goto(vt_cy, vt_cx - n); }
    else if (f == 69) { vt_goto(vt_cy + n, 0); }
    else if (f == 70) { vt_goto(vt_cy - n, 0); }
    else if (f == 71 || f == 96) { vt_goto(vt_cy, n - 1); }
    else if (f == 100) { vt_goto(n - 1, vt_cx); }
    else if (f == 72 || f == 102) { vt_goto(vt_param(0, 1) - 1, vt_param(1, 1) - 1); }
    else if (f == 74) { vt_erase_display(vt_param(0, 0)); }
    else if (f == 75) { vt_erase_line(vt_param(0, 0)); }
    else if (f == 76) {
        if (vt_cy >= vt_top && vt_cy <= vt_bot) { vt_scroll_down(vt_cy, vt_bot, n); };
        vt_cx = 0;
        vt_wrapnext = false;
    }
    else if (f == 77) {
        if (vt_cy >= vt_top && vt_cy <= vt_bot) { vt_scroll_up(vt_cy, vt_bot, n); };
        vt_cx = 0;
        vt_wrapnext = false;
    }
    else if (f == 64) { vt_insert_chars(n); }
    else if (f == 80) { vt_delete_chars(n); }
    else if (f == 88) {
        let e = vt_cx + n - 1;
        if (e >= vt_cols) { e = vt_cols - 1; };
        vt_clear_range(vt_cy, vt_cx, e);
    }
    else if (f == 83) { vt_scroll_up(vt_top, vt_bot, n); }
    else if (f == 84) { vt_scroll_down(vt_top, vt_bot, n); }
    else if (f == 109) { vt_sgr(); }
    else if (f == 104) { vt_mode(true); }
    else if (f == 108) { vt_mode(false); }
    else if (f == 114) { vt_set_margins(); }
    else if (f == 115) { vt_save_cursor(); }
    else if (f == 117) { vt_restore_cursor(); }
    else if (f == 98) {
        let k = 0;
        while (k < n && k < 4096) {
            vt_print(vt_last_cp);
            k = k + 1;
        };
    }
    else if (f == 103) {
        if (vt_param(0, 0) == 3) {
            let t = 0;
            while (t < VT_MAXC) { vt_tabs[t] = 0; t = t + 1; };
        } else if (vt_cx < VT_MAXC) {
            vt_tabs[vt_cx] = 0;
        };
    }
    else if (f == 110) {
        if (vt_param(0, 0) == 5) { vt_reply_add(chr(27) + "[0n"); }
        else if (vt_param(0, 0) == 6) { vt_reply_add(chr(27) + "[" + tostring(vt_cy + 1) + ";" + tostring(vt_cx + 1) + "R"); };
    }
    else if (f == 99) {
        if (vt_prefix == 0) { vt_reply_add(chr(27) + "[?1;2c"); }
        else if (vt_prefix == 62) { vt_reply_add(chr(27) + "[>0;0;0c"); };
    };
};

def vt_reset() -> void {
    vt_fg = DEF_FG;
    vt_bg = DEF_BG;
    vt_attr = 0;
    vt_top = 0;
    vt_bot = vt_rows - 1;
    vt_cur_vis = true;
    vt_autowrap = true;
    vt_appkeys = false;
    vt_mouse = 0;
    vt_msgr = false;
    vt_g0_dec = false;
    vt_alt = false;
    vt_state = 0;
    vt_u_need = 0;
    let t = 0;
    while (t < VT_MAXC) {
        if (t % 8 == 0) { vt_tabs[t] = 1; } else { vt_tabs[t] = 0; };
        t = t + 1;
    };
    vt_clear_rows(0, vt_rows - 1);
    vt_goto(0, 0);
};

def vt_csi_start() -> void {
    vt_np = 0;
    vt_have = false;
    vt_prefix = 0;
    vt_inter = 0;
    let i = 0;
    while (i < 16) { vt_params[i] = 0; i = i + 1; };
    vt_state = 2;
};

def vt_esc(c: long) -> void {
    vt_state = 0;
    if (c == 91) { vt_csi_start(); }
    else if (c == 93) { vt_state = 3; }
    else if (c == 40) { vt_state = 4; }
    else if (c == 41 || c == 42 || c == 43) { vt_state = 6; }
    else if (c == 55) { vt_save_cursor(); }
    else if (c == 56) { vt_restore_cursor(); }
    else if (c == 77) { vt_rev_index(); }
    else if (c == 68) { vt_index(); }
    else if (c == 69) { vt_cx = 0; vt_index(); vt_goto(vt_cy, 0); }
    else if (c == 99) { vt_reset(); }
    else if (c == 72) { if (vt_cx < VT_MAXC) { vt_tabs[vt_cx] = 1; }; };
};

def vt_csi_byte(c: long) -> void {
    if (c >= 48 && c <= 57) {
        if (vt_np < 16) {
            if (!vt_have) { vt_have = true; if (vt_np == 0) { vt_np = 1; }; };
            let i = vt_np - 1;
            vt_params[i] = vt_params[i] * 10 + c - 48;
            if (vt_params[i] > 65535) { vt_params[i] = 65535; };
        };
    } else if (c == 59 || c == 58) {
        if (!vt_have && vt_np == 0) { vt_np = 1; };
        if (vt_np < 16) { vt_np = vt_np + 1; };
        vt_have = true;
    } else if (c >= 60 && c <= 63) {
        vt_prefix = c;
    } else if (c >= 32 && c <= 47) {
        vt_inter = c;
    } else if (c >= 64 && c <= 126) {
        vt_state = 0;
        if (vt_inter == 0) { vt_csi(c); };
    } else if (c == 27) {
        vt_state = 1;
    } else if (c == 24 || c == 26) {
        vt_state = 0;
    };
};

/** A C0 control in the ground state. */
def vt_control(c: long) -> bool {
    if (c == 27) { vt_state = 1; return true; };
    if (c == 8) { if (vt_cx > 0) { vt_cx = vt_cx - 1; }; vt_wrapnext = false; vt_mark(vt_cy); return true; };
    if (c == 9) {
        let x = vt_cx + 1;
        while (x < vt_cols - 1 && vt_tabs[x] == 0) { x = x + 1; };
        if (x > vt_cols - 1) { x = vt_cols - 1; };
        vt_cx = x;
        vt_wrapnext = false;
        vt_mark(vt_cy);
        return true;
    };
    if (c == 10 || c == 11 || c == 12) { vt_index(); vt_wrapnext = false; return true; };
    if (c == 13) { vt_cx = 0; vt_wrapnext = false; vt_mark(vt_cy); return true; };
    c < 32
};

/** One byte of output. */
def vt_putc(b: long) -> void {
    if (!vt_on) { return; };
    let c = b & 255;
    if (vt_state == 0) {
        if (vt_u_need > 0) {
            if (c >= 128 && c < 192) {
                vt_u_cp = (vt_u_cp << 6) | (c & 63);
                vt_u_need = vt_u_need - 1;
                if (vt_u_need == 0) { vt_print(vt_u_cp); };
                return;
            };
            vt_u_need = 0;
        };
        if (c < 32) { vt_control(c); return; };
        if (c < 128) {
            if (vt_g0_dec) { vt_print(vt_dec_map(c)); } else { vt_print(c); };
            return;
        };
        if (c >= 192 && c < 224) { vt_u_need = 1; vt_u_cp = c & 31; }
        else if (c >= 224 && c < 240) { vt_u_need = 2; vt_u_cp = c & 15; }
        else if (c >= 240 && c < 248) { vt_u_need = 3; vt_u_cp = c & 7; };
    } else if (vt_state == 1) {
        vt_esc(c);
    } else if (vt_state == 2) {
        vt_csi_byte(c);
    } else if (vt_state == 3) {
        // OSC: up to BEL or ESC \
        if (c == 7) { vt_state = 0; } else if (c == 27) { vt_state = 5; };
    } else if (vt_state == 5) {
        vt_state = 0;
    } else if (vt_state == 4) {
        vt_g0_dec = c == 48;
        vt_state = 0;
    } else if (vt_state == 6) {
        vt_state = 0;
    };
};

// ── drawing ─────────────────────────────────────────────────────────────
def vt_bright(c: long) -> long {
    let r = (c >> 16) & 255;
    let g = (c >> 8) & 255;
    let b = c & 255;
    vt_rgb(r + (255 - r) * 3 / 8, g + (255 - g) * 3 / 8, b + (255 - b) * 3 / 8)
};

def vt_dim(c: long) -> long {
    vt_rgb(((c >> 16) & 255) * 2 / 3, ((c >> 8) & 255) * 2 / 3, (c & 255) * 2 / 3)
};

/** Render cell (r, c) into the VT buffer. */
def vt_draw_cell(r: long, c: long, buf: long, w: long) -> void {
    let a = vt_shown(r, c, 0);
    let cp = a & 2097151;
    let attr = (a >> 21) & 255;
    let fg = (a >> 29) & 16777215;
    let bg = vt_shown(r, c, 1);
    if ((attr & 1) != 0) { fg = vt_bright(fg); };
    if ((attr & 2) != 0) { fg = vt_dim(fg); };
    let rev = (attr & 8) != 0;
    if (vt_cur_vis && vt_view == 0 && r == vt_cy && c == vt_cx) { rev = !rev; };
    if (rev) {
        let t = fg;
        fg = bg;
        bg = t;
    };
    if (vt_pshow && r == vt_pr && c == vt_pc) {
        fg = 658958;
        bg = 5809919;
    };
    let blank = cp == 32 || cp == 0;
    let slot = 0;
    if (!blank) { slot = font.font_slot(cp); };
    let p: *u32 = ptr_from(buf + (r * 16 * w + c * 8) * 4);
    let y = 0;
    while (y < 16) {
        let bits = 0;
        if (!blank) { bits = font.font_row(slot, y); };
        if ((attr & 4) != 0 && y == 15) { bits = 255; };
        if ((attr & 32) != 0 && y == 8) { bits = 255; };
        let q: *u32 = p + y * w;
        *q = if ((bits & 128) != 0) { fg } else { bg };
        *(q + 1) = if ((bits & 64) != 0) { fg } else { bg };
        *(q + 2) = if ((bits & 32) != 0) { fg } else { bg };
        *(q + 3) = if ((bits & 16) != 0) { fg } else { bg };
        *(q + 4) = if ((bits & 8) != 0) { fg } else { bg };
        *(q + 5) = if ((bits & 4) != 0) { fg } else { bg };
        *(q + 6) = if ((bits & 2) != 0) { fg } else { bg };
        *(q + 7) = if ((bits & 1) != 0) { fg } else { bg };
        y = y + 1;
    };
};

/** Render dirty rows (top down) and show them, stopping once `budget` TSC cycles have gone;
the rows left over stay dirty and the next tick carries on. */
def vt_flush_some(budget: long) -> void {
    if (!vt_on || !vt_any || vt_flushing) { return; };
    if (console.con_get_mode() != 0) { return; };
    vt_flushing = true;
    let t0 = kernel.rdtsc();
    let buf = fb.fb_vt_buf();
    let w = fb.fb_width();
    let r = 0;
    let run = 0 - 1;
    let left = false;
    while (r < vt_rows && !left) {
        if (vt_dirty[r] != 0) {
            vt_dirty[r] = 0;
            let c = 0;
            while (c < vt_cols) {
                vt_draw_cell(r, c, buf, w);
                c = c + 1;
            };
            if (run < 0) { run = r; };
            if (kernel.rdtsc() - t0 > budget) { left = true; };
        } else if (run >= 0) {
            fb.fb_flush(buf, 0, run * 16, w, (r - run) * 16);
            run = 0 - 1;
        };
        r = r + 1;
    };
    if (run >= 0) { fb.fb_flush(buf, 0, run * 16, w, (r - run) * 16); };
    if (!left && vt_full) {
        vt_full = false;
        fb.fb_flush(buf, 0, vt_rows * 16, w, fb.fb_height() - vt_rows * 16);
    };
    vt_any = left;
    vt_frame_due = left;
    vt_flushing = false;
};

/** The 1 kHz clock: a frame is due about every 16 ms. */
def vt_tick() -> void {
    vt_tick_n = vt_tick_n + 1;
    if (vt_tick_n >= 16) {
        vt_tick_n = 0;
        vt_frame_due = true;
    };
};

/** True when the clock handler should call `vt_flush_some` (once a frame, and while a frame is unfinished). */
def vt_frame_pending() -> bool { vt_frame_due && vt_any && !vt_flushing };

def vt_get_appkeys() -> bool { vt_appkeys };

/** Which mouse reports the program asked for: 0 none, else 1000 (buttons), 1002 (and drags), 1003 (and all motion). */
def vt_mouse_mode() -> long { vt_mouse };
def vt_mouse_sgr() -> bool { vt_msgr };

/** The pointer sits over cell (r, c) (drawn as a coloured block); the old cell's row and the new one are redrawn. */
def vt_set_pointer(r: long, c: long) -> void {
    if (!vt_on) { return; };
    if (vt_pshow && r == vt_pr && c == vt_pc) { return; };
    vt_mark(vt_pr);
    vt_pshow = true;
    vt_pr = r;
    vt_pc = c;
    vt_mark(r);
};
def vt_in_alt() -> bool { vt_alt };
def vt_get_rows() -> long { vt_rows };
def vt_get_cols() -> long { vt_cols };
def vt_active() -> bool { vt_on };

/** The terminal's size follows the display: keep what fits, fill the rest blank. */
def vt_resize() -> void {
    if (!vt_on) { return; };
    let nc = fb.fb_width() / 8;
    let nr = fb.fb_height() / 16;
    if (nc > VT_MAXC) { nc = VT_MAXC; };
    if (nr > VT_MAXR) { nr = VT_MAXR; };
    if (nc < 20) { nc = 20; };
    if (nr < 5) { nr = 5; };
    vt_view = 0;
    let oc = vt_cols;
    let orr = vt_rows;
    let n = orr * oc;
    let i = 0;
    while (i < n) {
        vt_ta[i] = vt_a[i];
        vt_tb[i] = vt_b[i];
        i = i + 1;
    };
    vt_cols = nc;
    vt_rows = nr;
    let r = 0;
    while (r < nr) {
        let c = 0;
        while (c < nc) {
            let j = r * nc + c;
            if (r < orr && c < oc) {
                vt_a[j] = vt_ta[r * oc + c];
                vt_b[j] = vt_tb[r * oc + c];
            } else {
                vt_a[j] = vt_a_of(32, 0, DEF_FG);
                vt_b[j] = DEF_BG;
            };
            c = c + 1;
        };
        r = r + 1;
    };
    vt_top = 0;
    vt_bot = nr - 1;
    if (vt_cy >= nr) { vt_cy = nr - 1; };
    if (vt_cx >= nc) { vt_cx = nc - 1; };
    vt_wrapnext = false;
    vt_clear_margin();
    vt_mark_all();
    vt_full = true;
    vt_frame_due = true;
};

/** Paint the pixels the grid does not cover (a display that is not a multiple of 8x16). */
def vt_clear_margin() -> void {
    let w = fb.fb_width();
    let h = fb.fb_height();
    let p: *u32 = ptr_from(fb.fb_vt_buf());
    let n = w * h;
    let i = vt_rows * 16 * w;
    while (i < n) {
        *(p + i) = DEF_BG;
        i = i + 1;
    };
    let y = 0;
    while (y < vt_rows * 16) {
        let x = vt_cols * 8;
        while (x < w) {
            *(p + y * w + x) = DEF_BG;
            x = x + 1;
        };
        y = y + 1;
    };
};

/** Attach the terminal to the display (boot, after fb.fb_init). */
def vt_init() -> bool {
    if (!fb.fb_present()) { return false; };
    font.font_init();
    vt_init_pal();
    vt_on = true;
    vt_cols = 80;
    vt_rows = 25;
    vt_resize();
    vt_reset();
    vt_clear_margin();
    vt_mark_all();
    true
};

/** The VT view comes (back) to the screen: everything is redrawn at the next frame. */
def vt_show() -> void {
    if (!vt_on) { return; };
    vt_mark_all();
    vt_full = true;
    vt_frame_due = true;
};
