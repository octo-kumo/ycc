/* dwarf.c — DWARF 4 line information for `ycc -g`.
 *
 * dwarf_sections(files, rows, text_addr, text_len, comp_dir) -> the
 * .debug_info, .debug_abbrev and .debug_line sections elf.y appends past
 * the loaded image (elf_debug). One compile unit, named after the
 * program's root file, covers all of .text; all it holds is the line
 * table, a row per `.loc` marker (asm.y debug_lines): per statement, per
 * function entry, per `else if` test and per loop back edge (native.y
 * dbg_lines). No types, variables or frames: tools map an address to
 * file:line (addr2line, perf annotate, objdump -dl) and gdb breaks and
 * steps by line; function names still come from the symbol table.
 *
 * files: the `.file` table, `.file N` at index N-1 (the root file first);
 * rows: flat (code offset, file number, line) triples in text order;
 * text_addr/text_len: where .text is loaded and its length (without the
 * page padding); comp_dir: the directory relative paths start from. */

#include "ylong.h"
#include "dwarf.h"

/* imported: elf.y, for its alias ElfSec only (a record is a Yv * here). */

static Yv *dw_abbrev(void);
static Yv *dw_info(Yv *root, Yv *comp_dir, ylong text_addr, ylong text_len);
static Yv *dw_line(Yv *files, Yv *rows, ylong text_addr, ylong text_len);
static Yv *dw_program(Yv *rows, ylong text_addr, ylong text_len);
static Yv *dw_le(Yv *out, ylong v, ylong n);
static Yv *dw_uleb(Yv *out, ylong v);
static Yv *dw_sleb(Yv *out, ylong v);
static Yv *dw_cstr(Yv *out, Yv *s);

Yv *dwarf_sections(Yv *files, Yv *rows, ylong text_addr, ylong text_len,
                   Yv *comp_dir) {
    Yv *root = ys("?");
    if (yv_len(files) > 0) {
        root = ya_get(files, 0);
        ;
    }
    Yv *out = yav(0);
    out = ya_push(out, yr(2, "name", ys(".debug_info"),
                          "data", dw_info(root, comp_dir, text_addr, text_len)));
    out = ya_push(out, yr(2, "name", ys(".debug_abbrev"), "data", dw_abbrev()));
    out = ya_push(out, yr(2, "name", ys(".debug_line"),
                          "data", dw_line(files, rows, text_addr, text_len)));
    return out;
}

/* The one abbreviation: code 1, DW_TAG_compile_unit (0x11), no children;
 * DW_AT_producer (0x25), DW_AT_name (0x03) and DW_AT_comp_dir (0x1b) as
 * DW_FORM_string (0x08), DW_AT_stmt_list (0x10) as DW_FORM_sec_offset
 * (0x17), DW_AT_low_pc (0x11) as DW_FORM_addr (0x01), DW_AT_high_pc
 * (0x12) as DW_FORM_data8 (0x07: a length, from DWARF 4 on); then the
 * attribute list's and the table's terminators. */
static Yv *dw_abbrev(void) {
    return yav(18,
               yv_long(1), yv_long(17), yv_long(0), yv_long(37), yv_long(8),
               yv_long(3), yv_long(8), yv_long(27), yv_long(8), yv_long(16),
               yv_long(23), yv_long(17), yv_long(1), yv_long(18), yv_long(7),
               yv_long(0), yv_long(0), yv_long(0));
}

/* The compile unit: its header (DWARF 4, abbreviations at offset 0,
 * 8-byte addresses), then its one DIE in dw_abbrev's attribute order. */
static Yv *dw_info(Yv *root, Yv *comp_dir, ylong text_addr, ylong text_len) {
    Yv *die = yav(1, yv_long(1));
    die = dw_cstr(die, ys("ycc"));
    die = dw_cstr(die, root);
    die = dw_cstr(die, comp_dir);
    die = dw_le(die, 0, 4);
    die = dw_le(die, text_addr, 8);
    die = dw_le(die, text_len, 8);
    Yv *b = yav(0);
    /* unit_length counts what follows it: version 2, abbreviation offset
     * 4, address size 1, the DIE */
    b = dw_le(b, 7 + yv_len(die), 4);
    b = dw_le(b, 4, 2);
    b = dw_le(b, 0, 4);
    b = ya_push(b, yv_long(8));
    ylong i = 0;
    while (i < yv_len(die)) {
        b = ya_push(b, ya_get(die, i));
        i = i + 1;
    }
    return b;
}

/* The line table: its header, then the program (dw_program). After
 * header_length: minimum_instruction_length 1,
 * maximum_operations_per_instruction 1, default_is_stmt 1, line_base -5,
 * line_range 14, opcode_base 13, the operand counts of the 12 standard
 * opcodes; then include_directories and file_names, split the way gcc
 * splits them: a path with a '/' files its last part under the directory
 * before it (numbered from 1 in first-seen order), one without under
 * directory 0 (the comp_dir); no mtimes or lengths, and a 0 ends each
 * list. (A name never carries a directory: valgrind prefixes even an
 * absolute name with its directory.) */
static Yv *dw_line(Yv *files, Yv *rows, ylong text_addr, ylong text_len) {
    Yv *hdr = yav(18,
                  yv_long(1), yv_long(1), yv_long(1), yv_long(251),
                  yv_long(14), yv_long(13), yv_long(0), yv_long(1),
                  yv_long(1), yv_long(1), yv_long(1), yv_long(0),
                  yv_long(0), yv_long(0), yv_long(1), yv_long(0),
                  yv_long(0), yv_long(1));
    Yv *dirs = yav(0);
    Yv *fdir = yav(0);
    Yv *fbase = yav(0);
    ylong fi = 0;
    while (fi < yv_len(files)) {
        Yv *fname = ya_get(files, fi);
        ylong cut = yv_len(fname) - 1;
        while (cut >= 0 && ys_byte_at(fname, cut) != 47) {
            cut = cut - 1;
        }
        if (cut < 0) {
            fdir = ya_push(fdir, yv_long(0));
            fbase = ya_push(fbase, fname);
            ;
        } else {
            Yv *d = ys("/");
            if (cut > 0) {
                d = ys_slice(fname, 0, cut);
                ;
            }
            ylong di = 0;
            ylong i = 0;
            while (i < yv_len(dirs)) {
                if (di == 0 && ys_eq(ya_get(dirs, i), d)) {
                    di = i + 1;
                    ;
                }
                i = i + 1;
            }
            if (di == 0) {
                dirs = ya_push(dirs, d);
                di = yv_len(dirs);
                ;
            }
            fdir = ya_push(fdir, yv_long(di));
            fbase = ya_push(fbase, ys_slice(fname, cut + 1, yv_len(fname)));
            ;
        }
        fi = fi + 1;
    }
    ylong i = 0;
    while (i < yv_len(dirs)) {
        hdr = dw_cstr(hdr, ya_get(dirs, i));
        i = i + 1;
    }
    hdr = ya_push(hdr, yv_long(0));
    i = 0;
    while (i < yv_len(fbase)) {
        hdr = dw_cstr(hdr, ya_get(fbase, i));
        hdr = dw_uleb(hdr, yv_l(ya_get(fdir, i)));
        hdr = ya_push(hdr, yv_long(0));
        hdr = ya_push(hdr, yv_long(0));
        i = i + 1;
    }
    hdr = ya_push(hdr, yv_long(0));
    Yv *prog = dw_program(rows, text_addr, text_len);
    Yv *b = yav(0);
    /* unit_length: version 2, header_length 4, the header, the program */
    b = dw_le(b, 6 + yv_len(hdr) + yv_len(prog), 4);
    b = dw_le(b, 4, 2);
    b = dw_le(b, yv_len(hdr), 4);
    i = 0;
    while (i < yv_len(hdr)) {
        b = ya_push(b, ya_get(hdr, i));
        i = i + 1;
    }
    i = 0;
    while (i < yv_len(prog)) {
        b = ya_push(b, ya_get(prog, i));
        i = i + 1;
    }
    return b;
}

/* The rows as one sequence over all of .text: DW_LNE_set_address to the
 * first row, a row per triple, an advance to the end of .text, then
 * DW_LNE_end_sequence. A row at the offset of the one before replaces it
 * (that marker produced no code); one on the file and line of the one
 * before adds nothing. A row is one special opcode when its line moves by
 * -5..8 and its address by little enough; otherwise DW_LNS_advance_line
 * and/or DW_LNS_advance_pc go first and the special opcode moves only
 * what is left. */
static Yv *dw_program(Yv *rows, ylong text_addr, ylong text_len) {
    Yv *keep = yav(0);
    ylong i = 0;
    while (i + 2 < yv_len(rows)) {
        ylong ro = yv_l(ya_get(rows, i));
        ylong rf = yv_l(ya_get(rows, i + 1));
        ylong rl = yv_l(ya_get(rows, i + 2));
        ylong n = yv_len(keep);
        if (n > 0 && yv_l(ya_get(keep, n - 3)) == ro) {
            ya_set(keep, n - 2, yv_long(rf));
            ya_set(keep, n - 1, yv_long(rl));
            ;
        } else if (n > 0 && yv_l(ya_get(keep, n - 2)) == rf &&
                   yv_l(ya_get(keep, n - 1)) == rl) {
            ;
        } else {
            keep = ya_push(keep, yv_long(ro));
            keep = ya_push(keep, yv_long(rf));
            keep = ya_push(keep, yv_long(rl));
            ;
        }
        i = i + 3;
    }
    Yv *b = yav(0);
    if (yv_len(keep) > 0) {
        ylong addr = yv_l(ya_get(keep, 0));
        /* DW_LNE_set_address: extended opcode (0), 9 bytes, 2, the address */
        b = ya_push(b, yv_long(0));
        b = ya_push(b, yv_long(9));
        b = ya_push(b, yv_long(2));
        b = dw_le(b, text_addr + addr, 8);
        ylong cur_file = 1;
        ylong cur_line = 1;
        ylong j = 0;
        while (j < yv_len(keep)) {
            ylong off = yv_l(ya_get(keep, j));
            ylong f = yv_l(ya_get(keep, j + 1));
            ylong l = yv_l(ya_get(keep, j + 2));
            if (f != cur_file) {
                /* DW_LNS_set_file */
                b = ya_push(b, yv_long(4));
                b = dw_uleb(b, f);
                cur_file = f;
                ;
            }
            ylong dl = l - cur_line;
            if (dl < -5 || dl > 8) {
                /* DW_LNS_advance_line */
                b = ya_push(b, yv_long(3));
                b = dw_sleb(b, dl);
                dl = 0;
                ;
            }
            ylong op = dl + 5 + 14 * (off - addr) + 13;
            if (op > 255) {
                /* DW_LNS_advance_pc */
                b = ya_push(b, yv_long(2));
                b = dw_uleb(b, off - addr);
                op = dl + 5 + 13;
                ;
            }
            b = ya_push(b, yv_long(op));
            addr = off;
            cur_line = l;
            j = j + 3;
        }
        if (text_len > addr) {
            b = ya_push(b, yv_long(2));
            b = dw_uleb(b, text_len - addr);
            ;
        }
        /* DW_LNE_end_sequence: extended opcode (0), 1 byte, 1 */
        b = ya_push(b, yv_long(0));
        b = ya_push(b, yv_long(1));
        b = ya_push(b, yv_long(1));
        ;
    }
    return b;
}

/* v's low n bytes, little-endian (v >= 0). */
static Yv *dw_le(Yv *out, ylong v, ylong n) {
    ylong x = v;
    ylong i = 0;
    while (i < n) {
        out = ya_push(out, yv_long(x % 256));
        x = x / 256;
        i = i + 1;
    }
    return out;
}

/* Unsigned LEB128: 7 bits a byte, low first, the high bit set on every
 * byte but the last (v >= 0). */
static Yv *dw_uleb(Yv *out, ylong v) {
    ylong x = v;
    int more = 1;
    while (more) {
        ylong lo = x % 128;
        x = x / 128;
        if (x == 0) {
            out = ya_push(out, yv_long(lo));
            more = 0;
            ;
        } else {
            out = ya_push(out, yv_long(lo + 128));
            ;
        }
    }
    return out;
}

/* Signed LEB128: the same, until what is left is only sign -- 0 with bit
 * 6 of the last byte clear, or -1 with it set. `/` rounds toward zero, so
 * a negative x steps down by one to shift right arithmetically. */
static Yv *dw_sleb(Yv *out, ylong v) {
    ylong x = v;
    int more = 1;
    while (more) {
        ylong q = x / 128;
        if (x < 0 && q * 128 != x) {
            q = q - 1;
            ;
        }
        ylong lo = x - q * 128;
        x = q;
        if ((x == 0 && lo < 64) || (x == -1 && lo >= 64)) {
            out = ya_push(out, yv_long(lo));
            more = 0;
            ;
        } else {
            out = ya_push(out, yv_long(lo + 128));
            ;
        }
    }
    return out;
}

/* A string's bytes and its NUL; "?" for an empty one (a lone NUL would
 * end the list it is in). */
static Yv *dw_cstr(Yv *out, Yv *s) {
    if (yv_len(s) == 0) {
        out = ya_push(out, yv_long(63));
        ;
    } else {
        Yv *bs = bytes_of(s);
        ylong i = 0;
        while (i < yv_len(bs)) {
            out = ya_push(out, ya_get(bs, i));
            i = i + 1;
        }
        ;
    }
    out = ya_push(out, yv_long(0));
    return out;
}
