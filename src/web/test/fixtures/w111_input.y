// W6 w111_input: what the person does at the canvas comes back as gui events.
//
// The scripted sequence, the expected output and the event meanings are the
// native Xvfb run's (test/gui/x11_input.y and x11_input.expected, produced by
// ytest gui); the browser test dispatches the same keys, clicks, wheel and the
// page's close, and compares the program's echo byte for byte.
import gui;

region {
    let w = gui.open("w111 input", 320, 200);
    if (w == none) { print("no window"); exit(1); };
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
            else if (ev.kind == gui.EV_CLOSE) { print("close"); closed = true; break; };
        };
        if (any) { idle = 0; } else { idle += 1; };
        gui.wait(win, 20);
    };
    if (win.alive) { gui.close(win); };
    print("done");
};
