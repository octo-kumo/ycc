// fexp -- the GUI's file explorer: a panel of the desktop (not a program) that lists a directory,
// goes into folders, makes folders and empty files, and opens a file in the bundled editor.
//
// The GUI feeds it clicks, wheel turns and keys while it is open; what it wants run (the editor on
// a file) it leaves in `cmd` for the GUI to type into the shell. Names it makes are limited to
// characters the shell needs no quoting for.
import ulib;
import gfx;

const ROWH = 24;
const TITLEH = 32;
const BARH = 44;
const PATHH = 28;
const FOOTH = 34;

const BG = 0xF012161E;
const BAR = 0xFF1B2230;
const EDGE = 0xFF2E3646;
const TXT = 0xFFE6EDF3;
const DIM = 0xFF8794AB;
const HOT = 0xFF2B3A55;
const BTN = 0xFF2F3B52;
const BTN_HOT = 0xFF41547A;
const FOLDER = 0xFFFBBF24;
const FILE = 0xFF93C5FD;
const GOOD = 0xFF4ADE80;
const BAD = 0xFFF87171;

let is_open = false;
let path = "/home/user";
let names: [str] = [];
let kinds: [long] = [];
let sizes: [long] = [];
let top = 0;
let hover = 0 - 1;
let hover_btn = 0 - 1;
// 0 browsing, 1 naming a folder, 2 naming a file
let mode = 0;
let field = "";
let msg = "";
let msg_bad = false;
// the command the GUI should run (the editor on a file), "" when none
let cmd = "";

// geometry
let ex = 0;
let ey = 0;
let ew = 0;
let eh = 0;

def layout(sw: long, dock_top: long) -> void {
    ew = gfx.min(sw - 40, 760);
    eh = gfx.min(dock_top - 80, 560);
    eh = gfx.max(eh, 240);
    ex = (sw - ew) / 2;
    ey = gfx.max(16, (dock_top - 44 - eh) / 2);
};

/** The command to run (and forget it). */
def take_cmd() -> str {
    let c = cmd;
    cmd = "";
    c
};

def inside(x: long, y: long) -> bool { is_open && x >= ex && x < ex + ew && y >= ey && y < ey + eh };

def join(dir: str, name: str) -> str { if (dir == "/") { "/" + name } else { dir + "/" + name } };

def parent_of(p: str) -> str {
    let i = len(p) - 1;
    while (i > 0 && p[i] != 47) { i = i - 1; };
    if (i <= 0) { "/" } else { p[0:i] }
};

def size_str(n: long) -> str {
    if (n < 1024) { return tostring(n) + " B"; };
    if (n < 1048576) { return tostring(n / 1024) + "." + tostring(n * 10 / 1024 % 10) + " KiB"; };
    tostring(n / 1048576) + "." + tostring(n * 10 / 1048576 % 10) + " MiB"
};

/** Read the directory again: folders first, each group by name. */
def refresh() -> void {
    names = [];
    kinds = [];
    sizes = [];
    let ents = ulib.read_dir(path);
    if (ents == none) {
        msg = "cannot read " + path;
        msg_bad = true;
        return;
    };
    let ds: [str] = [];
    let fs: [str] = [];
    foreach (e in ents!) {
        if (e.name == "." || e.name == "..") { continue; };
        if (ulib.is_dir(join(path, e.name))) { ds += e.name; } else { fs += e.name; };
    };
    sort(ds);
    sort(fs);
    foreach (n in ds) { names += n; kinds += 4; sizes += 0; };
    foreach (n in fs) {
        names += n;
        kinds += 8;
        let st = ulib.stat(join(path, n));
        sizes += if (st == none) { 0 } else { st!.size };
    };
    top = gfx.clamp(top, 0, gfx.max(len(names) - rows(), 0));
};

def sort(a: [str]) -> void {
    let i = 1;
    while (i < len(a)) {
        let j = i;
        while (j > 0 && a[j - 1] > a[j]) {
            let t = a[j];
            a[j] = a[j - 1];
            a[j - 1] = t;
            j = j - 1;
        };
        i = i + 1;
    };
};

def rows() -> long { gfx.max((eh - TITLEH - BARH - PATHH - FOOTH) / ROWH, 1) };

def list_y() -> long { ey + TITLEH + BARH + PATHH };

def toggle(start: str) -> void {
    is_open = !is_open;
    if (is_open) {
        if (ulib.is_dir(start)) { path = start; };
        mode = 0;
        field = "";
        msg = "";
        top = 0;
        refresh();
    };
};

def go(p: str) -> void {
    path = p;
    top = 0;
    hover = 0 - 1;
    mode = 0;
    field = "";
    msg = "";
    refresh();
};

// toolbar buttons: label and the x of each (relative to the panel)
def nbtn() -> long { 4 };
def btn_label(i: long) -> str {
    if (i == 0) { return "Up"; };
    if (i == 1) { return "New folder"; };
    if (i == 2) { return "New file"; };
    "Refresh"
};
def btn_x(i: long) -> long {
    let x = 14;
    let k = 0;
    while (k < i) { x = x + len(btn_label(k)) * 8 + 36; k = k + 1; };
    x
};
def btn_w(i: long) -> long { len(btn_label(i)) * 8 + 24 };

def btn_at(x: long, y: long) -> long {
    if (y < ey + TITLEH + 6 || y >= ey + TITLEH + BARH - 6) { return 0 - 1; };
    let i = 0;
    while (i < nbtn()) {
        let bx = ex + btn_x(i);
        if (x >= bx && x < bx + btn_w(i)) { return i; };
        i = i + 1;
    };
    0 - 1
};

def row_at(x: long, y: long) -> long {
    let ly = list_y();
    if (x < ex + 1 || x >= ex + ew - 1 || y < ly || y >= ly + rows() * ROWH) { return 0 - 1; };
    let i = top + (y - ly) / ROWH;
    if (i >= len(names)) { 0 - 1 } else { i }
};

def hover_at(x: long, y: long) -> bool {
    let h = row_at(x, y);
    let b = btn_at(x, y);
    let changed = h != hover || b != hover_btn;
    hover = h;
    hover_btn = b;
    changed
};

def make(name: str) -> void {
    if (name == "") { return; };
    let p = join(path, name);
    if (ulib.exists(p)) {
        msg = name + " already exists";
        msg_bad = true;
        return;
    };
    if (mode == 1) {
        if (ulib.mkdir(p) < 0) { msg = "cannot make folder " + name; msg_bad = true; return; };
        msg = "made folder " + name;
    } else {
        let fd = ulib.open(p, 65);
        if (fd < 0) { msg = "cannot make file " + name; msg_bad = true; return; };
        ulib.close(fd);
        msg = "made file " + name;
    };
    msg_bad = false;
    mode = 0;
    field = "";
    refresh();
};

/** A press at (x, y) inside the panel. */
def click(x: long, y: long) -> void {
    if (y < ey + TITLEH) {
        // the close box
        if (x >= ex + ew - 34) { is_open = false; };
        return;
    };
    let b = btn_at(x, y);
    if (b == 0) { if (path != "/") { go(parent_of(path)); }; return; };
    if (b == 1 || b == 2) {
        mode = b;
        field = "";
        msg = "";
        return;
    };
    if (b == 3) { go(path); msg = "refreshed"; msg_bad = false; return; };
    // the parent row of the path line
    if (y >= ey + TITLEH + BARH && y < list_y()) {
        if (path != "/") { go(parent_of(path)); };
        return;
    };
    let i = row_at(x, y);
    if (i < 0) { return; };
    if (kinds[i] == 4) {
        go(join(path, names[i]));
    } else {
        cmd = "editor " + join(path, names[i]);
        is_open = false;
    };
};

def wheel(d: long) -> void {
    top = gfx.clamp(top + d, 0, gfx.max(len(names) - rows(), 0));
};

/** The character a key types for the field, or 0. */
def key_char(code: long, shift: bool) -> long {
    let letters = "qwertyuiop";
    if (code >= 16 && code <= 25) { return letter(letters[code - 16], shift); };
    let home = "asdfghjkl";
    if (code >= 30 && code <= 38) { return letter(home[code - 30], shift); };
    let low = "zxcvbnm";
    if (code >= 44 && code <= 50) { return letter(low[code - 44], shift); };
    if (code >= 2 && code <= 11) {
        let digits = "1234567890";
        if (shift) { if (code == 3) { return 64; }; return 0; };
        return digits[code - 2];
    };
    if (code == 12) { return if (shift) { 95 } else { 45 }; };
    if (code == 13) { return if (shift) { 43 } else { 61 }; };
    if (code == 51) { return 44; };
    if (code == 52) { return 46; };
    0
};

def letter(c: long, shift: bool) -> long { if (shift) { c - 32 } else { c } };

/** A key press (or repeat) while the panel is open. */
def key(code: long, shift: bool) -> void {
    if (code == 1) {
        if (mode != 0) { mode = 0; field = ""; msg = ""; } else { is_open = false; };
        return;
    };
    if (mode != 0) {
        if (code == 14) {
            if (len(field) > 0) { field = field[0:len(field) - 1]; };
        } else if (code == 28 || code == 96) {
            make(field);
        } else {
            let c = key_char(code, shift);
            if (c != 0 && len(field) < 48) { field += chr(c); };
        };
        return;
    };
    if (code == 14 && path != "/") { go(parent_of(path)); }
    else if (code == 104) { wheel(0 - rows()); }
    else if (code == 109) { wheel(rows()); }
    else if (code == 103) { wheel(0 - 1); }
    else if (code == 108) { wheel(1); }
    else if (code == 102) { top = 0; }
    else if (code == 107) { top = gfx.max(len(names) - rows(), 0); };
};

// ── drawing ─────────────────────────────────────────────────────────────

def button(s: gfx.Surf, i: long) -> void {
    let bx = ex + btn_x(i);
    let by = ey + TITLEH + 7;
    let c = if (i == hover_btn || (mode == i && i > 0)) { BTN_HOT } else { BTN };
    gfx.fill_round(s, bx, by, bx + btn_w(i), by + BARH - 14, 5, c & 16777215);
    gfx.text(s, bx + 12, by + 5, btn_label(i), 1, TXT);
};

def draw_folder(s: gfx.Surf, x: long, y: long) -> void {
    gfx.rect(s, x, y + 3, x + 7, y + 6, FOLDER);
    gfx.rect(s, x, y + 5, x + 16, y + 15, FOLDER);
};

def draw_file(s: gfx.Surf, x: long, y: long) -> void {
    gfx.rect(s, x + 2, y + 1, x + 13, y + 15, FILE);
    gfx.rect(s, x + 4, y + 5, x + 11, y + 6, BG);
    gfx.rect(s, x + 4, y + 8, x + 11, y + 9, BG);
    gfx.rect(s, x + 4, y + 11, x + 9, y + 12, BG);
};

def draw(s: gfx.Surf) -> void {
    if (!is_open) { return; };
    if (ex >= gfx.clip_x1 || ex + ew <= gfx.clip_x0 || ey >= gfx.clip_y1 || ey + eh <= gfx.clip_y0) { return; };
    gfx.rect(s, ex, ey, ex + ew, ey + eh, BG);
    gfx.rect(s, ex, ey, ex + ew, ey + TITLEH, BAR);
    gfx.rect(s, ex, ey + eh - 1, ex + ew, ey + eh, EDGE);
    gfx.rect(s, ex, ey, ex + 1, ey + eh, EDGE);
    gfx.rect(s, ex + ew - 1, ey, ex + ew, ey + eh, EDGE);
    gfx.text(s, ex + 14, ey + 8, "Files", 1, TXT);
    gfx.text(s, ex + ew - 26, ey + 8, "x", 1, DIM);
    // toolbar
    gfx.rect(s, ex, ey + TITLEH, ex + ew, ey + TITLEH + BARH, 0xFF161B27);
    let i = 0;
    while (i < nbtn()) { button(s, i); i = i + 1; };
    // the path
    let py = ey + TITLEH + BARH;
    gfx.rect(s, ex, py, ex + ew, py + PATHH, 0xFF10141C);
    gfx.text(s, ex + 14, py + 6, path, 1, DIM);
    let cnt = tostring(len(names)) + " items";
    gfx.text(s, ex + ew - 14 - len(cnt) * 8, py + 6, cnt, 1, DIM);
    // the entries
    let ly = list_y();
    let r = 0;
    while (r < rows()) {
        let k = top + r;
        let ry = ly + r * ROWH;
        if (k < len(names)) {
            if (k == hover) { gfx.rect(s, ex + 1, ry, ex + ew - 1, ry + ROWH, HOT); };
            if (kinds[k] == 4) { draw_folder(s, ex + 16, ry + 4); } else { draw_file(s, ex + 16, ry + 4); };
            gfx.text(s, ex + 44, ry + 4, names[k], 1, if (kinds[k] == 4) { FOLDER } else { TXT });
            let right = if (kinds[k] == 4) { "folder" } else { size_str(sizes[k]) };
            gfx.text(s, ex + ew - 16 - len(right) * 8, ry + 4, right, 1, DIM);
        };
        r = r + 1;
    };
    if (len(names) == 0) { gfx.text(s, ex + 44, ly + 4, "(empty)", 1, DIM); };
    // a scroll thumb when the list is longer than the panel
    if (len(names) > rows()) {
        let th = gfx.max(rows() * rows() * ROWH / len(names), 16);
        let travel = rows() * ROWH - th;
        let ty = ly + travel * top / gfx.max(len(names) - rows(), 1);
        gfx.rect(s, ex + ew - 6, ty, ex + ew - 2, ty + th, 0xFF4B5A78);
    };
    // the footer: the name being typed, or the last message
    let fy = ey + eh - FOOTH;
    gfx.rect(s, ex, fy, ex + ew, ey + eh - 1, 0xFF161B27);
    if (mode != 0) {
        let label = if (mode == 1) { "New folder: " } else { "New file: " };
        gfx.text(s, ex + 14, fy + 9, label, 1, DIM);
        let fx = ex + 14 + len(label) * 8;
        gfx.rect(s, fx - 4, fy + 5, fx + 48 * 8 + 4, fy + FOOTH - 5, 0xFF0B0E14);
        gfx.text(s, fx, fy + 9, field, 1, TXT);
        gfx.rect(s, fx + len(field) * 8, fy + 8, fx + len(field) * 8 + 2, fy + 26, TXT);
        gfx.text(s, ex + ew - 14 - 26 * 8, fy + 9, "Enter creates, Esc cancels", 1, DIM);
    } else if (msg != "") {
        gfx.text(s, ex + 14, fy + 9, msg, 1, if (msg_bad) { BAD } else { GOOD });
    } else {
        gfx.text(s, ex + 14, fy + 9, "Click a folder to enter it, a file to edit it.", 1, DIM);
    };
};
