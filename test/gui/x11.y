// The X11 backend of std/gui against a real X server (ytest gui starts a private one, or
// takes $GUI_DISPLAY): the window opens, what is presented is what the server holds (GetImage),
// a partial present is exact, a resize the program asks for comes back as an event with a
// buffer of the new size, and the title is set. The server's own copy is the check.
import gui;

let w = gui.open("ytest gui x11", 320, 200);
if (w == none) {
    print("no window");
    exit(1);
};
let win = w!;
print(gui.backend_name(gui.backend(win)));
print(win.x11 != none && win.win32 == none);
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
print(gui.verify_present(win));

// a partial update
gui.text(win, 3, 3, "Hello, X11", 0xffffff, 0x000000);
gui.cell(win, 6, 6, 0x2580, 0xff0000, 0x00ff00);
gui.present(win);
let rb = gui.read_back(win);
print(rb != none && gui.checksum_of(rb!, 320 * 200) == gui.checksum(win));

let ev = gui.new_event();
let i = 0;
while (i < 5) {
    while (gui.poll(win, ev)) { };
    gui.wait(win, 10);
    i += 1;
};
print(win.alive);

gui.resize(win, 400, 240);
let got = false;
i = 0;
while (i < 100 && !got) {
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
