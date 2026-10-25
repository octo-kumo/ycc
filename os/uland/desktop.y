// desktop -- the Y-OS desktop: a wallpaper and a dock of every program in /bin.
//
// It runs in the background from init and does nothing until F1 or F12 shows its view (the kernel
// then queues keys, motion and clicks on /dev/input). The picture is composed in this process's
// own memory and sent to the display a rectangle at a time (/dev/fb0, fbdev.y), so a pointer
// move redraws a few hundred pixels, not the screen. The dock is a flat strip at the bottom: one
// drawn icon per program (icons.y), a lighter tile under the pointer, scrolling with the wheel, the
// arrow keys or a drag when there are more than fit. Everything is flat colour and whole pixels, and
// nothing animates: the icons are scaled once per layout onto the colour they sit on, so a frame is
// copies of rectangles, and the process sleeps until an event arrives. A click types the program's name into the
// shell and switches to the terminal, where it runs like any command; when it exits the shell shows
// this desktop again (`todesktop`), and F1 or F12 flips to the terminal and back by hand. The desktop is
// what the machine shows at boot.
//
// Two panels live in the desktop itself, not as programs: the file explorer (the "files" icon in the
// dock, fexp.y) and the resource monitor (F3, kmon.y; it samples the kernel twice a second).
//
// The display may be resized by the host while this runs: the kernel queues a type-32 event, and once
// the batch of events is read the buffers and the wallpaper (the generated weave and the vector
// character, vec.y) are rebuilt for the new size. The wallpaper is a cached surface: a redraw copies the
// dirty rectangle out of it, nothing is re-rendered per frame.
import ulib;
import gfx;
import icons;
import vec;
import kmon;
import fexp;

const FB_INFO = 17920;
const FB_BLIT = 17921;
const FB_VIEW = 17922;
const FB_TYPE = 17923;

const EV_KEY = 1;
const EV_REL = 2;
const EV_ABS = 3;
const EV_DISPLAY = 32;
const BTN_LEFT = 272;
const KEY_LEFT = 105;
const KEY_RIGHT = 106;
const KEY_HOME = 102;
const KEY_END = 107;
const KEY_ESC = 1;
const KEY_F3 = 61;
const KEY_LSHIFT = 42;
const KEY_RSHIFT = 54;
const STAT_MS = 500;
const MON_X = 20;
const MON_Y = 20;

// display
let fbfd = 0 - 1;
let infd = 0 - 1;
let sw = 0;
let sh = 0;
let gen = 0;
let back: gfx.Surf = gfx.surf_new(1, 1);
let wall: gfx.Surf = gfx.surf_new(1, 1);

// scratch memory for syscalls
let abuf = 0;
let pbuf = 0;
let ebuf = 0;
let cbuf = 0;

// the dock's content
let names: [str] = [];
let ics: [gfx.Surf] = [];
// the icons at the dock's size, flattened onto the plate colour and onto the hover colour
let flat: [gfx.Surf] = [];
let lit: [gfx.Surf] = [];
const PLATE = 0x262B36;
const TILE = 0x434B5E;

// dock geometry (layout())
let isz = 64;
let gap = 12;
let pad = 16;
let plate_x = 0;
let plate_y = 0;
let plate_w = 0;
let plate_h = 0;
let in_x0 = 0;
let in_x1 = 0;
let content_w = 0;
let scroll = 0;

// pointer
let px = 0;
let py = 0;
let down = false;
let down_x = 0;
let down_scroll = 0;
let dragged = false;
let hover = 0 - 1;
let shift_l = false;
let shift_r = false;
// the resource monitor: shown, and when it was last sampled (clock_us)
let mon_on = false;
let mon_next = 0;
// a press the explorer took: its release is not the dock's
let swallowed = false;

// the display changed size: rebuild the wallpaper and the layout once the events are read
let resized = false;

// what needs redrawing
let dx0 = 0;
let dy0 = 0;
let dx1 = 0;
let dy1 = 0;
let dirty = false;

def dirty_add(x0: long, y0: long, x1: long, y1: long) -> void {
    x0 = gfx.max(x0, 0);
    y0 = gfx.max(y0, 0);
    x1 = gfx.min(x1, sw);
    y1 = gfx.min(y1, sh);
    if (x1 <= x0 || y1 <= y0) { return; };
    if (!dirty) {
        dx0 = x0;
        dy0 = y0;
        dx1 = x1;
        dy1 = y1;
        dirty = true;
    } else {
        dx0 = gfx.min(dx0, x0);
        dy0 = gfx.min(dy0, y0);
        dx1 = gfx.max(dx1, x1);
        dy1 = gfx.max(dy1, y1);
    };
};

def dirty_dock() -> void {
    dirty_add(plate_x - 120, plate_y - 36, plate_x + plate_w + 120, plate_y + plate_h);
};

/** Redraw the slot of icon `i` and the name above it. */
def dirty_icon(i: long) -> void {
    if (i < 0) { return; };
    dirty_add(icon_cx(i) - 130, plate_y - 36, icon_cx(i) + 130, plate_y + plate_h);
};

def w64(a: long, i: long, v: long) -> void {
    let q: *long = ptr_from(a);
    *(q + i) = v;
};

def r64(a: long, i: long) -> long {
    let q: *long = ptr_from(a);
    *(q + i)
};

// ── the wallpaper ───────────────────────────────────────────────────────

embed WALL from "../assets/wallpaper.yvg";

/** The carbon-fibre weave, generated: a 2x2 twill of 4-pixel tows, each lit across its width like a
cylinder, with the fine fibres along its length and the tow underneath in shadow. */
def carbon(x: long, y: long) -> long {
    let cx = x >> 2;
    let cy = y >> 2;
    let u = x & 3;
    let v = y & 3;
    // twill: in each row of cells the tow that is on top moves over by one
    let warp = ((cx + cy) & 3) < 2;
    let t = if (warp) { u } else { v };
    let along = if (warp) { v } else { u };
    let lit = if (t == 1 || t == 2) { 7 } else { 0 };
    let fibre = if (((if (warp) { x } else { y }) & 1) == 0) { 1 } else { 0 };
    // the tow's first and last rows along its length dip under its crossing neighbour
    let dip = if (along == 0 || along == 3) { 2 } else { 0 };
    let v0 = 17 + lit + fibre - dip;
    if (warp) { gfx.rgb(v0, v0 + 1, v0 + 5) } else { gfx.rgb(v0 - 2, v0 - 1, v0 + 2) }
};

/** Build the wallpaper for the current size, once: the carbon weave with a soft light from the
middle, the vector character on top (as large as the screen is high, centred). The result is the
cache every redraw copies from; it is rebuilt only when the display changes size. */
def build_wall() -> void {
    gfx.surf_free(wall);
    wall = gfx.surf_new(sw, sh);
    let hw = sw / 2;
    let hh = sh / 2;
    let y = 0;
    while (y < sh) {
        let ry = (y - hh) * 256 / hh;
        let x = 0;
        while (x < sw) {
            let rx = (x - hw) * 256 / hw;
            // 0 in the middle .. 256 at the corners of the screen
            let d = gfx.min((rx * rx + ry * ry) >> 8, 512);
            let c = carbon(x, y);
            let k = 256 + 80 - d * 160 / 512;
            let r = (((c >> 16) & 255) * k) >> 8;
            let g = (((c >> 8) & 255) * k) >> 8;
            let b = ((c & 255) * k) >> 8;
            gfx.put(wall, x, y, gfx.rgb(r, g, b));
            x = x + 1;
        };
        y = y + 1;
    };
    let size = gfx.min(sw, sh);
    vec.draw(wall, WALL, (sw - size) / 2, (sh - size) / 2, size);
};

// ── the dock ────────────────────────────────────────────────────────────

/** The programs a dock does not list: the command-line tools, the system's own and the test programs. */
let hidden: [str] = ["init", "sh", "ls", "cat", "echo", "mkdir", "rmdir", "rm", "cp", "mv", "touch", "wc",
    "head", "tail", "pwd", "stat", "env", "clear", "sleep", "uname", "write", "stty", "pulsed", "desktop",
    "mousedemo", "osstat", "sktest", "pulsetest", "segv", "ttyt", "fstest", "b1", "b2time", "b2mm", "b2thr", "bigdata", "sndtone", "beep", "halt"];

def is_hidden(name: str) -> bool {
    let i = 0;
    while (i < len(hidden)) {
        if (hidden[i] == name) { return true; };
        i = i + 1;
    };
    // t341, t385, ...: the kernel's test programs
    if (len(name) >= 2 && name[0] == 116 && name[1] >= 48 && name[1] <= 57) { return true; };
    false
};

/** What to type for `name`: a few programs need a file to open to show anything. */
def command_of(name: str) -> str {
    if (name == "editor") { return "editor /usr/share/editor/demo.txt"; };
    if (name == "toolkit-cli") { return "toolkit-cli version"; };
    if (name == "bignum") { return "bignum calc 2+3*4"; };
    name
};

/** Find the programs and draw their icons. */
def load_items() -> void {
    let found: [str] = [];
    let ents = ulib.read_dir("/bin");
    if (ents != none) {
        foreach (e in ents!) {
            if (e.kind != 4 && !is_hidden(e.name) && e.name != "." && e.name != "..") { found += e.name; };
        };
    };
    // alphabetical, the terminal first
    let i = 1;
    while (i < len(found)) {
        let j = i;
        while (j > 0 && found[j - 1] > found[j]) {
            let t = found[j];
            found[j] = found[j - 1];
            found[j - 1] = t;
            j = j - 1;
        };
        i = i + 1;
    };
    names = ["terminal", "files"] + found;
    if (ulib.exists("/bin/halt")) { names += "halt"; };
    foreach (n in names) {
        let s = gfx.surf_new(icons.IS, icons.IS);
        icons.icon_draw(n, s);
        ics += s;
    };
};

/** The icons at the dock's size, once per layout: onto the plate colour and onto the hover tile. */
def build_icons() -> void {
    foreach (s in flat) { gfx.surf_free(s); };
    foreach (s in lit) { gfx.surf_free(s); };
    flat = [];
    lit = [];
    gfx.target_argb = false;
    foreach (src in ics) {
        let a = gfx.surf_new(isz, isz);
        gfx.fill(a, PLATE);
        gfx.clip_to(a);
        gfx.blit_scaled(a, src, 0, 0, isz);
        flat += a;
        let b = gfx.surf_new(isz, isz);
        gfx.fill(b, TILE);
        gfx.clip_to(b);
        gfx.blit_scaled(b, src, 0, 0, isz);
        lit += b;
    };
};

/** Where the dock sits for this screen size. */
def layout() -> void {
    isz = gfx.clamp(sh / 12, 44, 88);
    gap = isz / 5;
    pad = isz / 4;
    let n = len(names);
    content_w = n * isz + (n - 1) * gap;
    let avail = gfx.min(content_w, sw * 85 / 100 - 2 * pad);
    plate_w = avail + 2 * pad;
    plate_h = isz + 2 * pad;
    plate_x = (sw - plate_w) / 2;
    plate_y = sh - plate_h - isz / 3;
    in_x0 = plate_x + pad;
    in_x1 = in_x0 + avail;
    scroll = gfx.clamp(scroll, 0, gfx.max(content_w - avail, 0));
    fexp.layout(sw, plate_y);
};

def scroll_max() -> long { gfx.max(content_w - (in_x1 - in_x0), 0) };

/** Icon `i`: its centre x and its left/top. */
def icon_cx(i: long) -> long { in_x0 + i * (isz + gap) + isz / 2 - scroll };
def icon_left(i: long) -> long { icon_cx(i) - isz / 2 };
def icon_top(i: long) -> long { plate_y + pad };

/** The icon whose slot holds the pointer, or -1. */
def icon_at(x: long, y: long) -> long {
    if (y < plate_y || y >= plate_y + plate_h || x < in_x0 - pad / 2 || x >= in_x1 + pad / 2) { return 0 - 1; };
    let i = (x - in_x0 + scroll + gap / 2) / (isz + gap);
    if (x - in_x0 + scroll + gap / 2 < 0 || i >= len(names)) { return 0 - 1; };
    i
};

def draw_dock() -> void {
    if (gfx.clip_y1 <= plate_y - 24 || gfx.clip_x1 <= plate_x - 120 || gfx.clip_x0 >= plate_x + plate_w + 120) { return; };
    gfx.fill_round(back, plate_x, plate_y, plate_x + plate_w, plate_y + plate_h, isz / 4, PLATE);
    // the icons stay inside the plate's strip
    let ox0 = gfx.clip_x0;
    let ox1 = gfx.clip_x1;
    gfx.clip_set(gfx.max(ox0, in_x0 - pad / 2), gfx.clip_y0, gfx.min(ox1, in_x1 + pad / 2), gfx.clip_y1);
    let i = 0;
    while (i < len(names)) {
        let l = icon_left(i);
        if (l + isz > gfx.clip_x0 && l < gfx.clip_x1) {
            if (i == hover && !down) { gfx.copy_to(back, lit[i], l, icon_top(i)); } else { gfx.copy_to(back, flat[i], l, icon_top(i)); };
        };
        i = i + 1;
    };
    gfx.clip_set(ox0, gfx.clip_y0, ox1, gfx.clip_y1);
    // there is more to scroll to: an arrow at that end
    let cy = plate_y + plate_h / 2;
    let ax = plate_x + pad / 2;
    if (scroll > 0) { gfx.tri(back, gfx.f(ax + 5), gfx.f(cy - 8), gfx.f(ax + 5), gfx.f(cy + 8), gfx.f(ax - 4), gfx.f(cy), 0xFFFFFFFF); };
    ax = plate_x + plate_w - pad / 2;
    if (scroll < scroll_max()) { gfx.tri(back, gfx.f(ax - 5), gfx.f(cy - 8), gfx.f(ax - 5), gfx.f(cy + 8), gfx.f(ax + 4), gfx.f(cy), 0xFFFFFFFF); };
    // the name of the program under the pointer
    if (hover >= 0 && !down) {
        let label = names[hover];
        let tw = gfx.text_width(label, 1) + 20;
        let tx = gfx.clamp(icon_cx(hover) - tw / 2, 6, sw - tw - 6);
        let ty = plate_y - 34;
        gfx.rect(back, tx, ty, tx + tw, ty + 26, 0xFF121418);
        gfx.text(back, tx + 10, ty + 5, label, 1, 0xFFF1F5F9);
    };
};

/** The mouse arrow: 12 x 19, '#' black, '.' white. */
let arrow: [str] = [
    "#",
    "##",
    "#.#",
    "#..#",
    "#...#",
    "#....#",
    "#.....#",
    "#......#",
    "#.......#",
    "#........#",
    "#.........#",
    "#..........#",
    "#......#####",
    "#...#..#",
    "#..# #..#",
    "#.#  #..#",
    "##    #..#",
    "#     #..#",
    "       ##"];

def draw_cursor() -> void {
    let y = 0;
    while (y < len(arrow)) {
        let row = arrow[y];
        let x = 0;
        while (x < len(row)) {
            let c = row[x];
            let ax = px + x;
            let ay = py + y;
            if ((c == 35 || c == 46) && ax >= gfx.clip_x0 && ax < gfx.clip_x1 && ay >= gfx.clip_y0 && ay < gfx.clip_y1) {
                gfx.put(back, ax, ay, if (c == 35) { 0x000000 } else { 0xFFFFFF });
            };
            x = x + 1;
        };
        y = y + 1;
    };
};

/** Send the rectangle to the display. */
def blit(x0: long, y0: long, x1: long, y1: long) -> void {
    w64(abuf, 0, back.p);
    w64(abuf, 1, sw * 4);
    w64(abuf, 2, x0);
    w64(abuf, 3, y0);
    w64(abuf, 4, x1 - x0);
    w64(abuf, 5, y1 - y0);
    syscall(16, fbfd, FB_BLIT, abuf);
};

/** Redraw what is dirty: wallpaper underneath, then the dock, then the pointer. */
def render() -> void {
    if (!dirty) { return; };
    dirty = false;
    gfx.target_argb = false;
    gfx.clip_set(dx0, dy0, dx1, dy1);
    gfx.copy_rect(back, wall, dx0, dy0, dx1, dy1);
    draw_dock();
    if (mon_on) { kmon.draw(back, MON_X, MON_Y, sw - 2 * MON_X, mon_h()); };
    fexp.draw(back);
    draw_cursor();
    blit(dx0, dy0, dx1, dy1);
};

def mon_h() -> long { gfx.min(gfx.max(plate_y - 64, 300), sh - 2 * MON_Y) };

def dirty_mon() -> void { dirty_add(MON_X, MON_Y, sw - MON_X, MON_Y + mon_h()); };

def dirty_files() -> void { dirty_add(fexp.ex, fexp.ey, fexp.ex + fexp.ew, fexp.ey + fexp.eh); };

/** The explorer asked for a program to run (a file to edit). */
def files_done() -> void {
    dirty_files();
    let c = fexp.take_cmd();
    if (c != "") { run(c); };
};

/** F3: show or hide the monitor; showing it takes a sample at once. */
def toggle_mon() -> void {
    mon_on = !mon_on;
    if (mon_on) {
        kmon.sample();
        mon_next = clock_us() + STAT_MS * 1000;
    };
    dirty_mon();
};

/** The cursor's box, for the dirty rectangle. */
def dirty_cursor() -> void { dirty_add(px, py, px + 13, py + 20); };

// ── the display ─────────────────────────────────────────────────────────

/** Ask the kernel for the display's size; true when it is not what we have. */
def read_info() -> bool {
    if (syscall(16, fbfd, FB_INFO, abuf) != 0) { return false; };
    let w = r64(abuf, 0);
    let h = r64(abuf, 1);
    let g = r64(abuf, 4);
    if (w == sw && h == sh && g == gen) { return false; };
    sw = w;
    sh = h;
    gen = g;
    true
};

def rebuild() -> void {
    gfx.surf_free(back);
    back = gfx.surf_new(sw, sh);
    px = gfx.clamp(px, 0, sw - 1);
    py = gfx.clamp(py, 0, sh - 1);
    layout();
    build_icons();
    build_wall();
    dirty = false;
    dirty_add(0, 0, sw, sh);
};

// ── input ───────────────────────────────────────────────────────────────

/** Type `name`'s command into the shell and show the terminal (or just show it, for the terminal). */
def launch(name: str) -> void {
    if (name == "terminal") {
        syscall(16, fbfd, FB_VIEW, 0);
        return;
    };
    if (name == "files") {
        fexp.toggle("/home/user");
        dirty_add(0, 0, sw, sh);
        return;
    };
    run(command_of(name));
};

/** Type `cmd` into the shell, followed by `todesktop` so the desktop comes back when it ends. */
def run(command: str) -> void {
    let cmd = command + "; todesktop";
    let i = 0;
    while (i < len(cmd)) {
        let q: *i8 = ptr_from(cbuf + i);
        *q = cmd[i];
        i = i + 1;
    };
    let q: *i8 = ptr_from(cbuf + i);
    *q = 10;
    w64(abuf, 0, cbuf);
    w64(abuf, 1, i + 1);
    syscall(16, fbfd, FB_TYPE, abuf);
};

def scroll_by(d: long) -> void {
    scroll = gfx.clamp(scroll + d, 0, scroll_max());
    hover = icon_at(px, py);
};

def on_button(pressed: bool) -> void {
    if (pressed && fexp.inside(px, py)) {
        swallowed = true;
        fexp.click(px, py);
        files_done();
        return;
    };
    if (!pressed && swallowed) {
        swallowed = false;
        return;
    };
    if (pressed) {
        down = true;
        dragged = false;
        dirty_icon(hover);
        down_x = px;
        down_scroll = scroll;
        return;
    };
    let was = down;
    down = false;
    if (was && !dragged) {
        let i = icon_at(px, py);
        if (i >= 0) { launch(names[i]); };
    };
    dirty_icon(hover);
};

def on_move() -> void {
    if (down) {
        if (gfx.abs(px - down_x) > 6) { dragged = true; };
        if (dragged && scroll_max() > 0) {
            scroll = gfx.clamp(down_scroll - (px - down_x), 0, scroll_max());
            dirty_dock();
        };
    };
    if (fexp.is_open && fexp.hover_at(px, py)) { dirty_files(); };
    let h = icon_at(px, py);
    if (h != hover) {
        dirty_icon(hover);
        hover = h;
        dirty_icon(hover);
    };
};

/** One event: type, code, value. */
def on_event(ty: long, code: long, value: long) -> void {
    if (ty == EV_REL) {
        dirty_cursor();
        if (code == 0) { px = gfx.clamp(px + value, 0, sw - 1); on_move(); }
        else if (code == 1) { py = gfx.clamp(py + value, 0, sh - 1); on_move(); }
        else if (code == 8 && fexp.inside(px, py)) { fexp.wheel(value * (0 - 3)); dirty_files(); }
        else if (code == 8) { scroll_by(value * (isz + gap) * 3 / 2 * (0 - 1)); dirty_dock(); }
        else if (code == 6) { scroll_by(value * (isz + gap) * 3 / 2); dirty_dock(); };
        dirty_cursor();
    } else if (ty == EV_ABS) {
        dirty_cursor();
        if (code == 0) { px = gfx.clamp(value * sw / 32768, 0, sw - 1); on_move(); }
        else if (code == 1) { py = gfx.clamp(value * sh / 32768, 0, sh - 1); on_move(); };
        dirty_cursor();
    } else if (ty == EV_KEY) {
        if (code == KEY_LSHIFT) { shift_l = value != 0; }
        else if (code == KEY_RSHIFT) { shift_r = value != 0; }
        else if (code == BTN_LEFT) { on_button(value != 0); }
        else if (value == 1 && code == KEY_F3) { toggle_mon(); }
        else if (value != 0 && fexp.is_open) {
            fexp.key(code, shift_l || shift_r);
            files_done();
            dirty_add(0, 0, sw, sh);
        }
        else if (value == 1 && code == KEY_ESC && mon_on) { toggle_mon(); }
        else if (value != 0 && code == KEY_LEFT) { scroll_by(0 - (isz + gap)); dirty_dock(); }
        else if (value != 0 && code == KEY_RIGHT) { scroll_by(isz + gap); dirty_dock(); }
        else if (value != 0 && code == KEY_HOME) { scroll = 0; dirty_dock(); }
        else if (value != 0 && code == KEY_END) { scroll = scroll_max(); dirty_dock(); };
    } else if (ty == EV_DISPLAY) {
        // a resize arrives as a burst: rebuild once, after the batch
        resized = true;
    };
};

// ── main ────────────────────────────────────────────────────────────────
fbfd = ulib.open("/dev/fb0", 2);
if (fbfd < 0) { exit(0); };
infd = ulib.open("/dev/input", 2048);
if (infd < 0) { exit(0); };
abuf = gfx.alloc(4096);
pbuf = gfx.alloc(4096);
ebuf = gfx.alloc(65536);
cbuf = gfx.alloc(4096);
if (abuf == 0 || pbuf == 0 || ebuf == 0 || cbuf == 0) { exit(1); };
gfx.init();
kmon.init(fbfd);
read_info();
px = sw / 2;
py = sh / 2;
load_items();
rebuild();
render();
// the desktop is what the machine shows first
syscall(16, fbfd, FB_VIEW, 1);

while (true) {
    w64(pbuf, 0, infd | (1 << 32));
    let wait = 0 - 1;
    if (mon_on) { wait = gfx.max((mon_next - clock_us()) / 1000, 1); };
    syscall(7, pbuf, 1, wait);
    if (mon_on && clock_us() >= mon_next) {
        kmon.sample();
        mon_next = gfx.max(mon_next + STAT_MS * 1000, clock_us() + STAT_MS * 500);
        dirty_mon();
    };
    let n = syscall(0, infd, ebuf, 65536);
    let k = 0;
    while (n >= 16 && k + 16 <= n) {
        let w0 = r64(ebuf, k / 8);
        on_event(w0 & 65535, (w0 >> 16) & 65535, w0 >> 32);
        k = k + 16;
    };
    if (resized) {
        resized = false;
        if (read_info()) { rebuild(); } else { dirty_add(0, 0, sw, sh); };
    };
    render();
};
