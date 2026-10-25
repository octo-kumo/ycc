// x11.y -- an X11 example in Y: the X11 wire protocol spoken over a raw Unix
// socket, and a framebuffer renderer whose image can be diffed.
//
// WHY THE SPLIT, AND WHY IT IS NOT A PREFERENCE
//
// The acceptance gate diffs EXPECTED byte for byte.  A window on somebody's
// screen produces no bytes to diff: it has whatever size the screen is, it
// appears at whatever moment the server felt like painting it, and it is gone
// before anyone can look.  So:
//
//   demo    (the default, and the gate's run=) needs NO DISPLAY.  It renders
//           the scene in integer arithmetic into one fixed buffer, prints a
//           digest of the image, the pixel count and the non-zero pixel count,
//           and stops.  That output is EXPECTED, compared byte for byte.
//   check   (the gate's check=) is a property battery.  No reference file, no
//           display, no clock, no network.
//   verify  round-trips a pixmap through a real X server: CreatePixmap,
//           PutImage, then GetImage to read the pixels BACK, and compares the
//           digest the server returns with the digest computed locally.
//   --show  opens a real 320x240 window with the same image.
//
// Nothing on the demo or check path looks at DISPLAY, at the clock, at an
// environment variable or at the network, which is what lets both run on a
// machine with no X server at all.

import gfx;
import scene;
import check;
import xwire;

// The default run: render in memory, describe it in bytes.  Never opens a
// socket.  This is the invocation the gate diffs.
// demo(rep): draw the scene `rep` times and report the LAST one.
//
// `rep` exists for one reason: to measure whether redrawing allocates.  The
// heap is an arena and nothing is ever freed, so a render loop that allocated
// per frame would show a peak heap that grows with the frame count -- and the
// only way to see that is to be able to ask for more frames without changing
// anything else.  Output is byte-IDENTICAL for every rep, which is what makes
// this a measurement rather than a different program: `demo --repeat 25` and
// `demo` differ in no byte.
def demo(rep: long) -> long {
    let n = rep;
    if (n < 1) { n = 1 };
    let el = 0;
    let i = 0;
    while (i < n) {
        el = scene.scene_draw(scene.W, scene.H);
        i = i + 1
    };
    let d = gfx.digest(scene.W, scene.H);
    gfx.stats_scan(scene.W, scene.H);

    print(f"x11: rendered {scene.W}x{scene.H} in memory, {el} element pixels");
    print(f"x11: frame   {scene.W} x {scene.H} = {gfx.st.pixels} pixels, "
        + f"{gfx.st.pixels * 3} bytes rgb");
    print(f"x11: digest  fnv1a64 {gfx.digest_hex(d)}");
    print(f"x11: nonzero {gfx.st.nonzero} of {gfx.st.pixels} pixels");
    print(f"x11: black   {gfx.st.pixels - gfx.st.nonzero} "
        + f"(predicted {scene.background_black_expect(scene.W, scene.H)}, "
        + f"at (0,0) and (1,0))");
    print(f"x11: sums    r {gfx.st.sum_r}  g {gfx.st.sum_g}  b {gfx.st.sum_b}"
        + f"  all {gfx.st.sum_all}");
    let i = 0;
    while (i < len(scene.elems)) {
        let e = scene.elems[i];
        print(f"x11: element {e.name} at ({e.x0},{e.y0})-({e.x1},{e.y1})"
            + f"  {e.px} px");
        i = i + 1;
    };
    print(f"x11: clipped {gfx.clipped}");
    print(f"x11: window  {scene.W}x{scene.H} is what --show opens; the screen "
        + f"is larger and belongs to whoever is sitting at it");
    0
};

def usage() -> long {
    eputs("usage: x11 [demo|check|verify|show] [--no-display]\n");
    eputs("  demo    render in memory and print a digest (default, no display)\n");
    eputs("  probe   connect, handshake, and dump the server's setup reply\n");
    eputs("  check   the property battery (no display)\n");
    eputs("  verify  PutImage/GetImage a pixmap on a real X server and\n");
    eputs("          compare the digest the server returns\n");
    eputs("  show    open a 320x240 window with the image\n");
    eputs("  --no-display  prove the degrading path, whatever DISPLAY says\n");
    eputs("  --repeat N    draw the scene N times, output unchanged, so a probe\n");
    eputs("                can measure whether redrawing allocates\n");
    2
};

def main() -> long {
    // Read av[0] as well as av[1]: argv().length is the only read of argv in
    // some builds and has crashed, and touching the vector keeps it
    // initialised.
    let av = argv();
    let n = len(av);
    let cmd = if n > 1 { av[1] } else { "demo" };

    // --no-display forces the degrading path even where a display exists, so
    // that path is testable on a machine that has one.
    let nodisp = false;
    let rep = 1;
    let i = 1;
    while (i < n) {
        if (av[i] == "--no-display") { nodisp = true }
        else if (av[i] == "--repeat" && i + 1 < n) {
            let r = tolong(av[i + 1]);
            if (r != none) { rep = r! };
            i = i + 1
        };
        i = i + 1;
    };

    if (cmd == "demo") {
        if (nodisp) {
            // The default path must not care about the display at all.  Prove
            // it: with --no-display the digest is unchanged and no socket is
            // opened, because there is no code here that could open one.
            demo(rep);
            print("x11: --no-display; the default path opened no socket");
            return 0;
        };
        demo(rep)
    } else if (cmd == "check") {
        check.do_check()
    } else if (cmd == "probe") {
        if (nodisp) { return xwire.verify_no_display() };
        xwire.probe()
    } else if (cmd == "verify") {
        if (nodisp) { return xwire.verify_no_display() };
        xwire.verify()
    } else if (cmd == "show" || cmd == "--show") {
        if (nodisp) { return xwire.verify_no_display() };
        xwire.show()
    } else if (cmd == "--help" || cmd == "-h") {
        usage()
    } else {
        eputs("x11: unknown command '" + cmd + "'\n");
        usage()
    }
};

exit(main());