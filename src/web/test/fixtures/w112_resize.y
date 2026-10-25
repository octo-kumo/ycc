// W6 (scope 3): fit mode's ResizeObserver delivers EV_RESIZE.
//
// The initial page/window size negotiation is drained first; the resize the
// test cares about is the stage changing size after that, so a host that also
// sends the opening EV_RESIZE (or an overlay that asks gui.size) does not
// change what this checks.
import gui;

puts("start\n");
region {
    let ww = gui.open("w112 resize", 320, 200);
    if (ww == none) { puts("no window\n"); exit(1); };
    let w = unwrap(ww);
    let ev = gui.new_event();
    while (gui.poll(w, ev)) { };
    let baseW = w.width;
    let baseH = w.height;
    puts("size " + tostring(baseW) + " " + tostring(baseH) + "\n");
    gui.clear(w, 0x203040);
    gui.present_all(w);
    let seen = false;
    let idle = 0;
    while (!seen && idle < 200) {
        let any = false;
        while (gui.poll(w, ev)) {
            any = true;
            if (ev.kind == gui.EV_RESIZE && (ev.a != baseW || ev.b != baseH)) {
                puts("resize " + tostring(ev.a) + " " + tostring(ev.b) + "\n");
                seen = true;
                break;
            };
        };
        if (any) { idle = 0; } else { idle += 1; };
        if (!seen) { gui.wait(w, 20); };
    };
    puts("final " + tostring(w.width) + " " + tostring(w.height) + "\n");
    gui.close(w);
};
puts("done\n");
