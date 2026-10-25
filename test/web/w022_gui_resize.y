// w022: a resize event replaces the pixel buffer (set_size), and gui.resize in
// fixed canvas mode queues one too. ytest delivers the first from
// w022_gui_resize.events on the virtual display; the second comes from the host.
import gui;

let w = gui.open("ytest web gui resize", 320, 200);
if (w == none) {
    print("no window");
    exit(1);
};
let win = w!;
print("start ", win.width, "x", win.height, " pixels ", win.pixels.length);
gui.present(win);
let ev = gui.new_event();

let got = false;
let i = 0;
while (!got && i < 200) {
    while (gui.poll(win, ev)) {
        if (ev.kind == gui.EV_RESIZE) {
            print("event ", ev.a, "x", ev.b, " pixels ", win.pixels.length);
            got = true;
        };
    };
    if (!got) { gui.wait(win, 20); i += 1; };
};
print("size ", win.width, "x", win.height, " pixels ", win.pixels.length);

gui.resize(win, 500, 320);
let got2 = false;
i = 0;
while (!got2 && i < 200) {
    while (gui.poll(win, ev)) {
        if (ev.kind == gui.EV_RESIZE) {
            print("resize ", ev.a, "x", ev.b, " pixels ", win.pixels.length);
            got2 = true;
        };
    };
    if (!got2) { gui.wait(win, 20); i += 1; };
};
print("final ", win.width, "x", win.height, " pixels ", win.pixels.length);
gui.close(win);
print("closed ", tostring(!win.alive));
