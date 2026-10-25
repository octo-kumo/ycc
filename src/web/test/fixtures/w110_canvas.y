// W6 w110_canvas: what the program presents is what the canvas holds.
//
// The page's test harness hashes the canvas with getImageData and compares that
// digest with the checksum this program prints from gui.read_back; the corner
// colours prove the host swapped B and R on the way to the canvas.  A second,
// partial present proves the host keeps the whole frame for read_back.
import gui;

puts("start\n");
region {
    let ww = gui.open("w110 canvas", 96, 64);
    if (ww == none) { puts("no window\n"); exit(1); };
    let w = unwrap(ww);
    // Fit mode: the page's size arrives as the first EV_RESIZE.
    let ev = gui.new_event();
    while (gui.poll(w, ev)) { };
    let W = w.width;
    let H = w.height;
    gui.clear(w, 0x101820);
    let hw = W / 2;
    let hh = H / 2;
    gui.fill(w, 0, 0, hw, hh, 0xff0000);
    gui.fill(w, hw, 0, W - hw, hh, 0x00ff00);
    gui.fill(w, 0, hh, hw, H - hh, 0x0000ff);
    gui.fill(w, hw, hh, W - hw, H - hh, 0xffffff);
    // A one-pixel-per-column gradient band, so a shifted row cannot match.
    if (H >= 8) {
        let x = 0;
        while (x < W) {
            let r = (x * 255 / W) & 0xff;
            let c = (r << 16) | (((255 - r) & 0xff) << 8) | ((x * 7) & 0xff);
            gui.fill(w, x, hh - 2, 1, 4, c);
            x += 1;
        };
    };
    gui.present_all(w);
    // Only this rectangle travels the second time.
    gui.fill(w, 5, 5, 6, 4, 0xabcdef);
    gui.present(w);
    let rb = gui.read_back(w);
    if (rb == none) { puts("no read_back\n"); exit(2); };
    puts("size " + tostring(W) + " " + tostring(H) + "\n");
    puts("checksum " + tostring(gui.checksum_of(unwrap(rb), W * H)) + "\n");
    puts("verify " + tostring(gui.verify_present(w)) + "\n");
    gui.close(w);
};
puts("done\n");
