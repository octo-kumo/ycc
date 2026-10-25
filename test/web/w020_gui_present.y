// w020: gui.open on the web's virtual display, draw, present, read back what the
// host holds, verify it, and close. ytest runs this under the Node host with
// --display=320x200 (w020_gui_present.runflags); no events are needed.
import gui;

let w = gui.open("ytest web gui present", 320, 200);
if (w == none) {
    print("no window");
    exit(1);
};
let win = w!;
print("backend ", gui.backend_name(gui.backend(win)), " ", win.width, "x", win.height);
gui.clear(win, 0x102030);
gui.fill(win, 10, 20, 30, 40, 0xffffff);
gui.text(win, 2, 2, "web", 0xffcc00, 0x102030);
gui.present(win);
let sum = gui.checksum(win);
print("checksum ", sum);
let rb = gui.read_back(win);
if (rb == none) {
    print("no read back");
    exit(1);
};
let rsum = gui.checksum_of(rb!, win.width * win.height);
print("read back ", rsum);
print("same ", tostring(rsum == sum));
print("verify ", tostring(gui.verify_present(win)));
gui.close(win);
print("closed ", tostring(!win.alive), " ", win.web);
