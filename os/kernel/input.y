// input -- every key, button and motion the machine receives.
//
// Devices (kbd.y: PS/2; virtio-input) report Linux evdev events: type, code and
// value, with the Linux codes (EV_KEY KEY_A.., BTN_LEFT; EV_REL REL_X; EV_ABS
// ABS_X with the range 0..32767), so a source needs no translation of its own.
// `input_event` is the one entry point:
//
//   F1, F12        toggle the view (console.y), and is never passed on;
//   TEXT view      a key press is typed into the tty (US layout, Shift, Caps
//                  Lock, Ctrl, Alt as a prefix, the cursor block as xterm
//                  sequences); the pointer is a block on the terminal's cell grid,
//                  and a program that asked for mouse reports (vt.y) gets them as
//                  xterm sequences; otherwise the wheel scrolls (the scrollback, or
//                  the cursor keys on the alternate screen);
//   GUI view       every event is queued for /dev/input.
//
// The queue is 16-byte records, little endian: u16 type, u16 code, i32 value,
// u64 time in microseconds.
import kernel;
import console from "./console.y";
import time from "./time.y";
import tty from "./tty.y";
import vt from "./vt.y";
import kconst from "./kconst.y";
import fdt from "./fdt.y";
import kstat from "./kstat.y";

const EV_SYN = 0;
const EV_KEY = 1;
const EV_REL = 2;
const EV_ABS = 3;

const KEY_LEFTCTRL = 29;
const KEY_LEFTSHIFT = 42;
const KEY_RIGHTSHIFT = 54;
const KEY_LEFTALT = 56;
const KEY_CAPSLOCK = 58;
const KEY_F1 = 59;
const KEY_F12 = 88;
const KEY_RIGHTCTRL = 97;
const KEY_RIGHTALT = 100;

const IN_EVENTS = 1024;

let in_q: [long; 2048] = [0; 2048];
let in_head = 0;
let in_tail = 0;
let in_dropped = 0;

let in_norm: [byte; 128] = [0; 128];
let in_shift: [byte; 128] = [0; 128];
let in_nshift = 0;
let in_nctrl = 0;
let in_nalt = 0;
let in_caps = false;

// the pointer in the TEXT view: pixel position, the buttons held (bit 0 left, 1 middle, 2 right)
let in_px = 0;
let in_py = 0;
let in_btn = 0;
let in_cell = 0 - 1;

/** Fill the layout tables: the keys of `normal` and `shifted` from code `start` on. */
def input_row(start: long, normal: str, shifted: str) -> void {
    let i = 0;
    while (i < len(normal)) {
        in_norm[start + i] = normal[i];
        in_shift[start + i] = shifted[i];
        i = i + 1;
    };
};

/** Boot: the US layout. */
def input_init() -> void {
    input_row(2, "1234567890-=", "!@#$%^&*()_+");
    input_row(16, "qwertyuiop[]", "QWERTYUIOP{}");
    input_row(30, "asdfghjkl;'`", "ASDFGHJKL:\"~");
    input_row(43, "\\zxcvbnm,./", "|ZXCVBNM<>?");
    input_row(57, " ", " ");
    input_row(71, "789-456+1230.", "789-456+1230.");
    input_row(55, "*", "*");
    input_row(98, "/", "/");
    in_norm[1] = 27;
    in_shift[1] = 27;
    in_norm[14] = 127;
    in_shift[14] = 127;
    in_norm[15] = 9;
    in_shift[15] = 9;
    in_norm[28] = 13;
    in_shift[28] = 13;
    in_norm[96] = 13;
    in_shift[96] = 13;
};

/** Queue one event for /dev/input (the oldest is dropped when the queue is full). */
def input_push(ty: long, code: long, value: long) -> void {
    if (in_tail - in_head >= IN_EVENTS) {
        in_head = in_head + 1;
        in_dropped = in_dropped + 1;
    };
    let i = (in_tail % IN_EVENTS) * 2;
    in_q[i] = ty | (code << 16) | ((value & 4294967295) << 32);
    in_q[i + 1] = time.now_us();
    in_tail = in_tail + 1;
    fdt.fdt_notify(kconst.INPUT, 0);
};

def input_pending() -> long { in_tail - in_head };

/** Word `k` (0: type/code/value, 1: time) of the oldest queued event. */
def input_head_word(k: long) -> long { in_q[(in_head % IN_EVENTS) * 2 + k] };

/** Discard the oldest event. */
def input_drop() -> void {
    if (in_head < in_tail) { in_head = in_head + 1; };
};

/** Drop everything queued (the GUI starts from a clean slate). */
def input_flush() -> void { in_head = in_tail; };

def input_type(w: long) -> long { w & 65535 };
def input_code(w: long) -> long { (w >> 16) & 65535 };

/** The tty bytes of the keys that are not characters: a cursor key, F1..F12, ... */
def input_seq(code: long) -> str {
    let esc = chr(27);
    if (code == 103) { return esc + "[A"; };
    if (code == 108) { return esc + "[B"; };
    if (code == 106) { return esc + "[C"; };
    if (code == 105) { return esc + "[D"; };
    if (code == 102) { return esc + "[H"; };
    if (code == 107) { return esc + "[F"; };
    if (code == 110) { return esc + "[2~"; };
    if (code == 111) { return esc + "[3~"; };
    if (code == 104) { return esc + "[5~"; };
    if (code == 109) { return esc + "[6~"; };
    if (code >= 59 && code <= 62) { return esc + "O" + chr(80 + code - 59); };
    if (code == 63) { return esc + "[15~"; };
    if (code == 64) { return esc + "[17~"; };
    if (code == 65) { return esc + "[18~"; };
    if (code == 66) { return esc + "[19~"; };
    if (code == 67) { return esc + "[20~"; };
    if (code == 68) { return esc + "[21~"; };
    if (code == 87) { return esc + "[23~"; };
    ""
};

/** One byte typed into the tty as if from the keyboard. */
def input_type_byte(b: long) -> void { tty.tty_input(b); };

/** Type `s` into the tty. */
def input_type_str(s: str) -> void {
    let i = 0;
    while (i < len(s)) {
        tty.tty_input(s[i]);
        i = i + 1;
    };
};

/** A key went down in the TEXT view: type what it means. */
def input_key_tty(code: long) -> void {
    // Shift+PageUp / PageDown look through the scrollback; any other key goes back to the live screen
    if (in_nshift > 0 && (code == 104 || code == 109)) {
        let page = vt.vt_get_rows() / 2;
        if (code == 104) { vt.vt_scrollback(page); } else { vt.vt_scrollback(0 - page); };
        return;
    };
    vt.vt_live();
    let c = 0;
    if (code < 128) {
        if (in_nshift > 0) { c = in_shift[code]; } else { c = in_norm[code]; };
    };
    if (c == 0) {
        input_type_str(input_seq(code));
        return;
    };
    let letter = (c >= 97 && c <= 122) || (c >= 65 && c <= 90);
    if (in_caps && letter) {
        if (c >= 97) { c = c - 32; } else { c = c + 32; };
    };
    if (in_nctrl > 0) {
        if (c == 32) { c = 0; }
        else if (c >= 64 && c <= 127) { c = c & 31; }
        else if (c == 63) { c = 127; };
    };
    if (in_nalt > 0) { tty.tty_input(27); };
    tty.tty_input(c);
};

/** The modifier keys' state follows every key event, in either view. */
def input_track(code: long, down: bool) -> void {
    let d = 0;
    if (down) { d = 1; };
    if (code == KEY_LEFTSHIFT || code == KEY_RIGHTSHIFT) {
        if (down) { in_nshift = in_nshift + 1; } else if (in_nshift > 0) { in_nshift = in_nshift - 1; };
    } else if (code == KEY_LEFTCTRL || code == KEY_RIGHTCTRL) {
        if (down) { in_nctrl = in_nctrl + 1; } else if (in_nctrl > 0) { in_nctrl = in_nctrl - 1; };
    } else if (code == KEY_LEFTALT || code == KEY_RIGHTALT) {
        if (down) { in_nalt = in_nalt + 1; } else if (in_nalt > 0) { in_nalt = in_nalt - 1; };
    } else if (code == KEY_CAPSLOCK && d == 1) {
        in_caps = !in_caps;
    };
};

/** One mouse report to the program: button code `b` (xterm's numbering) at the pointer's cell. */
def input_mouse_report(b: long, press: bool) -> void {
    if (in_nshift > 0) { b = b + 4; };
    if (in_nalt > 0) { b = b + 8; };
    if (in_nctrl > 0) { b = b + 16; };
    let col = in_px / 8 + 1;
    let row = in_py / 16 + 1;
    if (vt.vt_mouse_sgr()) {
        let end = "M";
        if (!press) { end = "m"; };
        input_type_str(chr(27) + "[<" + tostring(b) + ";" + tostring(col) + ";" + tostring(row) + end);
    } else {
        if (!press) { b = (b & 60) + 3; };
        if (col > 223) { col = 223; };
        if (row > 223) { row = 223; };
        input_type_str(chr(27) + "[M" + chr(32 + b) + chr(32 + col) + chr(32 + row));
    };
};

/** The pointer moved to pixel (x, y) in the TEXT view. */
def input_point(x: long, y: long) -> void {
    let w = vt.vt_get_cols() * 8;
    let h = vt.vt_get_rows() * 16;
    if (x < 0) { x = 0; };
    if (y < 0) { y = 0; };
    if (x >= w) { x = w - 1; };
    if (y >= h) { y = h - 1; };
    in_px = x;
    in_py = y;
    let cell = (y / 16) * 1024 + x / 8;
    if (cell == in_cell) { return; };
    in_cell = cell;
    vt.vt_set_pointer(y / 16, x / 8);
    let m = vt.vt_mouse_mode();
    if (m == 1003 || (m == 1002 && in_btn != 0)) {
        let b = 3;
        if ((in_btn & 1) != 0) { b = 0; } else if ((in_btn & 2) != 0) { b = 1; } else if ((in_btn & 4) != 0) { b = 2; };
        input_mouse_report(b + 32, true);
    };
};

/** A mouse button (Linux code `code`) changed in the TEXT view. */
def input_button(code: long, down: bool) -> void {
    let k = 0 - 1;
    if (code == 272) { k = 0; } else if (code == 274) { k = 1; } else if (code == 273) { k = 2; };
    if (k < 0) { return; };
    if (down) { in_btn = in_btn | (1 << k); } else { in_btn = in_btn & ~(1 << k); };
    if (vt.vt_mouse_mode() != 0) { input_mouse_report(k, down); };
};

/** The wheel turned in the TEXT view (positive: up, away from the user). */
def input_wheel(v: long) -> void {
    if (vt.vt_mouse_mode() != 0) {
        if (v > 0) { input_mouse_report(64, true); } else { input_mouse_report(65, true); };
    } else if (vt.vt_in_alt()) {
        let esc = chr(27);
        let k = "[";
        if (vt.vt_get_appkeys()) { k = "O"; };
        let key = esc + k + "B";
        if (v > 0) { key = esc + k + "A"; };
        input_type_str(key + key + key);
    } else {
        vt.vt_scrollback(v * 3);
    };
};

/** A pointer event in the TEXT view. */
def input_pointer(ty: long, code: long, value: long) -> void {
    if (ty == EV_REL) {
        if (code == 0) { input_point(in_px + value, in_py); }
        else if (code == 1) { input_point(in_px, in_py + value); }
        else if (code == 8) { input_wheel(value); };
    } else if (ty == EV_ABS) {
        if (code == 0) { input_point(value * vt.vt_get_cols() * 8 / 32768, in_py); }
        else if (code == 1) { input_point(in_px, value * vt.vt_get_rows() * 16 / 32768); };
    } else if (ty == EV_KEY && code >= 272 && code <= 274) {
        input_button(code, value != 0);
    };
};

/** One event from a device (see the header). */
def input_event(ty: long, code: long, value: long) -> void {
    kstat.kstat_input();
    if (ty == EV_KEY) {
        input_track(code, value != 0);
        if (code == KEY_F12 || code == KEY_F1) {
            if (value == 1) { console.con_toggle(); };
            return;
        };
    };
    if (console.con_get_mode() == console.CON_TEXT) {
        if (ty == EV_KEY && value != 0 && code < 256) { input_key_tty(code); }
        else { input_pointer(ty, code, value); };
        return;
    };
    input_push(ty, code, value);
};

/** Pseudo-events from the kernel itself: the display changed size (type 32, code 0). */
const EV_DISPLAY = 32;

def input_display_changed() -> void {
    input_push(EV_DISPLAY, 0, 0);
};
