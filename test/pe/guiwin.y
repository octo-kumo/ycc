// A real window through user32 and gdi32, called from Y (std/gui.y over the y_os_gui_* names
// and the window-procedure trampoline of arch/wgui.s): it opens, takes the pixel buffer,
// presents it whole and in part, and sees what the system says about it. The run happens in
// a logon session with no visible desktop (ssh), whose windows do not keep what is drawn into
// them, so the check is `verify_present`: the same blit code into a memory bitmap, read back.
import gui;

print(gui.on_windows());
let w = gui.open("ytest gui window", 320, 200);
if (w == none) {
    print("no window");
    exit(1);
};
let win = w!;
print(gui.backend_name(gui.backend(win)));
print(win.win32 != none && win.x11 == none);
print(win.width, "x", win.height);

let y = 0;
while (y < 200) {
    let x = 0;
    while (x < 320) {
        gui.fill(win, x, y, 1, 1, (x & 255) | ((y & 255) << 8) | (((x + y) & 255) << 16));
        x += 1;
    };
    y += 1;
};
gui.present(win);
gui.text(win, 2, 2, "Hello, Windows", 0xffffff, 0x000000);
gui.cell(win, 5, 5, 0x2588, 0xff0000, 0);
gui.cell(win, 6, 5, 0x2580, 0xff0000, 0x00ff00);
gui.present(win);
print(gui.verify_present(win));

// the message loop: poll drains whatever the system queued (a paint, activation) without waiting
let ev = gui.new_event();
let seen = 0;
let i = 0;
while (i < 10) {
    while (gui.poll(win, ev)) { seen += 1; };
    gui.wait(win, 10);
    i += 1;
};
print(win.alive);

// a resize asked for arrives as an event, with a pixel buffer of the new size
gui.resize(win, 400, 240);
let got = false;
i = 0;
while (i < 50 && !got) {
    while (gui.poll(win, ev)) {
        if (ev.kind == gui.EV_RESIZE) { got = true; };
    };
    gui.wait(win, 20);
    i += 1;
};
print(got, " ", win.width, "x", win.height);
gui.clear(win, 0x336699);
gui.present(win);
print(gui.verify_present(win));

gui.set_title(win, "renamed");
gui.close(win);
print(win.alive);
