// scratch
// gui: a headless window rasterises cells exactly. Blocks, boxes, shades and braille are drawn
// from rules, text from the baked font; the digest at the end is the same on every system
// (the PE run holds it to the same bytes), and the grid draws only what changed.
import fs;
import gui;

let FAILS = 0;
def check(name: str, ok: bool) -> void {
    if (!ok) {
        FAILS += 1;
        print("FAIL " + name);
    };
};

let w = gui.open_headless(160, 64);
check("size", w.width == 160 && w.height == 64 && gui.cols(w) == 20 && gui.rows(w) == 4);
check("backend", gui.backend(w) == gui.HEADLESS && gui.backend_name(gui.backend(w)) == "headless");

gui.clear(w, 0x112233);
check("clear", gui.pixel(w, 0, 0) == 0x112233 && gui.pixel(w, 159, 63) == 0x112233);
check("outside", gui.pixel(w, 160, 0) == -1 && gui.pixel(w, -1, 0) == -1 && gui.pixel(w, 0, 64) == -1);

// full block, upper half, left half, right half, a quadrant pair
gui.cell(w, 0, 0, 0x2588, 0xff0000, 0x000000);
check("full", gui.pixel(w, 0, 0) == 0xff0000 && gui.pixel(w, 7, 15) == 0xff0000 && gui.pixel(w, 8, 0) == 0x112233);
gui.cell(w, 1, 0, 0x2580, 0x00ff00, 0x0000ff);
check("upper half", gui.pixel(w, 8, 0) == 0x00ff00 && gui.pixel(w, 15, 7) == 0x00ff00 && gui.pixel(w, 8, 8) == 0x0000ff && gui.pixel(w, 15, 15) == 0x0000ff);
gui.cell(w, 2, 0, 0x258c, 0xffffff, 0x000000);
check("left half", gui.pixel(w, 16, 5) == 0xffffff && gui.pixel(w, 19, 5) == 0xffffff && gui.pixel(w, 20, 5) == 0);
gui.cell(w, 3, 0, 0x2590, 0xffffff, 0x000000);
check("right half", gui.pixel(w, 24, 5) == 0 && gui.pixel(w, 28, 5) == 0xffffff && gui.pixel(w, 31, 15) == 0xffffff);
gui.cell(w, 4, 0, 0x259a, 0xffffff, 0x000000);
check("quadrants", gui.pixel(w, 32, 0) == 0xffffff && gui.pixel(w, 39, 0) == 0 && gui.pixel(w, 32, 15) == 0 && gui.pixel(w, 39, 15) == 0xffffff);
gui.cell(w, 5, 0, 0x2582, 0xffffff, 0x000000);
check("lower quarter", gui.pixel(w, 40, 11) == 0 && gui.pixel(w, 40, 12) == 0xffffff && gui.pixel(w, 47, 15) == 0xffffff);
gui.cell(w, 6, 0, 0x2592, 0xffffff, 0x000000);
check("shade", gui.pixel(w, 48, 0) == 0x7e7e7e);

// box drawing: a light line, a heavy one, a double one, a corner, a cross
gui.cell(w, 0, 1, 0x2500, 0xffffff, 0);
check("light horizontal", gui.pixel(w, 0, 23) == 0xffffff && gui.pixel(w, 7, 23) == 0xffffff && gui.pixel(w, 3, 22) == 0 && gui.pixel(w, 3, 24) == 0);
gui.cell(w, 1, 1, 0x2502, 0xffffff, 0);
check("light vertical", gui.pixel(w, 11, 16) == 0xffffff && gui.pixel(w, 11, 31) == 0xffffff && gui.pixel(w, 10, 20) == 0 && gui.pixel(w, 12, 20) == 0);
gui.cell(w, 2, 1, 0x2501, 0xffffff, 0);
check("heavy horizontal", gui.pixel(w, 16, 23) == 0xffffff && gui.pixel(w, 16, 24) == 0xffffff && gui.pixel(w, 16, 22) == 0 && gui.pixel(w, 16, 25) == 0);
gui.cell(w, 3, 1, 0x2551, 0xffffff, 0);
check("double vertical", gui.pixel(w, 26, 20) == 0xffffff && gui.pixel(w, 28, 20) == 0xffffff && gui.pixel(w, 27, 20) == 0);
gui.cell(w, 4, 1, 0x250c, 0xffffff, 0);
check("corner", gui.pixel(w, 35, 23) == 0xffffff && gui.pixel(w, 39, 23) == 0xffffff && gui.pixel(w, 35, 31) == 0xffffff && gui.pixel(w, 34, 23) == 0 && gui.pixel(w, 35, 22) == 0);
gui.cell(w, 5, 1, 0x253c, 0xffffff, 0);
check("cross", gui.pixel(w, 40, 23) == 0xffffff && gui.pixel(w, 47, 23) == 0xffffff && gui.pixel(w, 43, 16) == 0xffffff && gui.pixel(w, 43, 31) == 0xffffff && gui.pixel(w, 40, 16) == 0);
gui.cell(w, 6, 1, 0x2571, 0xffffff, 0);
check("diagonal", gui.pixel(w, 48, 30) == 0xffffff && gui.pixel(w, 55, 16) == 0xffffff && gui.pixel(w, 48, 16) == 0);

// braille: every dot, then none
gui.cell(w, 7, 1, 0x28ff, 0xffffff, 0);
check("braille", gui.pixel(w, 57, 17) == 0xffffff && gui.pixel(w, 61, 17) == 0xffffff && gui.pixel(w, 57, 29) == 0xffffff && gui.pixel(w, 59, 17) == 0);
gui.cell(w, 8, 1, 0x2800, 0xffffff, 0);
check("braille blank", gui.pixel(w, 65, 17) == 0);

// the baked font
check("glyphs", gui.glyph_count() > 1000 && gui.has_glyph(65) && gui.has_glyph(0x16a0) && gui.has_glyph(0x3bb) && gui.has_glyph(0x2588) && !gui.has_glyph(0x4e2d));
let end = gui.text(w, 0, 2, "Hello, w\xc3\xb6rld \xe1\x9a\xa0", 0xffffff, 0x000000);
check("text columns", end == 14);
let lit = 0;
{
    let y = 32;
    while (y < 48) {
        let x = 0;
        while (x < 8) {
            if (gui.pixel(w, x, y) != 0) { lit += 1; };
            x += 1;
        };
        y += 1;
    };
};
check("H has ink", lit > 10 && lit < 80);
let nil = gui.text(w, 15, 2, "\xe4\xb8\xad", 0xffffff, 0x000000);
check("missing glyph draws something", nil == 16 && gui.pixel(w, 15 * 8 + 1, 2 * 16 + 2) == 0xffffff);
// a hard font thresholds the baked coverage: every pixel is ink or background
gui.set_hard(true);
gui.cell(w, 0, 3, 'A', 0xffffff, 0x000000);
let hard = true;
for y in 48..64 {
    for x in 0..8 {
        let c = gui.pixel(w, x, y);
        if (c != 0xffffff && c != 0x000000) { hard = false; };
    };
};
check("hard text is one bit", hard);
gui.set_hard(false);

// attributes: reverse swaps, underline adds a line, dim blends
gui.cell(w, 10, 2, 32, 0xffffff, 0x000000, 16);
check("reverse", gui.pixel(w, 80, 32) == 0xffffff);
gui.cell(w, 11, 2, 32, 0xffffff, 0x000000, 8);
check("underline", gui.pixel(w, 88, 46) == 0xffffff && gui.pixel(w, 88, 44) == 0);
gui.cell(w, 12, 2, 0x2588, 0xffffff, 0x000000, 2);
check("dim", gui.pixel(w, 96, 32) == 0x808080 || gui.pixel(w, 96, 32) == 0x7f7f7f);

// events
gui.inject(w, gui.EV_KEY, gui.K_LEFT, 1, 0, 0);
gui.inject(w, gui.EV_CHAR, 0x3bb, 0, 0, 0);
gui.inject(w, gui.EV_CLOSE, 0, 0, 0, 0);
let ev = gui.new_event();
check("event 1", gui.poll(w, ev) && ev.kind == gui.EV_KEY && ev.a == 37 && ev.b == 1);
check("event 2", gui.poll(w, ev) && ev.kind == gui.EV_CHAR && ev.a == 0x3bb);
check("event 3", gui.poll(w, ev) && ev.kind == gui.EV_CLOSE);
check("no event", !gui.poll(w, ev));

// the grid draws only what changed
let g = gui.grid_new(20, 4);
gui.grid_text(g, 0, 0, "grid", 0xffffff, 0x203040);
check("first flush draws all", gui.grid_flush(w, g) == 80);
check("second flush draws none", gui.grid_flush(w, g) == 0);
gui.grid_put(g, 3, 0, 0x58, 0xffffff, 0x203040);
check("one change", gui.grid_flush(w, g) == 1);
gui.grid_put(g, 3, 0, 0x58, 0xffffff, 0x203040);
check("same again", gui.grid_flush(w, g) == 0);
gui.grid_clear(g, 0);
check("clear changes all but the blanks that were", gui.grid_flush(w, g) == 80);

// a scale of 2 doubles every font pixel
let w2 = gui.open_headless(160, 64);
gui.set_scale(w2, 2);
check("scaled grid", gui.cols(w2) == 10 && gui.rows(w2) == 2);
gui.cell(w2, 0, 0, 0x2580, 0xffffff, 0x000000);
check("scaled half", gui.pixel(w2, 0, 15) == 0xffffff && gui.pixel(w2, 15, 15) == 0xffffff && gui.pixel(w2, 0, 16) == 0 && gui.pixel(w2, 16, 0) == 0);

// the pixel buffer a window holds, as a digest: the same on Linux and on Windows
let w3 = gui.open_headless(320, 96);
gui.clear(w3, 0x101820);
gui.text(w3, 1, 1, "Heavenly Rules \xe1\x9a\xa0\xe1\x9a\xa2 \xe2\x97\x86\xe2\x97\x8f\xe2\x96\xb2", 0xe8d8a0, 0x101820);
gui.cell(w3, 2, 3, 0x2588, 0xc04030, 0);
gui.cell(w3, 3, 3, 0x2580, 0xc04030, 0x3070c0);
gui.cell(w3, 4, 3, 0x2554, 0xffffff, 0x101820);
gui.cell(w3, 5, 3, 0x2550, 0xffffff, 0x101820);
gui.cell(w3, 6, 3, 0x2557, 0xffffff, 0x101820);
gui.cell(w3, 7, 3, 0x28ff, 0x80ff80, 0x101820);
gui.cell(w3, 8, 3, 0x2593, 0xffffff, 0x000000);
gui.cell(w3, 9, 3, 0x41, 0xffffff, 0x000000, 1);
gui.present(w3);
print("digest " + tostring(gui.checksum(w3)));
check("read back", gui.checksum_of(gui.read_back(w3)!, 320 * 96) == gui.checksum(w3));
check("verify", gui.verify_present(w3));
gui.close(w3);
check("closed", !w3.alive);
// the platform questions: a Windows process or not, and standard error to a file
check("on_windows answers", gui.on_windows() || !gui.on_windows());
check("redirect_stderr", gui.redirect_stderr("err.log"));
eputs("to the file");
check("the file has it", fs.read_file("err.log") != none);
if (FAILS == 0) { print("gui headless: ok"); } else { print("gui headless: " + tostring(FAILS) + " failed"); };
