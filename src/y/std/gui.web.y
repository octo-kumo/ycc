// std/gui.web.y -- gui on the web: the window is the page's
// canvas, and the JavaScript host owns it. Every call goes through the two
// host-call OS names (arch/web.s): y_os_host_sym resolves "gui.open" and its
// eight siblings once, and y_os_host_call passes a block of i64 arguments.
//
// A web Window is the base Window plus the host's window id (0 for none). The
// host writes events as five i64s each -- kind, a, b, c, d, the gui Event
// layout -- into WEB_EV, 128 at a time; web_pump turns them into gui events
// exactly as x_pump does (a resize replaces the pixels, a key updates the
// modifiers, a button updates the held-buttons mask, an expose repaints).
//
// The host functions, all arguments and results i64:
//
//   gui.open       w, h, title_ptr, title_len          -> id (0: no display)
//   gui.size       id                                  -> w | (h << 32)
//   gui.present    id, pix_ptr, pix_w, pix_h, x0, y0, x1, y1 -> 0
//   gui.poll       id, buf_ptr, cap                    -> events written
//   gui.wait       id, ms                              -> 1 when events are pending
//   gui.title      id, ptr, len                        -> 0
//   gui.resize     id, w, h                            -> 0 fixed, -1 fit
//   gui.close      id                                  -> 0
//   gui.read_back  id, dst_ptr, cap                    -> bytes copied
//
// New declarations land after the base's last line (S14), and a top-level
// let/const is visible only from there on, so the replaced functions below
// only delegate to these defs (hoisted); everything else, the host handles and
// the event buffer included, lives in the appended declarations.
const WEB = 5;

export { WEB };

// The superset Window: every base field, then the host's window id.
type Window = {
    backend: long,
    width: long, height: long,      // the client area in pixels
    scale: long,                    // pixels per font pixel (an integer, 1 or more)
    pixels: [byte],                 // width * height * 4 bytes (it may be longer)
    title: str,
    alive: bool,                    // false once closed or destroyed
    win32: Win32Info?, x11: X11Info?,
    evq: [long], evr: long, evw: long,
    dx0: long, dy0: long, dx1: long, dy1: long,   // what changed since the last present
    mods: long, buttons: long, mx: long, my: long, hi: long,
    web: long
};

// The only Window literal of the base adds the new field.
def new_window(backend: long, title: str, w: long, h: long) -> Window {
    let win: Window = {
        backend: backend, width: w, height: h, scale: 1, pixels: zeros(w * h * 4), title: title,
        alive: true, win32: none, x11: none,
        evq: long_array(EVQ * 5, 0), evr: 0, evw: 0,
        dx0: 0, dy0: 0, dx1: w, dy1: h, mods: 0, buttons: 0, mx: 0, my: 0, hi: 0, web: 0
    };
    win
};

const W_OPEN = 0;
const W_SIZE = 1;
const W_PRESENT = 2;
const W_POLL = 3;
const W_WAIT = 4;
const W_TITLE = 5;
const W_RESIZE = 6;
const W_CLOSE = 7;
const W_READ_BACK = 8;

let WEB_FN: [long; 9] = [0; 9];           // the host handles, resolved once
let WEB_EV: [long; 640] = [0; 640];       // 128 events of five i64
let WEB_ARG: [long; 8] = [0; 8];          // the argument block of a call
let WEB_READY = 0;                        // 0 not tried, 1 ready, -1 no host calls

def web_is(b: long) -> bool { b == WEB };

def web_sym(name: str) -> long {
    let b = cstr(name);
    os_call("y_os_host_sym", &b[0], b.length - 1)
};

def web_load(i: long, name: str) -> bool {
    WEB_FN[i] = web_sym(name);
    WEB_FN[i] != 0
};

// Resolve the nine host calls once; false when this target has no host calls
// (a native window never takes the web path).
def web_init() -> bool {
    if (WEB_READY != 0) { return WEB_READY > 0; };
    WEB_READY = -1;
    let ok = web_load(W_OPEN, "gui.open");
    ok = ok && web_load(W_SIZE, "gui.size");
    ok = ok && web_load(W_PRESENT, "gui.present");
    ok = ok && web_load(W_POLL, "gui.poll");
    ok = ok && web_load(W_WAIT, "gui.wait");
    ok = ok && web_load(W_TITLE, "gui.title");
    ok = ok && web_load(W_RESIZE, "gui.resize");
    ok = ok && web_load(W_CLOSE, "gui.close");
    ok = ok && web_load(W_READ_BACK, "gui.read_back");
    if (ok) { WEB_READY = 1; };
    ok
};

def web_call(i: long, n: long) -> long {
    os_call("y_os_host_call", WEB_FN[i], &WEB_ARG[0], n)
};

def web_open(title: str, cw: long, ch: long) -> Window? {
    if (!web_init()) { return none; };
    let t = cstr(title);
    WEB_ARG[0] = cw;
    WEB_ARG[1] = ch;
    WEB_ARG[2] = ptr_addr(&t[0]);
    WEB_ARG[3] = t.length - 1;
    let id = web_call(W_OPEN, 4);
    if (id <= 0) { return none; };
    // Fit mode: the page owns the client size.  Take it now, so a window that
    // the page stretched has its real pixels before the first resize event.
    let pw = cw;
    let ph = ch;
    WEB_ARG[0] = id;
    let sz = web_call(W_SIZE, 1);
    let aw = sz & 0xffffffff;
    let ah = (sz >> 32) & 0xffffffff;
    if (sz > 0 && aw > 0 && ah > 0) { pw = aw; ph = ah; };
    let w = new_window(WEB, title, pw, ph);
    w.web = id;
    some(w)
};

def web_present(w: Window, x0: long, y0: long, x1: long, y1: long) -> void {
    if (w.web <= 0) { return; };
    let a = x0;
    let b = y0;
    let c = x1;
    let d = y1;
    if (a < 0) { a = 0; };
    if (b < 0) { b = 0; };
    if (c > w.width) { c = w.width; };
    if (d > w.height) { d = w.height; };
    if (a >= c || b >= d) { return; };
    WEB_ARG[0] = w.web;
    WEB_ARG[1] = ptr_addr(&w.pixels[0]);
    WEB_ARG[2] = w.width;
    WEB_ARG[3] = w.height;
    WEB_ARG[4] = a;
    WEB_ARG[5] = b;
    WEB_ARG[6] = c;
    WEB_ARG[7] = d;
    web_call(W_PRESENT, 8);
};

// The gui button bit an event's button number stands for (1 left, 2 middle, 3 right).
def web_button(b: long) -> long {
    if (b == 1) { BTN_LEFT }
    else if (b == 2) { BTN_MIDDLE }
    else if (b == 3) { BTN_RIGHT }
    else { 0 }
};

def web_pump(w: Window) -> void {
    if (w.web <= 0) { return; };
    WEB_ARG[0] = w.web;
    WEB_ARG[1] = ptr_addr(&WEB_EV[0]);
    WEB_ARG[2] = EVQ;
    let n = web_call(W_POLL, 3);
    if (n > EVQ) { n = EVQ; };
    let i = 0;
    while (i < n) {
        let at = i * 5;
        let k = WEB_EV[at];
        let a = WEB_EV[at + 1];
        let b = WEB_EV[at + 2];
        let c = WEB_EV[at + 3];
        let d = WEB_EV[at + 4];
        if (k == EV_RESIZE) {
            set_size(w, a, b);
        } else if (k == EV_KEY) {
            w.mods = c;
            push_event(w, EV_KEY, a, b, c, d);
        } else if (k == EV_CHAR) {
            w.mods = c;
            push_event(w, EV_CHAR, a, b, c, d);
        } else if (k == EV_MOVE) {
            w.mx = a;
            w.my = b;
            w.buttons = c;
            push_event(w, EV_MOVE, a, b, c, d);
        } else if (k == EV_BUTTON) {
            w.mx = a;
            w.my = b;
            let bit = web_button(c);
            if (d != 0) { w.buttons = w.buttons | bit; }
            else { w.buttons = w.buttons & ~bit; };
            push_event(w, EV_BUTTON, a, b, c, d);
        } else if (k == EV_WHEEL) {
            w.mx = a;
            w.my = b;
            push_event(w, EV_WHEEL, a, b, c, d);
        } else if (k == EV_FOCUS) {
            push_event(w, EV_FOCUS, a, b, c, d);
        } else if (k == EV_CLOSE) {
            push_event(w, EV_CLOSE, a, b, c, d);
        } else if (k == EV_EXPOSE) {
            present_all(w);
            push_event(w, EV_EXPOSE, 0, 0, w.width, w.height);
        };
        i += 1;
    };
};

def web_wait(w: Window, ms: long) -> void {
    if (w.web <= 0) { return; };
    WEB_ARG[0] = w.web;
    WEB_ARG[1] = ms;
    web_call(W_WAIT, 2);
};

def web_set_title(w: Window, t: str) -> void {
    if (w.web <= 0) { return; };
    let b = cstr(t);
    WEB_ARG[0] = w.web;
    WEB_ARG[1] = ptr_addr(&b[0]);
    WEB_ARG[2] = b.length - 1;
    web_call(W_TITLE, 3);
};

def web_resize(w: Window, nw: long, nh: long) -> void {
    if (w.web <= 0) { return; };
    WEB_ARG[0] = w.web;
    WEB_ARG[1] = nw;
    WEB_ARG[2] = nh;
    let r = web_call(W_RESIZE, 3);
    // fit mode: the page owns the size; take what the host says it is
    if (r < 0) {
        WEB_ARG[0] = w.web;
        let sz = web_call(W_SIZE, 1);
        let pw = sz & 0xffffffff;
        let ph = (sz >> 32) & 0xffffffff;
        if (pw > 0 && ph > 0 && (pw != w.width || ph != w.height)) { set_size(w, pw, ph); };
    };
};

def web_read_back(w: Window) -> [byte]? {
    if (w.web <= 0) { return none; };
    let out = zeros(w.width * w.height * 4);
    if (out.length == 0) { return none; };
    WEB_ARG[0] = w.web;
    WEB_ARG[1] = ptr_addr(&out[0]);
    WEB_ARG[2] = out.length;
    let n = web_call(W_READ_BACK, 3);
    if (n <= 0) { return none; };
    if (n > out.length) { n = out.length; };
    some(out[0:n])
};

def web_verify(w: Window) -> bool {
    present_all(w);
    let rb = web_read_back(w);
    if (rb == none) { return false; };
    checksum_of(rb!, w.width * w.height) == checksum(w)
};

def web_close(w: Window) -> void {
    if (w.web <= 0) { return; };
    WEB_ARG[0] = w.web;
    web_call(W_CLOSE, 1);
    w.web = 0;
};

def open(title: str, w: long, h: long) -> Window? {
    let r = web_open(title, w, h);
    if (r != none) { return r; };
    let r2 = w32_open(title, w, h);
    if (r2 != none) { return r2; };
    x_open(title, w, h)
};

def backend_name(b: long) -> str {
    if (web_is(b)) { "web" }
    else if (b == WIN32) { "win32" }
    else if (b == X11) { "x11" }
    else if (b == WAYLAND) { "wayland" }
    else if (b == YOS) { "yos" }
    else { "headless" }
};

def present(w: Window) -> void {
    if (w.dx0 >= w.dx1 || w.dy0 >= w.dy1) { return; };
    if (!w.alive) { clean(w); return; };
    if (web_is(w.backend)) { web_present(w, w.dx0, w.dy0, w.dx1, w.dy1); }
    else if (w.backend == WIN32) { w32_present(w, w.dx0, w.dy0, w.dx1, w.dy1); }
    else if (w.backend == X11) { x_present(w, w.dx0, w.dy0, w.dx1, w.dy1); };
    clean(w);
};

def pump(w: Window) -> void {
    if (web_is(w.backend)) { web_pump(w); }
    else if (w.backend == WIN32) { w32_pump(w); }
    else if (w.backend == X11) { x_pump(w); };
};

def wait(w: Window, ms: long) -> void {
    if (w.evr < w.evw || !w.alive) { return; };
    if (web_is(w.backend)) { web_wait(w, ms); }
    else if (w.backend == WIN32) {
        WA[0] = 0;
        WA[1] = 0;
        WA[2] = 0;
        WA[3] = ms;
        WA[4] = 0x4ff;               // QS_ALLINPUT
        WA[5] = 0;
        gcall(F_MsgWait, 6);
    } else if (w.backend == X11) {
        let x = w.x11;
        if (x != none) { x_more(x!, ms); };
    };
};

def set_title(w: Window, t: str) -> void {
    w.title = t;
    if (web_is(w.backend)) { web_set_title(w, t); }
    else if (w.backend == WIN32) {
        let b = cstr(t);
        gcall4(F_SetWindowTextA, w32_hwnd(w), ptr_addr(&b[0]), 0, 0);
    } else if (w.backend == X11) {
        let x = w.x11;
        if (x != none) { x_title(w, x!, t); };
    };
};

def resize(w: Window, nw: long, nh: long) -> void {
    if (web_is(w.backend)) { web_resize(w, nw, nh); }
    else if (w.backend == WIN32) {
        W32_RC[0] = 0;
        W32_RC[1] = nw | (nh << 32);
        gcall4(F_AdjustWindowRectEx, ptr_addr(&W32_RC[0]), 0xcf0000, 0, 0);
        let rw = (W32_RC[1] & 0xffffffff) - (W32_RC[0] & 0xffffffff);
        let rh = ((W32_RC[1] >> 32) & 0xffffffff) - ((W32_RC[0] >> 32) & 0xffffffff);
        WA[0] = w32_hwnd(w);
        WA[1] = 0;
        WA[2] = 0;
        WA[3] = 0;
        WA[4] = rw;
        WA[5] = rh;
        WA[6] = 6;                   // SWP_NOMOVE | SWP_NOZORDER
        gcall(F_SetWindowPos, 7);
    } else if (w.backend == X11) {
        let x = w.x11;
        if (x != none) {
            TXP = 0;
            t8(12);
            t8(0);
            t16(5);
            t32(x!.win);
            t16(12);                 // width | height
            t16(0);
            t32(nw);
            t32(nh);
            x_send(x!, TXP);
        };
    } else {
        set_size(w, nw, nh);
    };
};

def read_back(w: Window) -> [byte]? {
    if (web_is(w.backend)) { return web_read_back(w); };
    if (w.backend == WIN32) { return w32_read_back(w); };
    if (w.backend == X11) { return x_read_back(w); };
    some(w.pixels[0:w.width * w.height * 4])
};

def verify_present(w: Window) -> bool {
    if (web_is(w.backend)) { return web_verify(w); };
    if (w.backend == WIN32) { return w32_verify(w); };
    if (w.backend == X11) {
        present_all(w);
        let rb = x_read_back(w);
        if (rb == none) { return false; };
        return checksum_of(rb!, w.width * w.height) == checksum(w);
    };
    true
};

def close(w: Window) -> void {
    if (web_is(w.backend)) { web_close(w); }
    else if (w.backend == WIN32) {
        let i = w.win32;
        if (i != none && w.alive) {
            w.alive = false;
            gcall4(F_ReleaseDC, i!.hwnd, i!.hdc, 0, 0);
            gcall4(F_DestroyWindow, i!.hwnd, 0, 0, 0);
        };
        w32_pump(w);
    } else if (w.backend == X11) {
        let x = w.x11;
        if (x != none && !x!.down) {
            TXP = 0;
            t8(4);
            t8(0);
            t16(2);
            t32(x!.win);
            x_send(x!, TXP);
            ipc.close(x!.fd);
            x!.down = true;
        };
    };
    w.alive = false;
};
