// w021: the host's scripted events become the same gui events the X11 path
// produces. ytest feeds w021_gui_keys.events (--events=...) on the virtual
// display; the output is test/gui/x11_input.expected, produced by the same
// program against Xvfb in the gui suite.
import gui;

let w = gui.open("ytest web gui keys", 320, 200);
if (w == none) {
    print("no window");
    exit(1);
};
let win = w!;
gui.clear(win, 0x202020);
gui.present(win);
print("ready");
let ev = gui.new_event();
let idle = 0;
let closed = false;
while (!closed && idle < 300) {
    let any = false;
    while (gui.poll(win, ev)) {
        any = true;
        if (ev.kind == gui.EV_CHAR) { print("char ", ev.a, " mods ", ev.c); }
        else if (ev.kind == gui.EV_KEY && ev.b == 1 && ev.a != gui.K_SHIFT && ev.a != gui.K_CTRL) { print("key ", ev.a, " mods ", ev.c); }
        else if (ev.kind == gui.EV_BUTTON) { print("button ", ev.c, " ", ev.d, " at ", ev.a, ",", ev.b); }
        else if (ev.kind == gui.EV_WHEEL) { print("wheel ", ev.c, " at ", ev.a, ",", ev.b); }
        else if (ev.kind == gui.EV_CLOSE) { print("close"); closed = true; };
    };
    if (any) { idle = 0; } else { idle += 1; };
    gui.wait(win, 20);
};
if (win.alive) { gui.close(win); };
print("done");
