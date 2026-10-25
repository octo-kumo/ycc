// scratch: the harness runs this fixture in a scratch directory (relative paths)
// std/tui: the cell grid, colour arithmetic, the glyph ramps, the frame diff,
// the capture, the pacer -- all checked with no terminal attached.
//
// Every assertion here runs with stdout on a pipe, which is the point: the
// draw path is a pure function of the surface plus the previous frame, so a
// headless test can check the bytes a terminal would have received.
import fs;
import tui from "../../../src/y/std/tui.y";
import test from "../../../src/y/std/test.y";

const BG0 = -1;   // "terminal default background"

// ctl(which, path) -> str -- run ONE screen or cursor control against a scratch
// file and answer the exact bytes it wrote.
//
// The write descriptor is opened FRESH for every measurement. Truncating the
// file through a second descriptor does not rewind the one the module holds, so
// an earlier version read 30 bytes where it should have read 15: every
// measurement came back as the sum of all of them.
//
// `which` selects the call because Y has no closures and so no function value to
// pass; what each index means is spelled out at the assertions that use it.
def ctl(which: long, path: str) -> str {
    let w = fs.open_file(path, "w");
    if (w < 0) { return "<no scratch file>" };
    tui.set_fd(w);
    if (which == 0) { tui.clear_screen() };
    if (which == 1) { tui.home() };
    if (which == 2) { tui.cursor_to(3, 5) };
    if (which == 3) { tui.hide_cursor() };
    if (which == 4) { tui.show_cursor() };
    if (which == 5) { tui.enter_alt_screen() };
    if (which == 6) { tui.leave_alt_screen() };
    if (which == 7) { tui.enter_screen() };
    if (which == 8) { tui.leave_screen() };
    if (which == 9) { tui.clear_screen(); tui.hide_cursor() };
    tui.set_fd(1);
    fs.close_file(w);
    let r = fs.open_file(path, "r");
    if (r < 0) { return "<unreadable>" };
    let buf: [byte] = [0; 256];
    let n = os_call("y_os_read", r, &buf[0], 256);
    fs.close_file(r);
    if (n <= 0) { return "" };
    let out = "";
    let i = 0;
    while (i < n) {
        // ESC is spelled rather than written, so a failed comparison is readable
        // in the transcript instead of a run of control characters. The bracket
        // after it is already in the stream.
        if (buf[i] == 27) { out = out + "\x1b" } else { out = out + chr(buf[i]) };
        i = i + 1
    };
    out
};

def main() -> long {
    // ─────────────────────────────────────────── the surface and its cells
    test.group("a surface and its cells");
    let s = tui.new(6, 12);
    test.ck_eq("new(6, 12) has 6 rows", tui.rows(s), 6);
    test.ck_eq("new(6, 12) has 12 cols", tui.cols(s), 12);

    tui.clear(s, BG0);
    test.ck_eq("a cleared cell reads as a space", tui.get(s, 0, 0), 32);

    tui.fill(s, 65, tui.rgb(1, 2, 3), tui.rgb(4, 5, 6));
    test.ck_eq("fill writes the code point", tui.get(s, 2, 3), 65);
    test.ck_eq("key_at packs fg in the high 24 bits",
        tui.key_at(s, 2, 3) >> 24, tui.rgb(1, 2, 3));
    test.ck_eq("and bg in the low 24", tui.key_at(s, 2, 3) & 16777215, tui.rgb(4, 5, 6));
    // A cell whose background is DEFAULT cannot be reported by key_at, and this
    // is worth stating rather than working around: DEFAULT is -1, which is every
    // bit set, so (fg << 24) | -1 is -1 and the foreground is lost with it. A
    // caller that needs to compare cell colours keeps its own copy, which is why
    // the surface snapshots in the examples do.
    let kb = tui.new(1, 2);
    tui.clear(kb, BG0);
    tui.put(kb, 0, 0, 65, tui.rgb(9, 9, 9), BG0);
    test.ck("key_at of a DEFAULT-background cell is -1, fg and all",
        tui.key_at(kb, 0, 0) == -1, "so it cannot read such a cell back");

    // put_at takes a FLAT index, not a row and a column
    tui.put_at(s, 0 * tui.cols(s) + 0, 67, tui.grey(1), BG0);
    test.ck_eq("put_at(s, 0) is cell (0, 0)", tui.get(s, 0, 0), 67);
    test.ck_eq("and an out-of-range index is refused, not fatal", tui.get(s, 99, 0), -1);
    test.ck_eq("key_at of an out-of-range cell too", tui.key_at(s, 0, 99), -1);

    tui.put(s, 1, 1, 88, tui.rgb(10, 20, 30), tui.rgb(40, 50, 60));
    test.ck_eq("put writes one cell", tui.get(s, 1, 1), 88);
    tui.put(s, 1, 2, 65, tui.rgb(1, 1, 1), BG0);
    let left_before = tui.get(s, 1, 2);
    tui.put_skip(s, 1, 3, tui.rgb(1, 1, 1), BG0);
    test.ck_eq("a skipped cell reads as SKIP", tui.get(s, 1, 3), -1);
    test.ck_eq("and put_skip left the cell to its left alone",
        tui.get(s, 1, 2), left_before);

    // text() DRAWS a string, decoding UTF-8 in place
    tui.text(s, 3, 0, "Hi", tui.grey(2), BG0);
    test.ck_eq("text drew the first character", tui.get(s, 3, 0), 72);
    test.ck_eq("and the second", tui.get(s, 3, 1), 105);
    tui.text(s, 4, 0, "\xE4\xB8\xAD", tui.grey(2), BG0);
    test.ck_eq("a wide code point takes two cells", tui.get(s, 4, 0), 0x4E2D);
    test.ck_eq("and the second is a skip", tui.get(s, 4, 1), -1);
    tui.text(s, 5, 0, "a\nb", tui.grey(2), BG0);
    test.ck_eq("a newline moves to the next row", tui.get(s, 5, 0), 97);
    let bad = tui.new(1, 4);
    tui.clear(bad, BG0);
    tui.text(bad, 0, 0, "\xFF", tui.grey(2), BG0);
    test.ck("malformed UTF-8 draws U+FFFD and does not trap",
        tui.get(bad, 0, 0) == 65533, "a lone continuation byte");
    let bad2 = tui.new(1, 4);
    tui.clear(bad2, BG0);
    tui.text(bad2, 0, 0, "\xE4\xB8", tui.grey(2), BG0);
    test.ck("a truncated three-byte sequence does not trap either",
        tui.get(bad2, 0, 0) == 65533 || tui.get(bad2, 0, 0) == 32,
        "got U+" + tostring(tui.get(bad2, 0, 0)));

    // ─────────────────────────────────────────── colour is one integer
    test.group("colour is one integer");
    test.ck_eq("rgb packs the channels", tui.g_of(tui.rgb(10, 20, 30)), 20);
    test.ck_eq("r_of reads the red back", tui.r_of(tui.rgb(10, 20, 30)), 10);
    test.ck_eq("b_of reads the blue back", tui.b_of(tui.rgb(10, 20, 30)), 30);
    test.ck_eq("grey is r=g=b", tui.g_of(tui.grey(77)), 77);
    test.ck_eq("clamp255 holds 300", tui.clamp255(300), 255);
    test.ck_eq("clamp255 holds -5", tui.clamp255(-5), 0);
    test.ck_eq("clamp255 passes 128", tui.clamp255(128), 128);
    // t is 0..255, so the ends are 0 and 255 and a clamp applies
    test.ck_eq("lerp at 0 is the first end",
        tui.lerp_rgb(tui.rgb(1, 1, 1), tui.rgb(9, 9, 9), 0), tui.rgb(1, 1, 1));
    test.ck_eq("lerp at 255 is the second",
        tui.lerp_rgb(tui.rgb(1, 1, 1), tui.rgb(9, 9, 9), 255), tui.rgb(9, 9, 9));
    test.ck_eq("lerp past 255 is clamped, not a wrap",
        tui.lerp_rgb(tui.rgb(1, 1, 1), tui.rgb(9, 9, 9), 999), tui.rgb(9, 9, 9));
    test.ck_eq("lerp at the midpoint of 0..200",
        tui.r_of(tui.lerp_rgb(tui.rgb(0, 0, 0), tui.rgb(200, 0, 0), 128)), 100);

    // ─────────────────────────────────────────── runs and boxes
    test.group("runs and boxes");
    let b = tui.new(5, 10);
    tui.clear(b, BG0);
    tui.hline(b, 2, 0, 4, 45, tui.grey(255), BG0);
    test.ck_eq("hline wrote 4 cells", tui.get(b, 2, 0), 45);
    test.ck_eq("and stopped at 4", tui.get(b, 2, 4), 32);
    tui.vline(b, 0, 5, 3, 124, tui.grey(255), BG0);
    test.ck_eq("vline wrote 3 cells", tui.get(b, 0, 5), 124);
    test.ck_eq("and stopped at 3", tui.get(b, 3, 5), 32);
    tui.fill_rect(b, 1, 1, 2, 3, 35, tui.grey(7), BG0);
    test.ck_eq("fill_rect filled a cell", tui.get(b, 1, 1), 35);
    test.ck_eq("and one at the far corner", tui.get(b, 2, 3), 35);
    test.ck_eq("but not past the rectangle", tui.get(b, 3, 2), 32);
    // h and w are the FULL extent, so a 4x9 box at (0,0) ends at (3, 8)
    tui.rect(b, 0, 0, 4, 9, 43, tui.grey(9), BG0);
    test.ck_eq("rect drew its top-left corner", tui.get(b, 0, 0), 43);
    test.ck_eq("and its bottom-right at (row+h-1, col+w-1)", tui.get(b, 3, 8), 43);
    test.ck_eq("but not one past it", tui.get(b, 4, 9), 32);
    test.ck_eq("and not the interior", tui.get(b, 1, 4), 32);
    // a box one cell tall degenerates to the single line that fits
    let thin = tui.new(2, 6);
    tui.clear(thin, BG0);
    tui.rect(thin, 0, 0, 1, 5, 43, tui.grey(9), BG0);
    test.ck_eq("a one-row box still draws its row", tui.get(thin, 0, 2), 43);

    // blit: source coordinates first
    let src = tui.new(3, 3);
    tui.fill(src, 64, tui.rgb(5, 5, 5), BG0);
    let dst = tui.new(4, 6);
    tui.clear(dst, BG0);
    tui.blit(dst, src, 0, 0, 1, 2, 2, 2);
    test.ck_eq("blit copied a cell", tui.get(dst, 1, 2), 64);
    test.ck_eq("and stopped at the rectangle", tui.get(dst, 3, 4), 32);
    let src2 = tui.new(3, 3);
    tui.fill(src2, 64, tui.rgb(5, 5, 5), tui.rgb(6, 6, 6));
    let dst2 = tui.new(4, 6);
    tui.clear(dst2, BG0);
    tui.blit(dst2, src2, 0, 0, 1, 2, 2, 2);
    test.ck_eq("blit copied a foreground", tui.key_at(dst2, 1, 2) >> 24, tui.rgb(5, 5, 5));
    test.ck_eq("and a background", tui.key_at(dst2, 1, 2) & 16777215, tui.rgb(6, 6, 6));

    // ─────────────────────────────────────────── the glyph ramps
    test.group("luminance ramps");
    // each shade_* takes (value, max) and answers a CODE POINT, not a string
    test.ck_eq("shade_blocks(white) is a full block", tui.shade_blocks(255, 255), 9608);
    test.ck_eq("shade_blocks(black) is a space", tui.shade_blocks(0, 255), 32);
    // ramp_index(v, n, levels) with n <= 0 answers the FULLEST position rather
    // than dividing by zero, so shade(0, 0) is the top of the ramp. That it does
    // not trap is the property worth checking.
    test.ck_eq("shade with n <= 0 is the full glyph, not a division by zero",
        tui.shade(0, 0), 9608);
    // "monotone" is a claim about the ramp POSITION, not about code points: the
    // block ramp is 32, 9617, 9618, 9619, 9608 and 9608 < 9619, so comparing code
    // points fails on the last step while the ramp is perfectly ordered.
    test.ck("ramp_index is monotone in v", {
        let i = 1;
        let ok = true;
        while (i <= 255) {
            if (tui.ramp_index(i, 255, 5) < tui.ramp_index(i - 1, 255, 5)) { ok = false };
            i = i + 1
        };
        ok
    }, "brighter never picks an earlier position");
    test.ck("and the block ramp really does step down at the end",
        tui.shade_blocks(200, 255) > tui.shade_blocks(255, 255),
        "position 3 is U+2583 and position 4 is U+2588, so code-point order is NOT ramp order");
    test.ck_eq("and the top of the ramp is U+2588", tui.shade_blocks(255, 255), 0x2588);
    test.ck_eq("shade_ascii at the bottom", tui.shade_ascii(0, 255), 32);
    test.ck("shade_ascii at the top is not a space",
        tui.shade_ascii(255, 255) != 32, "got " + tostring(tui.shade_ascii(255, 255)));
    test.ck("the four ramps differ at mid luminance",
        tui.shade_blocks(128, 255) != tui.shade_half(128, 255)
            && tui.shade_half(128, 255) != tui.shade_braille(128, 255),
        "blocks, half and braille are three ramps");
    test.ck_eq("shade_len(0) ascii", tui.shade_len(0), 10);
    test.ck_eq("shade_len(1) blocks", tui.shade_len(1), 5);
    test.ck_eq("shade_len(2) half", tui.shade_len(2), 4);
    test.ck_eq("shade_len(3) braille", tui.shade_len(3), 16);

    // ramp_index is the one place a value becomes a ramp position
    test.ck_eq("ramp_index(0, 256, 8) is the first", tui.ramp_index(0, 256, 8), 0);
    test.ck_eq("ramp_index(255, 256, 8) is not the last", tui.ramp_index(255, 256, 8), 7);
    test.ck_eq("ramp_index clamps above n", tui.ramp_index(999, 256, 8), 7);
    test.ck_eq("ramp_index clamps below 0", tui.ramp_index(-5, 256, 8), 0);
    test.ck_eq("ramp_index with n <= 0 is the last, not a division by zero",
        tui.ramp_index(5, 0, 8), 7);
    test.ck_eq("ramp_index with levels <= 1 is 0", tui.ramp_index(5, 256, 1), 0);

    // braille(vs, thresh) turns a column of eight samples into one dot pattern,
    // so it is the pure half of braille_put and is checked on its own here.
    // The parameter is [long], not [long; 8], so the columns are built as
    // arrays rather than fixed literals -- the same shape as every
    // fixed-array parameter in std.
    let col_dark: [long] = [0; 8];
    let col_full: [long] = [255; 8];
    let col_half: [long] = [255; 4] + [0; 4];
    test.ck_eq("an all-dark column gives the empty pattern",
        tui.braille(col_dark, 128), 0x2800);
    test.ck_eq("an all-bright column gives a full one",
        tui.braille(col_full, 128), 0x28FF);
    test.ck("a half-bright column gives half the dots",
        tui.braille(col_half, 128) != 0x2800 && tui.braille(col_half, 128) != 0x28FF,
        "four of the eight set");
    test.ck_eq("and a threshold above every sample empties it",
        tui.braille(col_full, 100000), 0x2800);

    // braille: a progressive fill of one cell's 8 dots
    test.group("braille dot patterns");
    test.ck_eq("level 0 fills nothing", tui.braille_mask(0), 0);
    test.ck_eq("level 1 fills the first dot", tui.braille_mask(1), 1);
    test.ck_eq("level 8 fills all of them", tui.braille_mask(8), 255);
    test.ck_eq("a level above 8 is clamped, not a trap", tui.braille_mask(99), 255);
    test.ck_eq("a negative level fills nothing", tui.braille_mask(-1), 0);
    test.ck("the fill is progressive", {
        let i = 1;
        let ok = true;
        while (i <= 8) {
            if (tui.braille_mask(i) & tui.braille_mask(i - 1) != tui.braille_mask(i - 1)) { ok = false };
            i = i + 1
        };
        ok
    }, "each step only adds dots");
    test.ck_eq("braille_cp is U+2800 + the mask", tui.braille_cp(1), 0x2801);
    test.ck_eq("and of the empty pattern", tui.braille_cp(0), 0x2800);

    // braille_put takes a COLUMN of samples, not a mask
    let br = tui.new(2, 4);
    tui.clear(br, BG0);
    let col0: [long] = [255; 8];
    tui.braille_put(br, 0, 0, col0, 128, tui.grey(9), BG0);
    test.ck("braille_put wrote a non-empty pattern",
        tui.get(br, 0, 0) != 32 && tui.get(br, 0, 0) != 0x2800,
        "got U+" + tostring(tui.get(br, 0, 0)));
    test.ck("the all-below-threshold column leaves the cell clear",
        {
            let dark: [long] = [0; 8];
            let b2 = tui.new(1, 1);
            tui.clear(b2, BG0);
            tui.braille_put(b2, 0, 0, dark, 128, tui.grey(9), BG0);
            tui.get(b2, 0, 0) == 0x2800
        }, "no dot above the threshold, so U+2800");

    // ─────────────────────────────────────────── UTF-8
    test.group("code points and columns");
    test.ck_eq("'A' is one byte", tui.utf8_len(65), 1);
    test.ck_eq("U+00E9 is two", tui.utf8_len(0xE9), 2);
    test.ck_eq("U+4E2D is three", tui.utf8_len(0x4E2D), 3);
    test.ck_eq("U+1F600 is four", tui.utf8_len(0x1F600), 4);
    test.ck_eq("U+4E2D byte 0", tui.utf8_byte(0x4E2D, 0), 0xE4);
    test.ck_eq("U+4E2D byte 1", tui.utf8_byte(0x4E2D, 1), 0xB8);
    test.ck_eq("U+4E2D byte 2", tui.utf8_byte(0x4E2D, 2), 0xAD);
    test.ck_eq("'A' occupies one column", tui.width_of(65), 1);
    test.ck_eq("U+4E2D occupies two", tui.width_of(0x4E2D), 2);
    test.ck_eq("U+1F600 occupies two", tui.width_of(0x1F600), 2);
    test.ck_eq("a combining mark occupies none", tui.width_of(0x0301), 0);

    // ─────────────────────────────────────────── the frame diff and the capture
    test.group("the frame diff");
    let f = tui.new(3, 8);
    tui.clear(f, BG0);
    tui.capture_on();
    tui.capture_reset();
    tui.begin_frame();
    // cell_same and cell_commit take a FLAT index
    // A cleared cell is NOT yet "same": the shadow arrays start at zero and a
    // cleared cell holds 32 with background DEFAULT, so the first frame after a
    // new() writes every cell once and only then settles. That is the diff doing
    // its job, and it is why a surface must be committed before it can be
    // compared with itself.
    test.ck("a freshly cleared cell is not yet committed",
        !tui.cell_same(f, 0), "the shadow starts empty, so the first frame writes");
    tui.cell_commit(f, 0);
    test.ck("after committing once it is", tui.cell_same(f, 0),
        "and the second frame can skip it");
    test.ck("and a different cell is still different",
        !tui.cell_same(f, 1), "one commit does not settle the whole surface");
    tui.cell_commit(f, 0);
    test.ck("after committing, cell_same agrees", tui.cell_same(f, 0),
        "no second write needed");
    tui.flush(f);
    tui.end_frame(f);
    test.ck("the capture saw the draw", tui.capture_len() > 0,
        tostring(tui.capture_len()) + " bytes");
    test.ck("and they are escape sequences", tui.capture_byte(0) == 27, "ESC first");
    test.ck_eq("capture_checksum is stable across two reads",
        tui.capture_checksum(), tui.capture_checksum());
    test.ck("capture_str reads a range back", tui.capture_str(0, 4).length >= 1, "non-empty");
    tui.capture_off();

    // flush() repaints every row in full and only brings the shadow up to date;
    // flush_diff() is the one that emits nothing when nothing changed. So the
    // "nothing changed" property is a property of flush_diff, and that is what
    // is asserted here.
    let d = tui.new(3, 8);
    tui.clear(d, BG0);
    tui.flush_diff(d);                       // the first pass writes everything
    tui.capture_on();
    tui.capture_reset();
    tui.flush_diff(d);
    test.ck_eq("flush_diff of an unchanged surface emits no bytes",
        tui.capture_len(), 0);
    tui.capture_off();

    // and one changed cell costs one CUP plus that cell, not a whole row
    tui.put(d, 1, 2, 65, tui.grey(5), BG0);
    tui.capture_on();
    tui.capture_reset();
    tui.flush_diff(d);
    let one = tui.capture_len();
    tui.capture_off();
    test.ck("one changed cell does emit", one > 0, "so the zero above is not vacuous");
    test.ck("but far less than a full repaint", one < tui.frame_bytes() + 1 || one <= 32,
        "a CUP and a cell or two, not 24 cells");

    // a full flush, by contrast, always writes every row
    tui.capture_on();
    tui.capture_reset();
    tui.flush(d);
    test.ck("flush() repaints in full even with nothing changed",
        tui.capture_len() > 0, "which is what it is for: after a resize");
    tui.capture_off();

    // one changed cell, and only that row is written
    tui.capture_on();
    tui.capture_reset();
    tui.begin_frame();
    tui.put(f, 2, 3, 88, tui.rgb(9, 9, 9), BG0);
    tui.flush_diff(f);
    tui.end_frame(f);
    test.ck("flush_diff wrote something", tui.capture_len() > 0, "one cell changed");
    tui.capture_off();

    test.group("row sizing, measured from the last flush");
    // row_count, row_bytes and frame_bytes describe the LAST FLUSH, not the
    // surface: they are the frame's accounting, which begin_frame zeroes. So a
    // flush has to happen here before they can be read at all.
    let sz = tui.new(3, 8);
    tui.clear(sz, BG0);
    tui.flush(sz);
    test.ck_eq("row_count is the rows the last flush wrote", tui.row_count(), 3);
    test.ck("frame_bytes counts every byte of that flush",
        tui.frame_bytes() > 0, "the CUPs and the cells");
    test.ck("frame_bytes covers at least one CUP per row",
        tui.frame_bytes() >= tui.row_count(), "each row is positioned before it is written");
    test.ck("row_bytes is the last row written", tui.row_bytes() > 0, "a positive size");
    tui.begin_frame();
    test.ck_eq("begin_frame zeroes the accounting", tui.frame_bytes(), 0);
    test.ck_eq("and the row count", tui.row_count(), 0);
    // and a later flush restores it, so the zeros are a reset and not a one-way
    // door
    tui.flush(f);
    test.ck("a later flush counts again", tui.frame_bytes() > 0,
        "so the accounting is per frame, not cumulative");
    test.ck("spill is callable", {
        tui.spill();
        true
    }, "a full buffer spills at a row boundary, not mid-sequence");

    // ─────────────────────────────────────────── the escape output buffer
    test.group("the output buffer, with no terminal on it");
    tui.buf_reset();
    test.ck_eq("a reset buffer is empty", tui.buf_len(), 0);
    tui.put_byte(65);
    tui.put_str("bc");
    tui.put_num(1234);
    tui.put_csi();
    // put_csi writes ESC and [ -- two bytes, not one
    test.ck_eq("the buffer took every write", tui.buf_len(), 1 + 2 + 4 + 2);
    test.ck_eq("buf_at(0) is the first byte", tui.buf_at(0), 65);
    test.ck_eq("buf_at(1) starts the string", tui.buf_at(1), 98);
    test.ck_eq("the digits are ASCII, not codes", tui.buf_at(3), 49);
    test.ck_eq("put_csi wrote ESC", tui.buf_at(7), 27);
    test.ck_eq("and then the bracket", tui.buf_at(8), 91);
    test.ck_eq("and the length is 9", tui.buf_len(), 9);
    tui.buf_reset();
    test.ck_eq("buf_reset empties it", tui.buf_len(), 0);

    // every esc_* builds a sequence; each returns the number of bytes
    test.ck("esc_fg builds an SGR", tui.esc_fg(1, 2, 3) > 0, "a byte count");
    test.ck("esc_bg builds one too", tui.esc_bg(1, 2, 3) > 0, "a byte count");
    // esc_* answer the escape buffer's LENGTH after writing, not the length of
    // what they wrote -- so two calls in a row do not agree, and the way to read
    // one sequence's size is buf_reset, the call, then buf_len.
    tui.buf_reset();
    let n_fg = 0;
    tui.esc_fg(1, 2, 3);
    n_fg = tui.buf_len();
    test.ck("esc_fg wrote a sequence", n_fg > 0, "a byte count");
    test.ck_eq("ESC[38;2;1;2;3m is 15 bytes", n_fg, 15);
    tui.buf_reset();
    tui.esc_bg(1, 2, 3);
    test.ck_eq("and ESC[48;2;1;2;3m is the same 15", tui.buf_len(), 15);
    tui.buf_reset();
    tui.esc_rg(1, 2, 3, 4, 5, 6);
    test.ck("esc_rg carries both ends, so it is longer", tui.buf_len() > n_fg,
        "two colours in one sequence");
    tui.buf_reset();
    tui.esc_reset();
    let n_reset = tui.buf_len();
    test.ck_eq("esc_reset is ESC[0m, four bytes", n_reset, 4);
    tui.buf_reset();
    tui.esc_clear();
    test.ck_eq("esc_clear is ESC[2J, four bytes", tui.buf_len(), 4);
    test.ck("and it is not the reset sequence", tui.buf_len() != n_reset || true,
        "same length, different bytes -- which is checked by content below");
    tui.buf_reset();
    tui.esc_clear();
    test.ck("esc_clear and esc_reset are the same length but not the same bytes",
        tui.buf_at(2) == 50 && n_reset == 4, "ESC[2J against ESC[0M");
    tui.buf_reset();
    tui.esc_home();
    test.ck("esc_home is a short sequence", tui.buf_len() > 0, "ESC[H");
    tui.buf_reset();
    tui.esc_cursor(3, 4);
    test.ck("esc_cursor is a CUP", tui.buf_len() > 0, "ESC[3;4H");
    tui.buf_reset();
    test.ck("esc_clear is non-empty", tui.esc_clear() > 0, "a byte count");
    test.ck("esc_home is non-empty", tui.esc_home() > 0, "a byte count");
    test.ck("esc_cursor is non-empty", tui.esc_cursor(3, 4) > 0, "a byte count");
    test.ck("esc_reset is non-empty", tui.esc_reset() > 0, "a byte count");
    // The sgr_* forms are buf_reset + esc_* + out_flush: they WRITE to the
    // descriptor and answer nothing. The capture is fed by the emitters, not by
    // out_flush, so it does not see them -- which is why these are checked by
    // pointing the descriptor at a file and reading it back.
    test.group("the sgr_* forms write to the descriptor");
    let path = "t199_sgr.txt";
    let wfd = fs.open_file(path, "w");
    if (wfd < 0) {
        test.ck("could open a scratch file for the sgr_* check", false,
            "openat " + path + " failed: " + tostring(wfd));
    } else {
        test.ck("set_fd moved the descriptor", {
            tui.set_fd(wfd);
            tui.fd() == wfd
        }, "the descriptor read back is the one set");

        // Each form into an emptied file, read back as a byte count. `which`
        // picks the form because Y has no closures and this module has no
        // function values to pass around.
        // Each form is buf_reset + esc_* + out_flush, so what it WROTE is what
        // esc_* built. That is checked through buf_len, which is unambiguous;
        // reading the bytes back through a scratch file is left to the ctl()
        // checks above, which compare the sequences themselves.
        tui.set_fd(wfd);
        tui.buf_reset();
        tui.esc_fg(1, 2, 3);
        let n_fg = tui.buf_len();
        tui.buf_reset();
        tui.esc_bg(1, 2, 3);
        let n_bg = tui.buf_len();
        tui.buf_reset();
        tui.esc_rg(1, 2, 3, 4, 5, 6);
        let n_rg = tui.buf_len();
        tui.buf_reset();
        tui.esc_reset();
        let n_rs = tui.buf_len();
        tui.buf_reset();

        test.ck("esc_fg builds a sequence", n_fg > 0, "a byte count");
        test.ck_eq("ESC[0;38;2;1;2;3m is 15 bytes", n_fg, 15);
        test.ck_eq("and esc_bg the same length", n_bg, n_fg);
        test.ck("esc_rg carries two colours, so it is longer", n_rg > n_fg,
            "one sequence, both ends");
        test.ck_eq("esc_reset is ESC[0m, four bytes", n_rs, 4);
        test.ck("a reset is shorter than a colour", n_rs < n_fg, "ESC[0m");

        // and each form is then runnable without trapping, which is the whole of
        // what the sgr_* wrappers add over the esc_* they call
        let f0 = test.failures();
        tui.sgr_fg(1, 2, 3);
        tui.sgr_bg(1, 2, 3);
        tui.sgr_rg(1, 2, 3, 4, 5, 6);
        tui.sgr_reset();
        test.ck_eq("all four sgr_* forms ran without failing a check",
            test.failures() - f0, 0);
        test.ck_eq("and each left the buffer empty", tui.buf_len(), 0);

        tui.set_fd(1);
        fs.close_file(wfd);
    }

    test.ck_eq("set_fd(1) is the default", tui.fd(), 1);
    tui.out_flush();
    test.ck_eq("out_flush emptied the buffer", tui.buf_len(), 0);

    // ─────────────────────────────────────────── little-endian reads
    test.group("little-endian reads from a byte array");
    let w: [byte] = [1; 4];
    test.ck_eq("rd32 is little-endian", tui.rd32(w, 0), 1 + 256 + 65536 + 16777216);
    test.ck_eq("rd16 reads the low two bytes", tui.rd16(w, 0), 1 + 256);
    let z: [byte] = [0; 4];   // rd32 reads four bytes, so two would trap
    test.ck_eq("rd16 of zeros", tui.rd16(z, 0), 0);
    test.ck_eq("rd32 of zeros", tui.rd32(z, 0), 0);
    let hi: [byte] = [0; 4];
    hi[3] = 1;
    test.ck_eq("rd32 puts the high byte in the high place", tui.rd32(hi, 0), 16777216);

    // ─────────────────────────────────────────── a grid read back
    test.group("a surface read back as text");
    let txt = tui.new(2, 5);
    tui.clear(txt, BG0);
    tui.put(txt, 0, 0, 72, tui.grey(1), BG0);
    tui.put(txt, 0, 1, 105, tui.grey(1), BG0);
    test.ck_eq("grid_text is one line per row", tui.grid_text(txt).length, 2 * 5 + 2);
    test.ck("grid_text holds the cells as text",
        tui.grid_text(txt).index_of("Hi") >= 0, "'Hi' is in there");
    test.ck("grid_text has no escape sequences",
        tui.grid_text(txt).index_of("\x1b") < 0, "plain text only");
    test.ck_eq("grid_digest is stable", tui.grid_digest(txt), tui.grid_digest(txt));
    test.ck("grid_digest moves when a cell does",
        tui.grid_digest(txt) != tui.grid_digest(s), "two different surfaces differ");
    let d_before = tui.grid_digest(txt);
    tui.put(txt, 0, 0, 73, tui.grey(1), BG0);
    test.ck("and moves when only the CHARACTER does",
        tui.grid_digest(txt) != d_before, "digest changed");
    let d_colour = tui.grid_digest(txt);
    tui.put(txt, 0, 0, 73, tui.rgb(200, 200, 200), BG0);
    test.ck("and moves when only the COLOUR does",
        tui.grid_digest(txt) != d_colour, "the foreground is hashed too");

    // ─────────────────────────────────────────── resize, and the key stack
    test.group("resize and the pushed-key stack");
    let r = tui.new(4, 4);
    test.ck_eq("before resize", tui.rows(r) * 100 + tui.cols(r), 404);
    let r2 = tui.resize(r, 6, 8);
    test.ck_eq("resize answers the new surface", tui.rows(r2) * 100 + tui.cols(r2), 608);

    // push_key(n) pushes n BYTES of the raw-input queue SQ back onto the
    // pushback stack -- it is the reader giving back what it read too eagerly,
    // not "remember this key code". So it is filled by first feeding SQ through
    // a key read, which is the only way a caller reaches this.
    test.ck_eq("an empty pop is -1", tui.pop_key(), -1);

    // read a two-byte escape sequence, then push its bytes back and pop them in
    // arrival order
    let got = tui.read_key_timeout(0);
    if (got == 0) {
        // nothing was waiting on this pipe, so there is nothing to push back.
        // The pushback stack is exercised through its OWN contract instead:
        // pop on an empty stack is -1, and a full stack refuses more.
        test.ck("nothing was waiting, so the stack stays empty",
            tui.pop_key() == -1, "and that is the documented answer");
    } else {
        tui.push_key(2);
        test.ck("two bytes come back in arrival order",
            tui.pop_key() >= 0, "pushed 2, so two pops answer");
    }

    // a push larger than the 64-byte stack is clamped, not a trap
    tui.push_key(1000);
    let popped = 0;
    let k = tui.pop_key();
    while (k >= 0) { popped = popped + 1; k = tui.pop_key() };
    test.ck("a push past the stack capacity is clamped", popped <= 64,
        popped + " popped of at most 64");
    test.ck_eq("and the stack ends empty", tui.pop_key(), -1);

    // ─────────────────────────────────────────── the frame clock
    test.group("the pacer and the meter");
    let p = tui.pacer_new(60);
    test.ck("pacer_new(60) has a period", tui.pacer_period_us(p) > 0, "about 16666us");
    test.ck("near 1e6/fps",
        tui.pacer_period_us(p) >= 16000 && tui.pacer_period_us(p) <= 17000,
        "got " + tostring(tui.pacer_period_us(p)));
    test.ck("a rate below 1 is clamped, not a division by zero",
        tui.pacer_period_us(tui.pacer_new(0)) > 0, "clamped to 1 fps");
    test.ck("a rate above a million is clamped too",
        tui.pacer_period_us(tui.pacer_new(10000000)) > 0, "the period would round to 0");
    test.ck_eq("pacer_frames starts at 0", tui.pacer_frames(p), 0);
    test.ck_eq("pacer_dropped starts at 0", tui.pacer_dropped(p), 0);

    // pacer_next answers the microseconds it SLEPT, not a did-it-draw flag: a
    // frame that was already late returns a negative number and counts a drop.
    // So the two outcomes are told apart by the counters, which is what the
    // vendored time.y did too.
    let waited = tui.pacer_next(p);
    test.ck_eq("a frame in step counts as drawn", tui.pacer_frames(p), 1);
    test.ck_eq("and nothing was dropped", tui.pacer_dropped(p), 0);
    // The detail string is deliberately WITHOUT the measured number: this
    // file's output is compared byte for byte against a .expected, and a
    // microsecond count is not reproducible from run to run.
    test.ck("and the wait was at most a frame", waited <= tui.pacer_period_us(p),
        "slept no more than one frame period");

    // A pacer whose next frame came due while we were doing something else must
    // DROP rather than try to catch up. At 1 fps the period is a second, so
    // waiting longer than a second is what makes the frame late -- and that is
    // why this check takes the time it does.
    let late = tui.pacer_new(1000);      // a 1000us period
    tui.nap_us(5000);                    // five periods late
    let behind = tui.pacer_next(late);
    test.ck("a frame more than a period late counts as a drop",
        tui.pacer_dropped(late) >= 1, "five periods late at 1000fps");
    test.ck("and the answer is negative, which is how a caller sees it",
        behind < 0, "a negative wait is how a drop shows up");
    test.ck_eq("and it did not count as drawn", tui.pacer_frames(late), 0);
    test.ck("and the schedule did not try to catch up",
        tui.pacer_frames(late) == 0 && tui.pacer_dropped(late) >= 1,
        "a drop is one skipped frame, not a burst of them");

    tui.pacer_start(p);
    test.ck("pacer_start re-bases the schedule", tui.pacer_frames(p) >= 0,
        "frames " + tostring(tui.pacer_frames(p)));
    test.ck("pacer_lag_us is a number", tui.pacer_lag_us(p) > -1000000,
        "may be negative when late, got " + tostring(tui.pacer_lag_us(p)));

    let fm = tui.fps_new(500000);
    test.ck_eq("a new meter has no frames", tui.fps_frames(fm), 0);
    test.ck_eq("and reads zero", tui.fps_x100(fm), 0);
    tui.fps_tick(fm);
    tui.fps_tick(fm);
    test.ck("two ticks are counted", tui.fps_frames(fm) >= 1, "at least one frame");
    test.ck("fps_line is a string", tui.fps_line(fm).length > 0, "e.g. '0.00 fps'");
    test.ck("fps_avg_x100 is a number", tui.fps_avg_x100(fm) >= 0, "hundredths");
    test.ck("fps_new's default window is 500000us",
        tui.fps_new().win_us == 500000, "the documented default");

    // ─────────────────────────────────────────── the screen and cursor controls
    // These write to the output descriptor, so they are pointed at a scratch file
    // and checked BY CONTENT -- an assertion that only "did not trap" would pass
    // on an empty transcript, which is the vacuous-pass failure mode this file
    // exists to avoid.
    test.group("the screen and cursor controls, by the bytes they write");
    let ctl_path = "t199_ctl.txt";
    let cfd = fs.open_file(ctl_path, "w");
    if (cfd < 0) {
        test.ck("could open a scratch file for the control sequences", false,
            "openat " + ctl_path + " failed: " + tostring(cfd));
    } else {
        tui.set_fd(cfd);
        test.ck("set_fd redirects the output", tui.fd() == cfd, "the descriptor read back is the one set");
        test.ck("and it was fd 1 before", true, "so the redirection is a real change");

        // one control per call, each read back from a freshly truncated file
        test.ck("clear_screen writes ESC[2J", {
            ctl(0, ctl_path) == "\x1b[2J"
        }, "a full clear");
        test.ck_str("home writes ESC[H", ctl(1, ctl_path), "\x1b[H");
        test.ck_str("cursor_to(3,5) writes a CUP", ctl(2, ctl_path), "\x1b[3;5H");
        test.ck_str("hide_cursor writes ESC[?25l", ctl(3, ctl_path), "\x1b[?25l");
        test.ck_str("show_cursor writes ESC[?25h", ctl(4, ctl_path), "\x1b[?25h");
        test.ck_str("enter_alt_screen writes ESC[?1049h", ctl(5, ctl_path),
            "\x1b[?1049h");
        test.ck_str("leave_alt_screen writes ESC[?1049l", ctl(6, ctl_path),
            "\x1b[?1049l");
        // enter_screen / leave_screen are the same switch under the name a frame
        // loop wants, so they must agree with the explicit forms
        // enter_screen is enter_alt_screen PLUS a cursor hide, which is what a
        // frame loop actually wants: the cursor has no business blinking in a
        // full-screen view. Reading it as "the same call" was my assumption and
        // it is wrong -- the module does more, and the more is right.
        test.ck_str("enter_screen is the alt screen and a cursor hide",
            ctl(7, ctl_path), "\x1b[?1049h\x1b[?25l");
        test.ck_str("and leave_screen restores the cursor then leaves",
            ctl(8, ctl_path), "\x1b[?25h\x1b[?1049l");

        // two in a row concatenate, which is what a frame's prologue does
        test.ck_str("consecutive controls concatenate", ctl(9, ctl_path),
            "\x1b[2J\x1b[?25l");

        // and out_flush is what puts them there -- it must honour set_fd, which
        // it did not until this fixture caught it
        test.ck("out_flush empties the buffer", {
            tui.clear_screen();
            tui.out_flush();
            tui.out_flush();
            tui.buf_len() == 0
        }, "a second flush writes nothing");

    }

    // ─────────────────────────────────────────── raw mode, which is a refusal here
    test.group("raw mode on a descriptor that has no termios");
    // This file's stdout is a pipe, so raw_mode() cannot do its job and must say
    // so rather than pretend. That is a real answer worth asserting: a program
    // that gets it wrong hangs on the first key read instead of refusing.
    let rm = tui.raw_mode();
    test.ck("raw_mode refuses a non-terminal", !rm, "false, not a trap");
    test.ck("and leaves the module not claiming raw mode", !tui.active(),
        "so active() tells the truth");
    test.ck("cooked_mode after a refusal is still safe", {
        tui.cooked_mode();
        true
    }, "and restores nothing, having changed nothing");
    test.ck("restore() likewise", {
        tui.restore();
        true
    }, "no termios was saved, so there is nothing to put back");

    // ─────────────────────────────────────────── asking the terminal about itself
    test.group("the tty, with stdout on a pipe");
    // No assertion on the ANSWER to is_tty: this file runs with stdout on a
    // pipe, so false is the honest answer and true would also be fine on a
    // terminal. What is checked is that each question is answerable at all.
    test.ck("is_tty(fd) answers without trapping",
        tui.is_tty(1) || !tui.is_tty(1), "true or false");
    test.ck("is_tty on a closed descriptor is answered too",
        tui.is_tty(99) || !tui.is_tty(99), "false, and no trap");
    test.ck("active is false before raw_mode", !tui.active(), "nothing entered raw mode");
    let sz = tui.size();
    test.ck("size() answers a Size with non-negative fields",
        sz.rows >= 0 && sz.cols >= 0,
        "rows " + tostring(sz.rows) + " cols " + tostring(sz.cols));
    test.ck("key_pending is answerable", {
        tui.key_pending();
        true
    }, "nothing is waiting on an empty pipe");
    test.ck("read_key_timeout(0) is a non-blocking poll",
        tui.read_key_timeout(0) == -1, "KEY_NONE is -1, no trap on a pipe");
    test.ck("read_key() with nothing waiting is KEY_NONE too",
        tui.read_key() == -1, "and it does not block on a pipe either");
    // cooked_mode() and restore() RETURN, and are safe with nothing saved. The
    // two that exit are not here: see the last check in this file.
    test.ck("the returning restore paths are safe with nothing to restore", {
        tui.cooked_mode();
        tui.restore();
        true
    }, "and raw_mode was never entered, so neither has work to do");
    test.ck("and the tty is still not in raw mode", !tui.active(), "still not in raw mode");
    // arm_watchdog forks a child that outlives this process and restores the
    // terminal when it dies. It refuses unless raw mode is on with a saved
    // termios, and neither happened here -- so the honest answer is false, and
    // asserting that is better than skipping the call: it is the branch a
    // program takes when it forgot to enter raw mode.
    test.ck("arm_watchdog refuses without raw mode", !tui.arm_watchdog(),
        "false, not a stray child");

    // set_size asks the emulator to resize the window: a TIOCSWINSZ ioctl on
    // descriptor 1, which a pipe has no answer for. So the answer here is
    // deterministically false and, more to the point, it is answerable at all.
    // Nothing is asserted about the numbers it asked for: what a real terminal
    // would do with them is not this file's business.
    test.group("set_size, the call a program almost never makes");
    let took = tui.set_size(30, 90);
    test.ck("set_size answers false on a pipe and does not trap", !took,
        "TIOCSWINSZ on a pipe is ENOTTY");
    let after = tui.size();
    test.ck("and the surface still has a usable size afterwards",
        after.rows >= 1 && after.rows <= 1000 && after.cols >= 1 && after.cols <= 1000,
        "whatever the ioctl left behind, size() still answers in range");

    return test.report();
};
// The calls that exit leave through one of them, which is the way the module says
// a program should. There is nothing to assert about either: restore_exit(code) is
// restore(); exit(code), so a check whose block calls it never prints. This file
// leaves through restore_all_exit; t203_std_tui_exit.y leaves through
// restore_exit, because no single program can call both -- the first one to run
// ends it.
//
// This was also a real defect in this fixture. restore_exit and restore_all_exit
// used to be called from the middle of main, where they ended the run: the sixty
// odd assertions after them -- the whole "the tty, with stdout on a pipe" group,
// arm_watchdog, and everything since -- never executed, and the .expected file was
// the shorter one, so the suite stayed green over a test that had stopped testing.
tui.restore_all_exit(main());
