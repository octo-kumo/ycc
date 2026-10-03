// dwarf.y — DWARF 4 line information for `ycc -g`.
//
// dwarf_sections(files, rows, text_addr, text_len, comp_dir) -> the
// .debug_info, .debug_abbrev and .debug_line sections elf.y appends past
// the loaded image (elf_debug). One compile unit, named after the
// program's root file, covers all of .text; all it holds is the line
// table, a row per `.loc` marker (asm.y debug_lines): per statement, per
// function entry, per `else if` test and per loop back edge (native.y
// dbg_lines). No types, variables or frames: tools map an address to
// file:line (addr2line, perf annotate, objdump -dl) and gdb breaks and
// steps by line; function names still come from the symbol table.
//
// files: the `.file` table, `.file N` at index N-1 (the root file first);
// rows: flat (code offset, file number, line) triples in text order;
// text_addr/text_len: where .text is loaded and its length (without the
// page padding); comp_dir: the directory relative paths start from.

// For its alias ElfSec.
import elf from "./elf.y";

def dwarf_sections(files: [str], rows: [long], text_addr: long, text_len: long, comp_dir: str) -> [ElfSec] {
    let root = "?";
    if (len(files) > 0) { root = files[0]; } else { };
    let out: [ElfSec] = [];
    out += { name: ".debug_info", data: dw_info(root, comp_dir, text_addr, text_len) };
    out += { name: ".debug_abbrev", data: dw_abbrev() };
    out += { name: ".debug_line", data: dw_line(files, rows, text_addr, text_len) };
    out
};

// The one abbreviation: code 1, DW_TAG_compile_unit (0x11), no children;
// DW_AT_producer (0x25), DW_AT_name (0x03) and DW_AT_comp_dir (0x1b) as
// DW_FORM_string (0x08), DW_AT_stmt_list (0x10) as DW_FORM_sec_offset
// (0x17), DW_AT_low_pc (0x11) as DW_FORM_addr (0x01), DW_AT_high_pc
// (0x12) as DW_FORM_data8 (0x07: a length, from DWARF 4 on); then the
// attribute list's and the table's terminators.
def dw_abbrev() -> [byte] {
    let b: [byte] = [1, 17, 0, 37, 8, 3, 8, 27, 8, 16, 23, 17, 1, 18, 7, 0, 0, 0];
    b
};

// The compile unit: its header (DWARF 4, abbreviations at offset 0,
// 8-byte addresses), then its one DIE in dw_abbrev's attribute order.
def dw_info(root: str, comp_dir: str, text_addr: long, text_len: long) -> [byte] {
    let die: [byte] = [1];
    die = dw_cstr(die, "ycc");
    die = dw_cstr(die, root);
    die = dw_cstr(die, comp_dir);
    die = dw_le(die, 0, 4);
    die = dw_le(die, text_addr, 8);
    die = dw_le(die, text_len, 8);
    let b: [byte] = [];
    // unit_length counts what follows it: version 2, abbreviation offset
    // 4, address size 1, the DIE
    b = dw_le(b, 7 + len(die), 4);
    b = dw_le(b, 4, 2);
    b = dw_le(b, 0, 4);
    b += 8;
    b += die;
    b
};

// The line table: its header, then the program (dw_program). After
// header_length: minimum_instruction_length 1,
// maximum_operations_per_instruction 1, default_is_stmt 1, line_base -5,
// line_range 14, opcode_base 13, the operand counts of the 12 standard
// opcodes; then include_directories and file_names, split the way gcc
// splits them: a path with a '/' files its last part under the directory
// before it (numbered from 1 in first-seen order), one without under
// directory 0 (the comp_dir); no mtimes or lengths, and a 0 ends each
// list. (A name never carries a directory: valgrind prefixes even an
// absolute name with its directory.)
def dw_line(files: [str], rows: [long], text_addr: long, text_len: long) -> [byte] {
    let hdr: [byte] = [1, 1, 1, 251, 14, 13, 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1];
    let dirs: [str] = [];
    let fdir: [long] = [];
    let fbase: [str] = [];
    foreach (fname in files) {
        let cut = len(fname) - 1;
        while (cut >= 0 && byte_at(fname, cut) != 47) {
            cut = cut - 1;
        };
        if (cut < 0) {
            fdir += 0;
            fbase += fname;
        } else {
            let d = "/";
            if (cut > 0) { d = fname[0:cut]; };
            let di = 0;
            for (let i = 0; i < len(dirs); i = i + 1) {
                if (di == 0 && dirs[i] == d) { di = i + 1; };
            };
            if (di == 0) {
                dirs += d;
                di = len(dirs);
            };
            fdir += di;
            fbase += fname[cut + 1:len(fname)];
        };
    };
    foreach (d in dirs) {
        hdr = dw_cstr(hdr, d);
    };
    hdr += 0;
    for (let i = 0; i < len(fbase); i = i + 1) {
        hdr = dw_cstr(hdr, fbase[i]);
        hdr = dw_uleb(hdr, fdir[i]);
        hdr += 0;
        hdr += 0;
    };
    hdr += 0;
    let prog = dw_program(rows, text_addr, text_len);
    let b: [byte] = [];
    // unit_length: version 2, header_length 4, the header, the program
    b = dw_le(b, 6 + len(hdr) + len(prog), 4);
    b = dw_le(b, 4, 2);
    b = dw_le(b, len(hdr), 4);
    b += hdr;
    b += prog;
    b
};

// The rows as one sequence over all of .text: DW_LNE_set_address to the
// first row, a row per triple, an advance to the end of .text, then
// DW_LNE_end_sequence. A row at the offset of the one before replaces it
// (that marker produced no code); one on the file and line of the one
// before adds nothing. A row is one special opcode when its line moves by
// -5..8 and its address by little enough; otherwise DW_LNS_advance_line
// and/or DW_LNS_advance_pc go first and the special opcode moves only
// what is left.
def dw_program(rows: [long], text_addr: long, text_len: long) -> [byte] {
    let keep: [long] = [];
    let i = 0;
    while (i + 2 < len(rows)) {
        let ro = rows[i];
        let rf = rows[i + 1];
        let rl = rows[i + 2];
        let n = len(keep);
        if (n > 0 && keep[n - 3] == ro) {
            keep[n - 2] = rf;
            keep[n - 1] = rl;
        } else if (n > 0 && keep[n - 2] == rf && keep[n - 1] == rl) {
        } else {
            keep += ro;
            keep += rf;
            keep += rl;
        };
        i = i + 3;
    };
    let b: [byte] = [];
    if (len(keep) > 0) {
        let addr = keep[0];
        // DW_LNE_set_address: extended opcode (0), 9 bytes, 2, the address
        b += 0;
        b += 9;
        b += 2;
        b = dw_le(b, text_addr + addr, 8);
        let cur_file = 1;
        let cur_line = 1;
        let j = 0;
        while (j < len(keep)) {
            let off = keep[j];
            let f = keep[j + 1];
            let l = keep[j + 2];
            if (f != cur_file) {
                // DW_LNS_set_file
                b += 4;
                b = dw_uleb(b, f);
                cur_file = f;
            };
            let dl = l - cur_line;
            if (dl < -5 || dl > 8) {
                // DW_LNS_advance_line
                b += 3;
                b = dw_sleb(b, dl);
                dl = 0;
            };
            let op = dl + 5 + 14 * (off - addr) + 13;
            if (op > 255) {
                // DW_LNS_advance_pc
                b += 2;
                b = dw_uleb(b, off - addr);
                op = dl + 5 + 13;
            };
            b += op;
            addr = off;
            cur_line = l;
            j = j + 3;
        };
        if (text_len > addr) {
            b += 2;
            b = dw_uleb(b, text_len - addr);
        };
        // DW_LNE_end_sequence: extended opcode (0), 1 byte, 1
        b += 0;
        b += 1;
        b += 1;
    };
    b
};

// v's low n bytes, little-endian (v >= 0).
def dw_le(out: [byte], v: long, n: long) -> [byte] {
    let x = v;
    let i = 0;
    while (i < n) {
        out += x % 256;
        x = x / 256;
        i = i + 1;
    };
    out
};

// Unsigned LEB128: 7 bits a byte, low first, the high bit set on every
// byte but the last (v >= 0).
def dw_uleb(out: [byte], v: long) -> [byte] {
    let x = v;
    let more = true;
    while (more) {
        let lo = x % 128;
        x = x / 128;
        if (x == 0) {
            out += lo;
            more = false;
        } else {
            out += lo + 128;
        };
    };
    out
};

// Signed LEB128: the same, until what is left is only sign -- 0 with bit
// 6 of the last byte clear, or -1 with it set. `/` rounds toward zero, so
// a negative x steps down by one to shift right arithmetically.
def dw_sleb(out: [byte], v: long) -> [byte] {
    let x = v;
    let more = true;
    while (more) {
        let q = x / 128;
        if (x < 0 && q * 128 != x) { q = q - 1; };
        let lo = x - q * 128;
        x = q;
        if ((x == 0 && lo < 64) || (x == -1 && lo >= 64)) {
            out += lo;
            more = false;
        } else {
            out += lo + 128;
        };
    };
    out
};

// A string's bytes and its NUL; "?" for an empty one (a lone NUL would
// end the list it is in).
def dw_cstr(out: [byte], s: str) -> [byte] {
    if (len(s) == 0) { out += 63; } else { out += bytes(s); };
    out += 0;
    out
};

export { dwarf_sections };
