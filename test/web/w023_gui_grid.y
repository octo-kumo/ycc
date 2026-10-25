// w023: Grid + grid_flush rasterises identically into the web window and a
// headless one, so the web digest equals the native headless digest without a
// golden number. The first flush draws all 240 cells; the second draws none.
import gui;

let w = gui.open("ytest web gui grid", 320, 96);
if (w == none) {
    print("no window");
    exit(1);
};
let win = w!;
let head = gui.open_headless(320, 96);
let gw = gui.grid_new(40, 6);
let gh = gui.grid_new(40, 6);

gui.grid_text(gw, 0, 0, "grid on the web", 0xffffff, 0x203040);
gui.grid_put(gw, 3, 1, 0x2588, 0xff0000, 0x000000);
gui.grid_put(gw, 4, 1, 0x2580, 0x00ff00, 0x0000ff);
gui.grid_put(gw, 5, 1, 0x2500, 0xffffff, 0x203040);
gui.grid_put(gw, 6, 1, 0x28ff, 0x80ff80, 0x101820);
gui.grid_text(gw, 0, 2, "Hello, w\xc3\xb6rld", 0xe8d8a0, 0x101820);

gui.grid_text(gh, 0, 0, "grid on the web", 0xffffff, 0x203040);
gui.grid_put(gh, 3, 1, 0x2588, 0xff0000, 0x000000);
gui.grid_put(gh, 4, 1, 0x2580, 0x00ff00, 0x0000ff);
gui.grid_put(gh, 5, 1, 0x2500, 0xffffff, 0x203040);
gui.grid_put(gh, 6, 1, 0x28ff, 0x80ff80, 0x101820);
gui.grid_text(gh, 0, 2, "Hello, w\xc3\xb6rld", 0xe8d8a0, 0x101820);

print("flush web ", gui.grid_flush(win, gw));
print("flush headless ", gui.grid_flush(head, gh));
print("again web ", gui.grid_flush(win, gw));
print("again headless ", gui.grid_flush(head, gh));
gui.present(win);
let a = gui.checksum(win);
let b = gui.checksum(head);
print("web ", a, " headless ", b, " same ", tostring(a == b));
let rb = gui.read_back(win);
print("read back same ", tostring(rb != none && gui.checksum_of(rb!, 320 * 96) == a));
gui.close(win);
print("closed ", tostring(!win.alive));
