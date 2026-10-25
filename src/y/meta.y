// Compile-time source generation and its process runner.
// Generators execute anonymous ELF files in forked children via execveat.
// The kernel supplies their stack and maps their segments; fd 3 carries the
// framed pieces, and the parent drains it before waiting for the child.

// Only the lexer: lit_end is the literal scanner, and the pass must not
// import native.y (native.y imports this file -- see the driver note).
import hostos from "./host_linux.y";
import lexer from "./lexer.y";

def leading_long(s: str) -> long {
    let n = len(s);
    let i = 0;
    let go = true;
    while (i < n && go) {
        let c = s[i];
        if (c == 32 || (c >= 9 && c <= 13)) { i++; } else { go = false; };
    };
    let neg = false;
    if (i < n) {
        let sg = s[i];
        if (sg == 45 || sg == 43) { neg = sg == 45; i++; };
    };
    let v = 0;
    let any = false;
    let clamp = false;
    while (i < n) {
        let c = s[i];
        if (c >= 48 && c <= 57) {
            let d = c - 48;
            if (!clamp) {
                if (v > 922337203685477580) { clamp = true; }
                else if (v == 922337203685477580 && d > (if (neg) { 8 } else { 7 })) { clamp = true; }
                else { v = v * 10 + d; };
            };
            any = true;
            i++;
        } else { i = n; };
    };
    if (!any) {
        0
    } else if (clamp) {
        if (neg) { -9223372036854775807 - 1 } else { 9223372036854775807 }
    } else if (neg) {
        0 - v
    } else { v }
};

// ── little-endian reads and writes ──────────────────────────────────────

// ── M2: the pass ────────────────────────────────────────────────────────

// Whether the pass runs at all. Off while G is compiled, on for the program.
let mg_on = false;
// The next slot index. Slots are global and in RESOLVE order (the program's
// own file first, then its modules as the splicer visits them), which is the
// order the generator runs them in.
let mg_next = 0;
// G's body: the files' lines with each block as a call, and the source line
// each of those lines came from.
let mg_g: [str] = [];
let mg_gol: [long] = [];
// Each block: its slot, the file and line of its `#{`, and -- for a block at
// file scope, whose text P really does drop -- the line of P and the byte
// offset in that line the piece goes at. A nested block's text lives inside
// its parent's call, so it has no P position.
let mg_bslot: [long] = [];
let mg_bfile: [long] = [];
let mg_bline: [long] = [];
let mg_bp: [long] = [];
let mg_bpo: [long] = [];
// The imports hoisted out of blocks, and the line each is reported at.
let mg_imp: [str] = [];
let mg_iol: [long] = [];
let mg_piece: [str] = [];
let mg_have: [bool] = [];
// How many blocks the whole resolve found, and whether any.
let mg_n = 0;
// How many of them sit inside another block. A program with none is the common
// case and costs exactly one compile of the generator, whatever else changes
// here (meta_prepare: mg_nest is what decides whether the rounds run at all).
let mg_nest = 0;
// Did each block's CHILDREN all have their text when it opened? A block whose
// own source wanted a nested block's text cannot produce its text until it has
// it, so the answer says whether the piece this round produced is the real one
// (mg_commit keeps it) or a stand-in to throw away.
let mg_bok: [bool] = [];
// Did each block's call go into this round's G? A block that did not is one
// whose text was already in the table and was spliced into the block around it,
// or one inside such text, so it neither runs nor owes the table anything.
let mg_live: [bool] = [];
// Does each block's text have to exist at all? Always for a top-level one -- it
// goes into the program. For a nested one, only while the block around it is
// being compiled: inside text that was spliced whole, the text is already there.
let mg_need: [bool] = [];
let mg_bkids: [bool] = [];
// The emitted-text size cap (R8 is not negotiable). The piece table is read
// into memory, so this is what bounds it.
const MG_MAX = 33554432;
const MG_NEST = 8;
// How many rounds meta_prepare will do before it calls the round logic broken.
// One round per level of nesting plus one for a program that has none, so a
// program the scanner accepted cannot reach it.
const MG_ROUND = MG_NEST + 2;
let mg_reduce = false;
// The collecting scan: the one that finds the blocks, before anything is known.
// It never holds a block's text and never reduces, so the G it builds for a
// program with no nesting is the G the pass has always built.
let mg_collect = true;

type Scan = { ok: bool, err: str, eline: long, ecol: long,
    p: [str], pf: [long], pol: [long], gen: [bool],
    g: [str], gf: [long], gol: [long] };

def scan_bad(err: str, line: long, col: long) -> Scan {
    { ok: false, err: err, eline: line, ecol: col, p: [], pf: [], pol: [],
        gen: [], g: [], gf: [], gol: [] }
};

def scan_none(src: str, fid: long) -> Scan {
    let lines = split(src, "\n");
    let f: [long] = [];
    let l: [long] = [];
    let i = 0;
    let gn: [bool] = [];
    while (i < len(lines)) {
        f += fid;
        l += i + 1;
        gn += false;
        i++;
    };
    { ok: true, err: "", eline: 0, ecol: 0, p: lines, pf: f, pol: l, gen: gn,
        g: lines, gf: f, gol: l }
};

// ── byte classes (the lexer's own predicates, spelled here because they are
// not exported, and they must agree with lexer.y's wordbyte/isspace) ──────

def m_word(c: long) -> bool {
    c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9')
};

def m_blank(c: long) -> bool {
    [' ', '\t', '\n', '\r'].index(c) >= 0
};

// The word at src[i], i known to be a word byte.
def m_word_at(src: str, i: long, n: long) -> str {
    let j = i + 1;
    while (j < n && m_word(src[j])) { j = j + 1; };
    src[i:j]
};

// Whether every byte of s is a blank.
def m_all_blank(s: str) -> bool {
    let ok = true;
    let i = 0;
    while (ok && i < len(s)) {
        if (!m_blank(s[i])) { ok = false; };
        i++;
    };
    ok
};

// The byte before src[i] (i > 0), or 0.

def m_token_end(c: long) -> bool {
    if (c == 0) { false }
    else if ([')', ']', '}', '.', '\'', '\"'].index(c) >= 0) { true }
    else { m_word(c) }
};

def rd16(b: [byte], at: long) -> long {
    b[at] + b[at + 1] * 256
};

def rd32(b: [byte], at: long) -> long {
    b[at] + b[at + 1] * 256 + b[at + 2] * 65536 + b[at + 3] * 16777216
};

def rd64(b: [byte], at: long) -> long {
    (rd32(b, at)) + (rd32(b, at + 4)) * 4294967296
};

// One byte written into a byte array.
type Img = { ok: bool, err: str, filesz: long, memsz: long, entry: long,
    bss_delta: long, bss_len: long };

def img_bad(e: str) -> Img {
    { ok: false, err: e, filesz: 0, memsz: 0, entry: 0, bss_delta: 0, bss_len: 0 }
};

def img_ok(bss_delta: long, bss_len: long, entry: long, filesz: long, memsz: long) -> Img {
    { ok: true, err: "", filesz: filesz, memsz: memsz, entry: entry,
        bss_delta: bss_delta, bss_len: bss_len }
};

def elf_img(b: [byte]) -> Img {
    let n = len(b);
    if (n < 120) {
        img_bad("the image is too small to be an ELF file")
    } else if (b[0] != 127 || b[1] != 69 || b[2] != 76 || b[3] != 70) {
        img_bad("the image is not an ELF file")
    } else if (b[4] != 2 || b[5] != 1) {
        img_bad("the image is not a little-endian ELF64 file")
    } else {
        elf_img_ph(b, n)
    }
};

def elf_img_ph(b: [byte], n: long) -> Img {
    let entry = rd64(b, 24);
    let phoff = rd64(b, 32);
    let phentsize = rd16(b, 54);
    let phnum = rd16(b, 56);
    if (phentsize < 56 || phoff + phentsize * phnum > n || phnum < 1) {
        img_bad("the image's program headers are out of range")
    } else {
        let base = rd64(b, phoff + 16);
        let filesz = rd64(b, phoff + 32);
        let memsz = rd64(b, phoff + 40);
        let eoff = entry - base;
        if (filesz > n || memsz < filesz || eoff < 0 || eoff >= filesz) {
            img_bad("the image's entry point is outside its own code")
        } else if (phnum < 2) {
            img_ok(0, 0, eoff, filesz, memsz)
        } else {
            elf_img_bss(b, n, phoff, phentsize, phnum, base, eoff, filesz, memsz)
        }
    }
};

def elf_img_bss(b: [byte], n: long, phoff: long, phentsize: long, phnum: long,
    base: long, eoff: long, filesz: long, memsz: long) -> Img {
    let k = 1;
    let found = false;
    let vaddr = 0;
    let msize = 0;
    while (k < phnum && !found) {
        let ph = phoff + k * phentsize;
        if (rd32(b, ph + 4) == 6) {
            found = true;
            vaddr = rd64(b, ph + 16);
            msize = rd64(b, ph + 40);
        };
        k++;
    };
    if (!found) {
        img_ok(0, 0, eoff, filesz, memsz)
    } else if (msize > 0 && vaddr >= base) {
        img_ok(vaddr - base, msize, eoff, filesz, memsz)
    } else {
        img_bad("the image's .bss segment is out of range")
    }
};

// ── generator process ───────────────────────────────────────────────────
type RunRes = { ok: bool, status: long, sig: long, out: [byte], err: str };

// Linux process primitives used by the generator runner.
const SYS_READ = 0;
const SYS_WRITE = 1;
const SYS_CLOSE = 3;
const SYS_PIPE = 22;
const SYS_DUP2 = 33;
const SYS_FCNTL = 72;
const F_DUPFD = 0;
const SYS_MEMFD = 319;
const SYS_WAIT4 = 61;
const GUEST_FD = 3;

def run_fail(e: str) -> RunRes {
    { ok: false, status: -1, sig: 0, out: [], err: e }
};

def run_image(b: [byte], av: [str], want_out: bool) -> RunRes {
    let im = elf_img(b);
    if (!im.ok) {
        run_fail(im.err)
    } else {
        run_image_exec(b, av, want_out)
    }
};

def pipe_fds() -> { ok: bool, rfd: long, wfd: long } {
    let pf: [byte; 8] = [0; 8];
    if (syscall(hostos.nr(SYS_PIPE), &pf[0], 0, 0, 0, 0) != 0) {
        { ok: false, rfd: -1, wfd: -1 }
    } else {
        let r = rd32(pf[0:8], 0);
        let w = rd32(pf[0:8], 4);
        let r2 = syscall(hostos.nr(SYS_FCNTL), r, F_DUPFD, GUEST_FD + 1, 0, 0);
        let w2 = syscall(hostos.nr(SYS_FCNTL), w, F_DUPFD, GUEST_FD + 1, 0, 0);
        syscall(hostos.nr(SYS_CLOSE), r, 0, 0, 0, 0);
        syscall(hostos.nr(SYS_CLOSE), w, 0, 0, 0, 0);
        if (r2 < 0 || w2 < 0) {
            if (r2 >= 0) { syscall(hostos.nr(SYS_CLOSE), r2, 0, 0, 0, 0); };
            if (w2 >= 0) { syscall(hostos.nr(SYS_CLOSE), w2, 0, 0, 0, 0); };
            { ok: false, rfd: -1, wfd: -1 }
        } else {
            { ok: true, rfd: r2, wfd: w2 }
        }
    }
};

// The kernel loads this anonymous executable; its .bss need not be stored.
def image_fd(b: [byte]) -> long {
    let fd = syscall(hostos.nr(SYS_MEMFD), "ycc-image", 1);
    if (fd < 0) { return -1; };
    if (fd <= GUEST_FD) {
        let moved = syscall(hostos.nr(SYS_FCNTL), fd, F_DUPFD, GUEST_FD + 1);
        syscall(hostos.nr(SYS_CLOSE), fd);
        fd = moved;
        if (fd < 0) { return -1; };
        syscall(hostos.nr(SYS_FCNTL), fd, 2, 1);
    };
    let at = ptr_addr(&b[0]);
    let off = 0;
    while (off < len(b)) {
        let count = syscall(hostos.nr(SYS_WRITE), fd, at + off, len(b) - off);
        if (count <= 0) { syscall(hostos.nr(SYS_CLOSE), fd); return -1; };
        off += count;
    };
    fd
};

// Execute the anonymous ELF through the kernel. This avoids manufacturing a
// stack and entering machine code on a foreign frame, so a hosted C bootstrap
// can use the same runner. Only the child redirects fd 3.
def run_image_exec(b: [byte], av: [str], want_out: bool) -> RunRes {
    let pp = { ok: true, rfd: -1, wfd: -1 };
    if (want_out) { pp = pipe_fds(); };
    if (!pp.ok) { return run_fail("cannot create a pipe for the generator"); };
    let fd = image_fd(b);
    if (fd < 0) {
        if (pp.rfd >= 0) { syscall(hostos.nr(SYS_CLOSE), pp.rfd); syscall(hostos.nr(SYS_CLOSE), pp.wfd); };
        return run_fail("cannot make an anonymous file for the image");
    };
    let pid = syscall(hostos.nr(57), 17, 0, 0, 0, 0);
    if (pid == 0) {
        if (pp.rfd >= 0) {
            syscall(hostos.nr(SYS_CLOSE), pp.rfd);
            syscall(hostos.nr(SYS_DUP2), pp.wfd, GUEST_FD, 0);
            syscall(hostos.nr(SYS_CLOSE), pp.wfd);
        };
        let strings: [[byte]] = [];
        let ptrs: [long] = [];
        foreach (arg in av) {
            let text = bytes(arg);
            text += 0;
            strings += [text];
        };
        foreach (text in strings) { ptrs += ptr_addr(&text[0]); };
        ptrs += 0;
        let ex = syscall(hostos.nr(322), fd, "", &ptrs[0], 0, 4096);
        if (ex == -38 || ex == -2) {
            syscall(hostos.nr(SYS_FCNTL), fd, 2, 0);
            let path = "/proc/self/fd/" + tostring(fd);
            syscall(hostos.nr(59), path, &ptrs[0], 0);
        };
        exit(127);
    };
    syscall(hostos.nr(SYS_CLOSE), fd);
    if (pp.wfd >= 0) { syscall(hostos.nr(SYS_CLOSE), pp.wfd); };
    if (pid < 0) {
        if (pp.rfd >= 0) { syscall(hostos.nr(SYS_CLOSE), pp.rfd); };
        return run_fail("cannot fork the generator");
    };
    let out: [byte] = [];
    if (pp.rfd >= 0) {
        let buf: [byte; 65536] = [0; 65536];
        let at = ptr_addr(&buf[0]);
        let more = true;
        while (more) {
            let count = syscall(hostos.nr(SYS_READ), pp.rfd, at, 65536);
            if (count <= 0) { more = false; }
            else if (len(out) <= MG_MAX) { out += buf[0:count]; };
        };
        syscall(hostos.nr(SYS_CLOSE), pp.rfd);
    };
    let ws: [byte; 8] = [0; 8];
    syscall(hostos.nr(SYS_WAIT4), pid, &ws[0], 0, 0, 0);
    let status = rd32(ws[0:8], 0);
    let low = status % 128;
    { ok: true, status: (low == 0 ? (status / 256) % 256 : 0),
        sig: (low == 0 || low == 127 ? 0 : low), out: out, err: "" }
};

// ── the scanner ─────────────────────────────────────────────────────────

let sg_src = "";
let sg_fid = 0;
// The dir of the file being scanned: a hoisted import path normalizes against
// it, not against G's own dir.
let sg_dir = "";
// P: the program's text, each block's bytes dropped. G: the generator's, each
// block's bytes replaced by the call. Both as (line, file, source line).
let sg_p: [str] = [];
let sg_pf: [long] = [];
let sg_pol: [long] = [];
// Which P lines a block's piece is: filled by mg_splice, read back as
// sc.gen. All false until the pieces arrive (the collecting pass).
let sg_gen: [bool] = [];
let sg_g: [str] = [];
let sg_gf: [long] = [];
let sg_gol: [long] = [];
// The lines being built, and the source line each started at. A P line can
// span several source lines -- a block covering lines 4-7 makes P's line 4
// hold all four -- so sg_pline is where the line STARTED, not where it ended.
let sg_pbuf = "";
let sg_gbuf = "";
let sg_pline = 1;
let sg_gline = 1;
// Where the current G line starts inside sg_gbuf: what is between it and the
// end is the code since the last newline, and that decides statement position.
let sg_gat = 0;
// ── the mid-token buffers ────────────────────────────────────────────────
let sg_mmid = false;
let sg_mbuf = "";
let sg_mol: [long] = [];
let sg_molast = false;
let sg_mline = 1;
// The buffer of an enclosing block, saved while a nested one is held and
// restored when it closes (so the nested call is hoisted out of it, not written
// into it).
let sg_midsave: [str] = [];
let sg_molsave: [[long]] = [];
let sg_mlastsave: [bool] = [];
let sg_mlinesave: [long] = [];
// The G line each held buffer started at, and the one for the file's own buffer.
// sg_restore needs it to name the line the text after a held block continues,
// and sg_drop to put it back where it was -- a dropped block's lines are gone,
// so nothing may carry on counting from them.
let sg_glsave: [long] = [];
let sg_glsaved = 1;
// The hoisted calls, in CLOSE order: innermost first, then siblings in source
// order -- which is exactly the order they have to run in. Each carries the
// top-level statement it belongs to, so the move can order them per statement.
type MidMove = { line: long, off: long, text: [str], ol: [long] };
let sg_mids: [MidMove] = [];
// The top-level statement in progress: its first token's position, and whether
// one has been found yet (before it, everything is blanks and comments).
let sg_tsline = 1;
let sg_tsoff = 0;
let sg_tsp = false;
// The depth of the innermost held block, 0 for none, recomputed by sg_m_live
// whenever a block closes. A top-level `;` or `}` only ends a statement when no
// block is held, so the anchor cannot land inside one of these hoisted calls.
let sg_mdepth = 0;
let sg_line = 1;
let sg_col = 1;
// 0 code, 1 a `//` comment, 2 a `/* */` comment, 3 a literal.
let sg_state = 0;
// True when the next byte of code position may start a `def`, a `type`, an
// `import` or a refused name: after a newline, a `;`, a `{`, a `}` or a `#{`.
// Those are the only places a keyword can be, so the word is only read there --
// which is what keeps this a byte scan and not a parse.
let sg_bound = false;
// The brace stack: 0 an ordinary brace, 1 a `def` body, 2 a `type` body. A block
// may not open while any 1 or 2 is on the stack, nor while sg_pending is set
// (the `def` keyword itself, so the header's parameter list counts as the body
// too). sg_tkind is what is being declared: 0 a `def`, 2 a `type`.
let sg_bkind: [long] = [];
let sg_tkind = 0;
let sg_pending = false;
// Per open block: whether only blanks have been seen since its `#{` (an
// import is only hoistable then), the brace depth at its `#{`, whether it is in
// statement position, and whether it is mid-token (its call is hoisted, so the
// bytes after its `}#` belong to the file's own G, not to its buffer).
let sg_bclean: [bool] = [];
let sg_bbrace: [long] = [];
let sg_bstmt: [bool] = [];
let sg_bmid: [bool] = [];
let sg_bslot: [long] = [];
let sg_bok: [bool] = [];
let sg_bsplice: [bool] = [];
let sg_bdead: [bool] = [];
let sg_bhold: [bool] = [];
let sg_depth = 0;
let sg_rfrom = 0;
let sg_rtext = "";
let sg_rgline = 1;
let sg_rbrace = 0;
let sg_rkeep = false;
let sg_rblk = false;
let sg_rpend = true;
// The block array index this file's first block takes, and the P line a block
// being opened sits on (-1 for a nested one, whose text P does not hold).
let mg_first = 0;
let mg_p_at = -1;
// The first diagnostic, and where. The rest of the text is not scanned.
let sg_err = "";
let sg_eline = 0;
let sg_ecol = 0;

def sg_reset(src: str, fid: long, dir: str) -> void {
    sg_src = src;
    sg_fid = fid;
    sg_dir = dir;
    sg_p = [];
    sg_pf = [];
    sg_pol = [];
    sg_gen = [];
    sg_g = [];
    sg_gf = [];
    sg_gol = [];
    sg_pbuf = "";
    sg_gbuf = "";
    sg_pline = 1;
    sg_gline = 1;
    sg_gat = 0;
    sg_line = 1;
    sg_col = 1;
    sg_state = 0;
    // true, not false: line 1's first word is a keyword position like any
    // other, so a file whose first line is `def`/`import` is seen
    sg_bound = true;
    sg_bkind = [];
    sg_pending = false;
    sg_bclean = [];
    sg_bbrace = [];
    sg_bstmt = [];
    sg_bslot = [];
    sg_bok = [];
    sg_bsplice = [];
    sg_bdead = [];
    sg_bhold = [];
    sg_depth = 0;
    sg_err = "";
    sg_eline = 0;
    sg_ecol = 0;
    sg_mmid = false;
    sg_mbuf = "";
    sg_mol = [];
    sg_molast = false;
    sg_mline = sg_gline;
    sg_mids = [];
    sg_tsline = 1;
    sg_tsoff = 0;
    sg_tsp = true;
    sg_mdepth = 0;
    sg_glsaved = 1;
    sg_glsave = [];
    sg_region_open()
};

// Append text to whichever G buffer is live: the file's own, or a held block's
// (its call is written there and hoisted afterwards, so it does not sit where
// the block stood). Blocks nest, so `mid` is the innermost block's.
def sg_gadd(t: str, mid: bool) -> void {
    if (mid) { sg_mbuf += t } else { sg_gbuf += t };
};

// Hold this block's text: from here to its `}#` it goes to a buffer of its own
// and nowhere else. sg_restore puts it back where it came from; sg_drop throws
// it away. Nothing is written to the live buffer meanwhile, which is what makes
// both safe.
def sg_hold() -> void {
    sg_midsave += sg_mbuf;
    sg_molsave += sg_mol;
    sg_mlastsave += sg_molast;
    sg_mlinesave += sg_mline;
    sg_glsave += sg_glsaved;
    sg_mmid = true;
    sg_mdepth = sg_depth;
    sg_glsaved = sg_gline;
    sg_mbuf = "";
    sg_mol = [];
    sg_molast = false;
    sg_mline = sg_gline;
};

// The enclosing block's buffer back, whatever this one did with its own.
def sg_m_pop() -> long {
    sg_mbuf = sg_midsave[len(sg_midsave) - 1];
    sg_midsave = sg_midsave[0:len(sg_midsave) - 1];
    sg_mol = sg_molsave[len(sg_molsave) - 1];
    sg_molsave = sg_molsave[0:len(sg_molsave) - 1];
    sg_molast = sg_mlastsave[len(sg_mlastsave) - 1];
    sg_mlastsave = sg_mlastsave[0:len(sg_mlastsave) - 1];
    sg_mline = sg_mlinesave[len(sg_mlinesave) - 1];
    sg_mlinesave = sg_mlinesave[0:len(sg_mlinesave) - 1];
    sg_glsaved = sg_glsave[len(sg_glsave) - 1];
    sg_glsave = sg_glsave[0:len(sg_glsave) - 1];
    0
};

def sg_restore(pre: str, post: str) -> long {
    let segs = mg_lines(sg_mbuf);
    let last = len(segs) - 1;
    let i = 0;
    if (pre != "") { sg_gbuf += pre };
    while (i < len(segs)) {
        if (i < last) {
            sg_gbuf += segs[i];
            sg_g += sg_gbuf;
            sg_gf += sg_fid;
            if (i < len(sg_mol)) { sg_gol += sg_mol[i] } else { sg_gol += sg_gline };
            sg_gbuf = "";
        } else {
            sg_gbuf += segs[i];
        };
        i++;
    };
    if (post != "") { sg_gbuf += post };
    if (sg_molast) { sg_gline = sg_mline };
    sg_gat = 0;
    sg_m_pop()
};

// The held text, thrown away: the block's lines are not in G and not in P, so
// the line counter goes back to where the buffer began -- the text that follows
// the block continues the line the block started on, not one of its own.
def sg_drop() -> void {
    sg_gline = sg_glsaved;
    sg_m_pop()
};

def sg_splice(slot: long, at: long) -> void {
    let lines = mg_lines(mg_piece[slot]);
    let last = len(lines) - 1;
    lines.foreach((e, i) => {
        sg_mbuf += e;
        if (i < last) {
            sg_mol += at;
            sg_mbuf += "\n";
            sg_molast = false;
            sg_gline = at;
        };
    });
};

// One piece of text, into both buffers. A byte inside a block reaches G only:
// P has to drop the block whole. Blanks do not count towards the enclosing
// block's "nothing but blanks yet" flag, which is what decides whether an
// `import` there is at the block's top level.
def sg_put(t: str) -> void {
    if (len(t) > 0) {
        let mid = sg_mmid;
        if (!mid) { sg_ts_go(t) } else { sg_molast = sg_ml_go(t) };
        sg_gadd(t, mid);
        if (sg_depth == 0) {
            sg_pbuf += t;
        } else if (!m_all_blank(t)) {
            sg_bclean[sg_depth - 1] = false;
        };
        sg_col += len(t);
    };
};

// One byte that is never a blank: a delimiter, or a word's first byte.
def sg_put1(c: str) -> void {
    if (sg_mmid) { if (!sg_molast) { sg_molast = true } }
    else { sg_ts_go(c) };
    sg_gadd(c, sg_mmid);
    if (sg_depth == 0) {
        sg_pbuf += c;
    } else {
        sg_bclean[sg_depth - 1] = false;
    };
    sg_col++;
};

def sg_ts_go(t: str) -> void {
    if (!sg_tsp) {
        let i = 0;
        let go = true;
        while (go && i < len(t)) {
            if (!m_blank(t[i])) {
                sg_tsline = sg_gline;
                sg_tsoff = len(sg_gbuf) + i;
                sg_tsp = true;
                go = false;
            };
            i++;
        };
    };
};

// The source line a mid-token buffer's LAST line started at: the first byte of
// `t` that is not a blank, if there is one and none has been found yet (the
// line began when the buffer began, at whatever `}`#` came closest to).
def sg_ml_go(t: str) -> bool {
    if (sg_molast) { true }
    else {
        for i in 0..len(t) {
            if (!m_blank(t[i])) {
                sg_molast = true;
                sg_mline = sg_gline;
                i = len(t);
            };
        };
        sg_molast
    }
};

// A top-level statement ends here, so the next one starts after what follows.
def sg_ts_end() -> void {
    sg_tsp = false;
};

def sg_break() -> void {
    if (sg_mmid) {
        sg_mol += sg_gline;
        sg_mbuf += "\n";
    } else {
        sg_g += sg_gbuf;
        sg_gf += sg_fid;
        sg_gol += sg_gline;
    };
    sg_gbuf = "";
    sg_gline = sg_line + 1;
    sg_gat = 0;
    if (sg_depth == 0) {
        sg_p += sg_pbuf;
        sg_pf += sg_fid;
        sg_pol += sg_pline;
        sg_pbuf = "";
        sg_pline = sg_line + 1;
    };
    sg_line++;
    sg_col = 1;
};

// sg_src[a:b] into both buffers, breaking lines on the newlines it holds. So
// a literal or a comment that spans lines costs the lines it really has, and
// the two texts stay in step with the source without either counting.
def sg_out(a: long, b: long) -> void {
    let i = a;
    while (i < b) {
        let nl = -1;
        let j = i;
        let go = true;
        while (go && j < b) {
            if (sg_src[j] == 10) { nl = j; go = false; } else { j = j + 1; };
        };
        if (nl < 0) {
            sg_put(sg_src[i:b]);
            i = b;
        } else {
            sg_put(sg_src[i:nl]);
            sg_break();
            i = nl + 1;
        };
    };
};

// Set while `mg_probe` scans: the probe is asking "is there a block in this
// text", not "is this text a legal file", so it must read PAST a diagnostic
// (the text it is given is G's own, whose `ycc_meta_stmt` calls the program's
// own pass would refuse) instead of stopping at the first one.
let sg_quiet = false;

def sg_fail(msg: str, line: long, col: long) -> void {
    if (sg_err == "" && !sg_quiet) {
        sg_err = msg;
        sg_eline = line;
        sg_ecol = col;
    };
};

def sg_in_body() -> bool {
    let hit = false;
    sg_bkind.foreach((k) => {
        if (k == 1 || k == 2) { hit = true };
    });
    hit
};

def mg_thread(w: str) -> bool {
    w in ["spawn", "fork", "join", "mutex", "lock", "try_lock", "sem", "post", "wait"]
};

// The names the pass injects into G. `y_`-prefixed, so a module imported into
// the generator namespaces its own names and cannot collide -- but the
// program's OWN top level is flat, so a def there is the collision.
// The three ycc_meta_* helpers are the pass's own plumbing: a block may not
// name them at all. The YCC names are different: a block CALLS them, so only
// defining one is the collision.
def mg_reserved(w: str) -> bool {
    w in ["ycc_meta_expr", "ycc_meta_stmt", "ycc_meta_emit",
        "YccBuild", "YCC", "ycc_define", "ycc_defined", "ycc_flag",
        "ycc_target_is", "ycc_hexd", "ycc_quote", "ycc_consts"]
};
def mg_reserved_call(w: str) -> bool {
    w in ["ycc_meta_expr", "ycc_meta_stmt", "ycc_meta_emit"]
};

def sg_next(i: long, n: long) -> long {
    let j = i;
    let found = false;
    while (j < n && !found) {
        let c = sg_src[j];
        // compares, not `[...].index(c)`: the literal was an array allocated
        // for every byte of every file with a '#' in it
        if (c == 35 || c == 34 || c == 39 || c == 47 || c == 123 || c == 125 || c == 59 || c == 10) {
            found = true;
        } else if (sg_depth > 0 && m_word(c)) {
            found = true;
        } else {
            j = j + 1;
        };
    };
    j
};

// At a statement boundary: the word there, if any. Handles `def`, `type`,
// `import` and the refused and reserved names; an ordinary name is nothing to
// do. Returns where to carry on from -- which is past the word, and past an
// `import` the caller must then not emit again.
def sg_word(i: long, n: long) -> long {
    let k = i;
    while (true && k < n && (sg_src[k] == 32 || sg_src[k] == 9 || sg_src[k] == 13)) {
        k = k + 1;
    };
    if (k < n && m_word(sg_src[k])) {
        let w = m_word_at(sg_src, k, n);
        let after = k + len(w);
        if (w == "import" && sg_depth > 0) {
            // hoisted to the top of G, so it is not part of G's block text:
            // the blanks before it are, or the block's own column drifts
            sg_put(sg_src[i:k]);
            sg_import(after, n)
        } else {
            sg_out(i, after);
            sg_word_go(w, after, n)
        }
    } else {
        i
    }
};

def sg_word_go(w: str, after: long, n: long) -> long {
    // the first word of the statement in progress is what the reduction reads
    if (mg_reduce && sg_depth == 0) { sg_region_word(w) };
    let j = after;
    while (true && j < n && (sg_src[j] == 32 || sg_src[j] == 9)) {
        j = j + 1;
    };
    let called = j < n && (sg_src[j] == 40 || sg_src[j] == 123);
    if (w == "def" || w == "type" || w == "ndef") {
        // the NAME it defines, not the keyword: a collision with an injected
        // helper is a duplicate top-level def, and it is silent in the
        // generator the same way it would be in the program
        if (j < n && m_word(sg_src[j])) {
            sg_check_def_name(m_word_at(sg_src, j, n));
        };
        sg_pending = true;
        sg_tkind = 0;
        if (w == "type") { sg_tkind = 2 };
        after
    } else {
        sg_check_name(w, called);
        after
    }
};

// A name the pass has an opinion about, in a block: one of the injected
// helpers, or a thread/process primitive being CALLED or DEFINED (a variable or
// a field of that name is fine, and so is the bare word).
def sg_check_name(w: str, called: bool) -> void {
    if (mg_reserved_call(w)) {
        sg_fail("'" + w + "' is reserved: the meta pass injects it into the generator", sg_line, sg_col);
    } else if (sg_depth > 0 && mg_thread(w) && called) {
        sg_fail("'" + w + "' cannot be used in a meta block: the generator runs in a forked child, and a thread or process primitive there is never what was meant", sg_line, sg_col);
    };
};

// The name a def, type or ndef introduces: defining an injected name is the
// collision, while calling ycc_define from a block is the point.
def sg_check_def_name(w: str) -> void {
    if (mg_reserved(w)) {
        sg_fail("'" + w + "' is reserved: the meta pass injects it into the generator", sg_line, sg_col);
    } else if (sg_depth > 0 && mg_thread(w)) {
        sg_fail("'" + w + "' cannot be used in a meta block: the generator runs in a forked child, and a thread or process primitive there is never what was meant", sg_line, sg_col);
    };
};

// An `import` inside a block, hoisted to the top of G so the existing splicer
// resolves it: its dedup, its namespacing, its cycle detection and its
// depth-32 diagnostic all come free. `after` is past the `import` keyword.
def sg_import(after: long, n: long) -> long {
    let top = false;
    let k = sg_depth - 1;
    if (sg_depth > 0 && sg_bclean[k] && len(sg_bkind) == sg_bbrace[k]) { top = true; };
    if (!top) {
        sg_fail("an import inside a meta block must come first in the block", sg_line, sg_col);
        after
    } else {
        let j = after;
        let go = true;
        let semi = 0;
        while (go && j < n) {
            let c = sg_src[j];
            if (c == 34 || c == 39) {
                j = lit_end(sg_src, j, [0]);
            } else if (c == 59) {
                semi = j + 1;
                go = false;
            } else {
                j = j + 1;
            };
        };
        if (semi == 0) {
            sg_fail("an import inside a meta block must end with ';'", sg_line, sg_col);
            after
        } else {
            mg_imp += mg_import_line(trim(sg_src[after:semi]), sg_dir);
            mg_iol += sg_line;
            sg_bound = true;
            sg_pending = false;
            semi
        }
    }
};

// `import <rest>` with a path normalized the way native.y's norm_path does:
// the splicer normalizes again on its own side, but this one decides WHICH file
// the path means, so it has to collapse the "/./" a nested base dir carries.
let mg_cwd = "";

def mg_import_line(rest: str, dir: str) -> str {
    // The scanner includes the required semicolon in rest.
    if (rest[len(rest) - 1:] == ";") { rest = trim(rest[:len(rest) - 1]); };
    let k = index_of(rest, " from ");
    if (k < 0) { return "import " + rest + ";"; };
    let name = rest[:k];
    let path = trim(rest[k + 6:]);
    if (len(path) >= 2 && path[:1] == "\"" && path[len(path) - 1:] == "\"") {
        let full = path[1:len(path) - 1];
        if (full[:1] != "/") { full = dir + "/" + full; };
        if (full[:1] != "/") {
            if (mg_cwd == "") {
                let buf: [byte; 4096] = [0; 4096];
                let n = syscall(hostos.nr(79), &buf[0], 4096);
                if (n < 1) { mg_report("cannot resolve the generator's import directory"); };
                mg_cwd = from_bytes(buf[0:n - 1]);
            };
            full = mg_cwd + "/" + full;
        };
        path = "\"" + mg_norm_path(full) + "\"";
    };
    "import " + name + " from " + path + ";"
};

// Whether a block has ever had a block open inside it. Structural, so the table
// is the same in every round and is never cleared; a slot nobody has reached yet
// reads false. sg_open needs it BEFORE it has scanned the block's own body, to
// know whether to hold that body.
def mg_bkids_had(slot: long) -> bool {
    while (len(mg_bkids) <= slot) { mg_bkids += false };
    mg_bkids[slot]
};

// Record the nesting shape: a block that opens inside another one.
def mg_kid_note(par: long) -> void {
    while (len(mg_bkids) <= par) { mg_bkids += false };
    mg_bkids[par] = true;
};

// ── the reduction ─────────────────────────────────────────────────────────
def sg_region_open() -> long {
    sg_rtext = sg_gbuf;
    sg_rgline = sg_gline;
    sg_rbrace = len(sg_bkind);
    sg_rfrom = len(sg_g);
    sg_rkeep = false;
    sg_rblk = false;
    sg_rpend = true;
    0
};

// The first word of the region in progress, if it has one yet: a declaration or
// a splicer directive is kept, anything else is the statement the reduction is
// about. A region whose first token is not a word (`#{`, a digit, `(`) leaves
// sg_rpend set, which costs nothing -- the region is over at the next `;`.
def sg_region_word(w: str) -> void {
    if (sg_rpend) {
        sg_rpend = false;
        if (mg_directive(w)) { sg_rkeep = true };
    };
};

// The words the reduction keeps: the four declarations, plus the splicer's own
// whole-line directives (`import`, `export`, `embed`), which are consumed by the
// resolve and never reach the lexer.
def mg_directive(w: str) -> bool {
    w in ["def", "type", "let", "const", "import", "export", "embed"]
};

def sg_region_close() -> void {
    if (!sg_rkeep && !sg_rblk) {
        sg_g = sg_g[0:sg_rfrom];
        sg_gf = sg_gf[0:sg_rfrom];
        sg_gol = sg_gol[0:sg_rfrom];
        sg_gbuf = sg_rtext;
        sg_gline = sg_rgline;
        sg_gat = 0;
    };
    sg_region_open()
};

def sg_open(i: long, n: long) -> long {
    let prev = 0;
    if (i > 0) { prev = sg_src[i - 1]; };
    let mid = sg_col > 1 && m_token_end(prev);
    if (sg_in_body()) {
        sg_fail("a meta block cannot be inside a def or type body: only the top level and other blocks", sg_line, sg_col);
        n
    } else if (sg_pending && !mid) {
        sg_fail("a meta block in a def or type header must be part of a name, with a character of the name beside it: a call cannot go in a header, and dropping the block's bytes would leave nothing behind", sg_line, sg_col);
        n
    } else if (sg_depth + 1 > MG_NEST) {
        // A COST bound, not the parser's: a level of nesting is a round, and a
        // round is a compile and a run of the generator (mg_pending). Naming the
        // cost here is the point -- the number is small because each step is a
        // whole program compiled again, not because the parser minds.
        sg_fail("meta blocks nest deeper than " + tostring(MG_NEST) + ": each level of nesting costs another compile and run of the meta generator, so this is a cost limit, not the parser's", sg_line, sg_col);
        n
    } else {
        let nested = sg_depth > 0;
        let slot = mg_next;
        mg_next = slot + 1;
        let pdead = false;
        if (nested) {
            mg_nest++;
            pdead = sg_bdead[sg_depth - 1];
            mg_kid_note(sg_bslot[sg_depth - 1])
        } else {
            // a block at the top level keeps the reduction's region: it has one
            sg_rblk = true;
        };
        let dead = pdead || (nested && sg_bsplice[sg_depth - 1]);
        let have = slot < len(mg_have) && mg_have[slot];
        // A nested block whose text is already in the table contributes that TEXT
        // to the source of the block around it -- that is the whole of nesting --
        // so it never runs and its own bytes are only scanned, for the slots of
        // the blocks inside it, and then dropped.
        let spliced = !dead && nested && have;
        mg_bfile += sg_fid;
        mg_bline += sg_line;
        mg_p_at = -1;
        if (!nested) { mg_p_at = len(sg_p); };
        mg_bslot += slot;
        mg_bp += mg_p_at;
        mg_bpo += len(sg_pbuf);
        mg_n++;
        mg_live += !dead && !spliced;
        // Does this block's text have to exist? A top-level block's does: it goes
        // into the program. A nested one's does only while the block around it is
        // being compiled -- inside spliced text it is already there.
        mg_need += nested ? !dead : true;
        mg_bok += false;
        sg_bmid += mid;
        // A statement-position block is one that held only blanks before it, and
        // a mid-token one is a statement by construction (it could not be an
        // expression there), so both want the `;` and the void helper.
        let stmt = mid || m_all_blank(sg_gbuf[sg_gat:]);
        sg_bstmt += stmt;
        sg_bclean += true;
        sg_bbrace += len(sg_bkind);
        sg_bslot += slot;
        // this block starts out able to produce its text; a child without its own
        // takes that away (there is exactly one child-fold per open block)
        sg_bok += true;
        if (nested && !dead && !have) { sg_bok[sg_depth - 1] = false };
        sg_bsplice += spliced;
        sg_bdead += dead;
        let hold = !mg_collect && !nested && !dead && mg_bkids_had(slot);
        sg_bhold += hold;
        sg_depth++;
        sg_bound = true;
        // the `#{` is a token like any other, so a block that starts a statement
        // starts it here: the anchor of a hoisted call is this position, and the
        // call lands immediately before the block's own
        if (!sg_tsp) {
            sg_tsline = sg_gline;
            sg_tsoff = len(sg_gbuf);
            sg_tsp = true;
        };
        if (dead) {
            // inside text that is not compiled: scan the bytes for the slots and
            // put them nowhere
            mg_live[slot] = false;
            mg_need[slot] = false;
            sg_hold()
        } else if (spliced) {
            // its text goes into the enclosing source where the block stood, and
            // its own bytes are held out of it
            sg_splice(slot, sg_line);
            sg_hold()
        } else if (mid || nested) {
            sg_m_open(slot)
        } else if (hold) {
            // the prefix waits for the `}#`: only then is it known whether this
            // round has the text of every block inside (sg_top_close)
            sg_hold()
        } else {
            sg_gadd((stmt ? "ycc_meta_stmt" : "ycc_meta_expr") + "(" + tostring(slot) + ", tostring({", sg_mmid);
            sg_col += 2;
        };
        let k = sg_word(i + 2, n);
        sg_col += (k - (i + 2));
        k
    }
};

def sg_m_open(slot: long) -> void {
    sg_hold();
    sg_mbuf += "ycc_meta_stmt(" + tostring(slot) + ", tostring({";
    sg_col += 2;
};

def sg_top_close(k: long) -> void {
    let slot = sg_bslot[k];
    let stmt = sg_bstmt[k];
    if (sg_bok[k]) {
        sg_restore((stmt ? "ycc_meta_stmt" : "ycc_meta_expr") + "(" + tostring(slot) + ", tostring({", (stmt ? "}));" : "}))"))
    } else {
        sg_drop();
        sg_gbuf += mg_stub(slot, stmt);
    }
};

// `}#` of a held block whose call is hoisted -- a mid-token one, or any nested
// one: close the call, record it with the statement to hoist it to, and give the
// enclosing block its buffer back. Recorded in CLOSE order, which is the order
// the calls have to run in.
def sg_m_close(k: long) -> void {
    if (sg_bok[k]) {
        sg_mbuf += "}));"
    } else {
        sg_mbuf = mg_stub(sg_bslot[k], true);
        sg_mol = [];
        sg_molast = false;
        sg_mline = sg_gline;
    };
    let lines = mg_lines(sg_mbuf);
    let ol: [long] = [];
    lines.foreach((_el, i) => {
        if (i < len(sg_mol)) { ol += sg_mol[i] }
        else if (sg_molast) { ol += sg_mline }
        else { ol += sg_gline };
    });
    let line = sg_tsline;
    let off = sg_tsoff;
    if (line < 1) { line = 1 };
    if (off < 0) { off = 0 };
    sg_mids += { line: line, off: off, text: lines, ol: ol };
    sg_m_pop()
};

// Which G buffer is live now that the block has closed and the per-block
// stacks have been popped: a held block's own if one is still open, and
// sg_mdepth says at what depth (0 = the file's own buffer).
def sg_m_live() -> void {
    sg_mmid = false;
    sg_mdepth = 0;
    let k = sg_depth - 1;
    while (k >= 0) {
        if (sg_bhold[k]) { sg_mmid = true; sg_mdepth = k + 1 };
        k = k - 1;
    };
};

def sg_mids_move() -> void {
    let n = len(sg_mids);
    let done: [bool] = [];
    for i in 0..n { done += false; };
    let left = n;
    while (left > 0) {
        let at = -1;
        for j in 0..n {
            if (!done[j]) {
                if (at < 0 || mg_after(j, at)) { at = j };
            };
        };
        if (at < 0) { left = 0 }
        else {
            sg_mids_one(at);
            done[at] = true;
            left = left - 1;
        };
    };
    sg_mids = [];
};

// Whether move `a` belongs to a LATER statement (or the same one, further along
// the list) than `b` -- so `a` is the next one out.
def mg_after(a: long, b: long) -> bool {
    let la = sg_mids[a].line;
    let lb = sg_mids[b].line;
    if (la != lb) { la > lb }
    else { sg_mids[a].off > sg_mids[b].off }
};

// One call, into sg_g at its statement: the statement's line is split at the
// anchor, the call's lines go between the halves, and its origins go with them.
def sg_mids_one(k: long) -> void {
    let m = sg_mids[k];
    let ln = m.line - 1;
    if (ln < 0) { ln = 0 };
    let cur = "";
    if (ln < len(sg_g)) { cur = sg_g[ln] };
    let off = m.off;
    if (off > len(cur)) { off = len(cur) };
    let head = cur[0:off];
    let tail = cur[off:];
    let rest = sg_g[0:ln];
    let restf = sg_gf[0:ln];
    let restl = sg_gol[0:ln];
    if (head != "") { rest += head; restf += sg_fid; restl += m.line };
    for i in 0..len(m.text) {
        rest += m.text[i];
        restf += sg_fid;
        let o = 0;
        if (i < len(m.ol)) { o = m.ol[i] };
        restl += o;
    };
    if (tail != "") { rest += tail; restf += sg_fid; restl += m.line };
    for t in ln + 1..len(sg_g) {
        rest += sg_g[t];
        restf += sg_gf[t];
        restl += sg_gol[t];
    };
    sg_g = rest;
    sg_gf = restf;
    sg_gol = restl;
};

// `}#` with sg_depth == 0: nothing opened it.
def sg_stray(i: long) -> void {
    sg_fail("'}#' in code position with no open meta block", sg_line, sg_col);
    i
};

// The scan. One pass over the file's bytes: P and G come out of it as (line,
// file, source line) triples, and the block table and hoisted imports go into
// the module-level lists.
def meta_scan(src: str, fid: long, dir: str) -> Scan {
    if (index_of(src, "#") < 0) {
        scan_none(src, fid)
    } else {
        sg_reset(src, fid, dir);
        mg_first = mg_next;
        let n = len(src);
        let i = 0;
        while (i < n && sg_err == "") {
            if (sg_state == 0) {
                i = sg_code(i, n);
            } else if (sg_state == 1) {
                i = sg_line_comment(i, n);
            } else if (sg_state == 2) {
                i = sg_block_comment(i, n);
            } else {
                i = sg_literal(i, n);
            };
        };
        meta_scan_end()
    }
};

def meta_scan_end() -> Scan {
    if (sg_err == "" && sg_depth > 0) {
        let ln = 1;
        if (mg_first < len(mg_bline)) { ln = mg_bline[mg_first]; };
        sg_fail("unterminated #{ block: no }# before the end of the file", ln, 1);
    };
    if (sg_err == "") {
        sg_p += sg_pbuf;
        sg_pf += sg_fid;
        sg_pol += sg_pline;
        if (sg_mmid) {
            // a file that ends inside a mid-token block: an error above (the
            // block never closed), so nothing reads these
            sg_mol += sg_gline;
            sg_mbuf += "\n";
        } else {
            sg_g += sg_gbuf;
            sg_gf += sg_fid;
            // the origin too, so sg_g and sg_gol stay the same length: the
            // hoisted calls below index both
            sg_gol += sg_gline;
        };
        sg_mids_move();
        sg_gbuf = "";
        sg_mdepth = 0;
        // this file's G lines go onto the whole program's G, then the scanner
        // starts the next file clean. The Scan still carries this file's own
        // lines: `mg_probe` reads the result, and a caller may too.
        let mine = sg_g;
        let minef = sg_gf;
        let mineol = sg_gol;
        // A hash in a comment or literal does not make this file a generator.
        if (mg_next > mg_first) {
            mg_g += sg_g;
            mg_gol += sg_gol;
        };
        mg_splice(mg_first, mg_next);
        sg_g = [];
        sg_gf = [];
        sg_gol = [];
        { ok: true, err: "", eline: 0, ecol: 0, p: sg_p, pf: sg_pf, pol: sg_pol,
            gen: sg_gen,
            g: mine, gf: minef, gol: mineol }
    } else {
        scan_bad(sg_err, sg_eline, sg_ecol)
    }
};

// Code position. `sg_bound` says a keyword may start at i.
def sg_code(i: long, n: long) -> long {
    if (sg_bound) {
        sg_bound = false;
        let k = sg_word(i, n);
        if (k > i) { return k };
    };
    let j = sg_next(i, n);
    sg_out(i, j);
    let c = 0;
    if (j < n) { c = sg_src[j] };
    if (sg_depth > 0 && m_word(c)) {
        // sg_next stops at a word start inside a block, so this is where a
        // name mid-expression gets read (sg_word emits the word as it goes)
        sg_word(j, n)
    } else if (c == 10) {
        sg_bound = true;
        sg_break();
        j + 1
    } else if (c == 34 || c == 39) {
        // a literal, taken whole: lit_end has the closing quote, so nothing
        // inside one is a block -- the f-string lowering's `#fmt` is inside a
        // literal in the source too
        sg_state = 3;
        j
    } else if (c == 47) {
        sg_slash(j, n)
    } else if (c == 123) {
        sg_open_brace(j, n)
    } else if (c == 125) {
        sg_close_brace(j, n)
    } else if (c == 35) {
        sg_hash(j, n)
    } else if (c == 59) {
        sg_pending = false;
        sg_bound = true;
        sg_put1(";");
        // a top-level `;` ends the statement in progress, so the next one starts
        // after it (see sg_ts_go) and the statement is over for the reduction
        if (sg_depth == 0 && sg_mdepth < 1) {
            sg_ts_end();
            if (mg_reduce && len(sg_bkind) == sg_rbrace) { sg_region_close() }
        };
        j + 1
    } else {
        j
    }
};

// A `/`: `//`, `/*`, or division.
def sg_slash(j: long, n: long) -> long {
    if (j + 1 < n && sg_src[j + 1] == 47) {
        sg_state = 1;
        sg_put1("/");
        sg_put1("/");
        j + 2
    } else if (j + 1 < n && sg_src[j + 1] == 42) {
        sg_state = 2;
        sg_put1("/");
        sg_put1("*");
        j + 2
    } else {
        sg_put1("/");
        j + 1
    }
};

// `{`: remember whether this is a `def` body, a `type` body, or neither.
// The two are told apart because only `def` marks its body with sg_pending: a
// `type` header has braces of its own, so sg_in_body has to find its body on
// the stack. `sg_tkind` is what is currently being declared.
def sg_open_brace(j: long, n: long) -> long {
    if (sg_pending) {
        if (sg_tkind == 2) { sg_bkind += 2 } else { sg_bkind += 1 };
        sg_pending = false;
    } else {
        sg_bkind += 0;
    };
    sg_bound = true;
    sg_put1("{");
    sg_word(j + 1, n)
};

// `}`: the block's own close when it is followed by `#`, else an ordinary
// brace. The block's `}` closes no Y brace -- its `{` was never pushed.
def sg_close_brace(j: long, n: long) -> long {
    if (j + 1 < n && sg_src[j + 1] == 35) {
        if (sg_depth == 0) {
            sg_stray(j);
            n
        } else {
            let k = sg_depth - 1;
            mg_bok[sg_bslot[k]] = sg_bok[k];
            let stmt = sg_bstmt[k];
            let mid = sg_bmid[k];
            if (sg_bdead[k]) {
                // inside text that is not compiled: nothing of this block's is in
                // G, not even a call
                sg_drop()
            } else if (sg_bsplice[k]) {
                // its text went into the enclosing source; its own bytes are
                // scanned (for the slots inside) and dropped
                sg_drop()
            } else if (mid || sg_depth > 1) {
                // mid-token, or nested: the call is not here, it is hoisted to the
                // statement that contains the block
                sg_m_close(k)
            } else if (sg_bhold[k]) {
                // a top-level block that may hold another block: the call goes
                // here, and whether the body it wraps is this block's own or a
                // stand-in is known only now
                sg_top_close(k)
            } else {
                // a statement-position call is a statement, and a statement
                // wants its ';'; in expression position the call is the
                // expression and a ';' there would be a syntax error
                sg_gadd("}))", sg_mmid);
                sg_col += 2;
                if (stmt) { sg_gadd(";", sg_mmid); sg_col++; };
            };
            // the per-block stacks are popped here, so `sg_depth - 1` is always
            // this block's entry and never one left over from a block that has
            // already closed
            sg_bstmt = sg_bstmt[0:len(sg_bstmt) - 1];
            sg_bmid = sg_bmid[0:len(sg_bmid) - 1];
            sg_bclean = sg_bclean[0:len(sg_bclean) - 1];
            sg_bbrace = sg_bbrace[0:len(sg_bbrace) - 1];
            sg_bslot = sg_bslot[0:len(sg_bslot) - 1];
            sg_bok = sg_bok[0:len(sg_bok) - 1];
            sg_bsplice = sg_bsplice[0:len(sg_bsplice) - 1];
            sg_bdead = sg_bdead[0:len(sg_bdead) - 1];
            sg_bhold = sg_bhold[0:len(sg_bhold) - 1];
            sg_depth--;
            sg_m_live();
            if (mg_reduce && sg_depth == 0 && stmt && !mid &&
                len(sg_bkind) == sg_rbrace) {
                sg_region_close()
            };
            j + 2
        }
    } else {
        if (len(sg_bkind) > 0) {
            sg_bkind = sg_bkind[0:len(sg_bkind) - 1];
        };
        sg_bound = true;
        sg_put1("}");
        // a top-level `}` closes whatever construct it was in, and the next
        // statement starts after it -- and the statement is over for the
        // reduction, since a top-level statement ends at a `;` or at the `}`
        // that closes it
        if (sg_depth == 0 && sg_mdepth < 1) {
            sg_ts_end();
            if (mg_reduce && len(sg_bkind) == sg_rbrace) { sg_region_close() }
        };
        j + 1
    }
};

// `#` in code position: `#{` opens a block, anything else is an error. A stray
// `#` already reaches the lexer as "expected an expression, got '#'"; this is
// the same refusal with a message that names the construct.
def sg_hash(j: long, n: long) -> long {
    if (j + 1 < n && sg_src[j + 1] == 123) {
        sg_open(j, n)
    } else {
        sg_fail("'#' in code position: a meta block is #{ … }#", sg_line, sg_col);
        n
    }
};

// A `//` comment: EVERYTHING to the newline is text, so the interesting bytes
// in it are not interesting.
def sg_line_comment(i: long, n: long) -> long {
    let j = i;
    let go = true;
    while (go && j < n) {
        if (sg_src[j] == 10) { go = false; } else { j = j + 1; };
    };
    sg_out(i, j);
    sg_state = 0;
    if (j < n) {
        sg_out(j, j + 1);
        sg_bound = true;
        j + 1
    } else {
        n
    }
};

// A `/* */` comment: verbatim, comments do not nest, and one that never closes
// is fatal (the lexer treats it the same way -- the rest of the file would
// silently disappear).
def sg_block_comment(i: long, n: long) -> long {
    let j = i;
    let go = true;
    let found = false;
    while (go && j + 1 < n) {
        if (sg_src[j] == 42 && sg_src[j + 1] == 47) {
            found = true;
            go = false;
        } else {
            j = j + 1;
        };
    };
    if (found) {
        sg_out(i, j);
        sg_put1("*");
        sg_put1("/");
        sg_state = 0;
        j + 2
    } else {
        sg_out(i, n);
        sg_fail("unterminated /* comment", sg_line, sg_col);
        n
    }
};

def sg_literal(i: long, n: long) -> long {
    if (sg_fstring(i)) {
        let w = fstr_walk(sg_src, i);
        sg_out(i, w.end);
        sg_state = 0;
        w.end
    } else {
        let cl: [long] = [0];
        let end = lit_end(sg_src, i, cl);
        if (cl[0] == 0) {
            sg_fail("unterminated string literal", sg_line, sg_col);
            n
        } else {
            sg_out(i, end);
            sg_state = 0;
            end
        }
    }
};

// Whether the quote at i opens an f-string: `f` before it, standing alone.
def sg_fstring(i: long) -> bool {
    sg_src[i] == 34 && i > 0 && sg_src[i - 1] == 102 &&
    (i == 1 || !m_word(sg_src[i - 2]))
};
// ── the driver ──────────────────────────────────────────────────────────

// The piece table (mg_piece, mg_have) is up with the scanner's state, which is
// where it is read. Whether the pieces are known: false while scanning to
// collect the blocks, true from the round after the generator's first run, when
// the scanner can splice.
let mg_ready = false;
// The program file's path and the origin map's file list, so a diagnostic can
// name the file and line a block came from. native.y fills these in after the
// recursion and before the generator runs.
let mg_root = "";
let mg_files: [str] = [];
// G's own resolution: its dir, whether exec() is allowed in it, and the
// package names and source roots the splicer should resolve G's bare imports
// against.
let mg_gbase = "";
let mg_gexec = true;
let mg_pkgs: [str] = [];
let mg_roots: [str] = [];

def meta_begin() -> void {
    mg_on = true;
    mg_ready = false;
    mg_root = "";
    mg_files = [];
    mg_piece = [];
    mg_have = [];
    mg_gbase = "";
    mg_gexec = true;
    mg_pkgs = [];
    mg_roots = [];
    // mg_bkids is NOT reset here: it is structural, so every pass learns the same
    // thing from it (sg_open) -- which is what makes it usable at the `#{`, before
    // the children have been seen. Only the FIRST pass is the collecting one, and
    // only meta_begin says so.
    mg_bkids = [];
    mg_reduce = false;
    mg_pass();
    mg_collect = true;
};

// The reduction, turned on once a pass has found nesting. The collecting pass
// never turns it on: it does not know yet, and a program with no nesting must
// compile to exactly what it always did.
def mg_reduce_on() -> void {
    mg_reduce = true;
};

def mg_pass() -> void {
    sg_quiet = false;
    mg_next = 0;
    mg_g = [];
    mg_gol = [];
    mg_bslot = [];
    mg_bfile = [];
    mg_bline = [];
    mg_bp = [];
    mg_bpo = [];
    mg_imp = [];
    mg_iol = [];
    mg_bok = [];
    mg_live = [];
    mg_need = [];
    mg_n = 0;
    mg_nest = 0;
    mg_collect = false;
};

def mg_pending() -> bool {
    let i = 0;
    let go = false;
    while (i < mg_next) {
        if (mg_need[i] && (i >= len(mg_have) || !mg_have[i])) { go = true };
        i++;
    };
    go
};

// native.y hands the generator its resolution over this, because
// `meta.<field> = v` is a namespaced field ASSIGNMENT and strip_ns rewrites
// only namespaced dot READS (it handles K.dot, not K.dotassign -- see
// strip_ns), so a module cannot set another module's global by name.
def mg_setup(root: str, files: [str], base: str, exec: bool, pkgs: [str], roots: [str]) -> void {
    mg_root = root;
    mg_files = files;
    mg_gbase = base;
    mg_gexec = exec;
    mg_pkgs = pkgs;
    mg_roots = roots;
};

// The pass is off for the generator's own compile: G is ordinary Y, and
// anything a generator emits is never re-scanned, so nothing in it can open a
// block. This is what makes "a block's output may not contain a block" true by
// construction rather than by checking.
def mg_set(on: bool) -> void {
    mg_on = on;
};

// A fatal pass-level diagnostic. Every leak path out of the pass is one of
// these, never a hand-off to the lexer (see the spec's invariant 1): whatever
// `#{` the scanner was meant to catch is caught here, with its line.
def mg_report(msg: str) -> void {
    puts("error: " + msg + "\n");
    exit(1);
};

// ── the build a generator sees (YCC) ────────────────────────────────────
// The driver builds this text from the command line, the target and the
// defines; it is injected into G, never into the program. A tool with no
// driver (the language server) gets the fallback below, so a meta program it
// analyses still knows YCC.
let mg_btext = "";

def mg_build(t: str) -> void {
    mg_btext = t;
};

def mg_hexd(n: long) -> long {
    if (n < 10) { 48 + n } else { 87 + n }
};

// s as a Y string literal: 9 and 10 get their short escapes, any other byte
// below 0x20 and 0x7f gets \xNN, and bytes >= 0x80 stay as they are (UTF-8).
def mg_quote(s: str) -> str {
    let out = chr(34);
    for i in 0..len(s) {
        let c = s[i];
        if (c == 92) { out += chr(92) + chr(92); }
        else if (c == 34) { out += chr(92) + chr(34); }
        else if (c == 10) { out += chr(92) + "n"; }
        else if (c == 9) { out += chr(92) + "t"; }
        else if (c < 32 || c == 127) {
            out += chr(92) + "x" + chr(mg_hexd(c >> 4)) + chr(mg_hexd(c & 15));
        } else { out += chr(c); };
    };
    out + chr(34)
};

def mg_str_array(xs: [str]) -> str {
    let out = "[";
    for i in 0..len(xs) {
        if (i > 0) { out += ", "; };
        out += mg_quote(xs[i]);
    };
    out + "]"
};

// YCC.os and YCC.arch from the target and arch names alone: meta.y must not
// import target.y (that pulls target_shapes' meta block into this module).
def mg_target_os(target: str) -> str {
    if (target == "kernel") { "none" }
    else if (target == "win") { "windows" }
    else if (target == "web") { "web" }
    else { "linux" }
};

def mg_target_arch(target: str, arch: str) -> str {
    if (arch == "aarch64") { "aarch64" }
    else if (target == "web") { "wasm32" }
    else { "x64" }
};

// type YccBuild and const YCC, exactly as S15 renders them. root and out are
// the command line's spellings, so the text is deterministic.
def mg_build_text(target: str, os: str, arch: str, format: str, host: str,
    debug: bool, gc: str, root: str, out: str,
    names: [str], values: [str], args: [str]) -> str {
    let t = "type YccBuild = { target: str, os: str, arch: str, format: str, host: str, debug: bool, gc: str, root: str, out: str, defines: [str], values: [str], args: [str] };";
    t += chr(10) + "const YCC: YccBuild = { target: " + mg_quote(target);
    t += ", os: " + mg_quote(os);
    t += ", arch: " + mg_quote(arch);
    t += ", format: " + mg_quote(format);
    t += ", host: " + mg_quote(host);
    t += ", debug: " + (if (debug) { "true" } else { "false" });
    t += ", gc: " + mg_quote(gc);
    t += ", root: " + mg_quote(root);
    t += ", out: " + mg_quote(out);
    t += ", defines: " + mg_str_array(names);
    t += ", values: " + mg_str_array(values);
    t += ", args: " + mg_str_array(args);
    t + " };"
};

def mg_build_unset() -> bool { mg_btext == "" };

// Last resort only: a tool that resolves a meta program without going through
// native.meta_compile_gen. The driver's text (ycc.y set_meta_build) is exact.
def mg_fallback_text() -> str {
    let t = hostos.name();
    let fmt = if (t == "win") { "pe" } else { "elf" };
    mg_build_text(t, mg_target_os(t), mg_target_arch(t, hostos.arch()), fmt, t,
        false, "never", "", "", [], [], [])
};

def mg_helpers() -> [str] {
    let out: [str] = [];
    let b = mg_btext;
    if (b == "") { b = mg_fallback_text(); };
    b.split("\n").foreach((e) => {
        out += e;
    });
    out += "def ycc_define(name: str) -> str? {";
    out += "    let i = 0;";
    out += "    while (i < len(YCC.defines)) {";
    out += "        if (YCC.defines[i] == name) { return some(YCC.values[i]); };";
    out += "        i++;";
    out += "    };";
    out += "    none";
    out += "};";
    out += "def ycc_defined(name: str) -> bool { ycc_define(name) != none };";
    out += "def ycc_flag(name: str) -> bool {";
    out += "    let v = ycc_define(name);";
    out += "    if (v == none) { return false; };";
    out += "    let s = v!;";
    out += "    s != \"\" && s != \"0\" && s != \"false\" && s != \"no\" && s != \"off\"";
    out += "};";
    out += "def ycc_target_is(names: str) -> bool {";
    out += "    let hit = false;";
    out += "    split(names, \",\").foreach((n) => {";
    out += "        if (n == YCC.target || n == YCC.os || n == YCC.arch) { hit = true; };";
    out += "    });";
    out += "    hit";
    out += "};";
    out += "def ycc_hexd(n: long) -> long {";
    out += "    if (n < 10) { 48 + n } else { 87 + n }";
    out += "};";
    out += "def ycc_quote(s: str) -> str {";
    out += "    let out = chr(34);";
    out += "    for i in 0..len(s) {";
    out += "        let c = s[i];";
    out += "        if (c == 92) { out += chr(92) + chr(92); }";
    out += "        else if (c == 34) { out += chr(92) + chr(34); }";
    out += "        else if (c == 10) { out += chr(92) + \"n\"; }";
    out += "        else if (c == 9) { out += chr(92) + \"t\"; }";
    out += "        else if (c < 32 || c == 127) {";
    out += "            out += chr(92) + \"x\" + chr(ycc_hexd(c >> 4)) + chr(ycc_hexd(c & 15));";
    out += "        } else { out += chr(c); };";
    out += "    };";
    out += "    out + chr(34)";
    out += "};";
    out += "def ycc_consts() -> str {";
    out += "    \"const YCC_TARGET = \" + ycc_quote(YCC.target) + \";\" + chr(10) +";
    out += "    \"const YCC_OS = \" + ycc_quote(YCC.os) + \";\" + chr(10) +";
    out += "    \"const YCC_ARCH = \" + ycc_quote(YCC.arch) + \";\" + chr(10)";
    out += "};";
    out += "def ycc_meta_emit(slot: long, body: str) -> void {";
    out += "    let h = tostring(slot) + \" \" + tostring(len(body)) + \"\\n\";";
    out += "    let hb = bytes(h);";
    out += "    os_call(\"y_os_write\", 3, &hb[0], len(hb));";
    out += "    let b = bytes(body);";
    out += "    if (len(b) > 0) { os_call(\"y_os_write\", 3, &b[0], len(b)); 0; };";
    out += "    0";
    out += "};";
    out += "def ycc_meta_expr(slot: long, body: str) -> str {";
    out += "    ycc_meta_emit(slot, body);";
    out += "    body";
    out += "};";
    out += "def ycc_meta_stmt(slot: long, body: str) -> void {";
    out += "    ycc_meta_emit(slot, body);";
    out += "    0";
    out += "};";
    out
};

// G's text: the helpers, then the hoisted imports, then the files' own lines
// with each block as a call. The imports go after the helpers and before the
// body, so a hoisted module's own statements see the helpers.
// File ids whose source top level participates in the generator.
def mg_generator_files() -> [long] {
    let files: [long] = [];
    foreach (fid in mg_bfile) {
        if (!(fid in files)) { files += fid; };
    };
    files
};

def meta_gtext() -> str {
    let out: [str] = [];
    mg_helpers().foreach((e) => {
        out += e;
    });
    mg_imp.foreach((e) => {
        out += e;
    });
    join(out + mg_g, "\n") + "\n"
};

// How many lines of G's origin map are the helpers and the hoisted imports:
// the generator's body starts here, so a line index has to know.
def mg_ghead() -> long {
    len(mg_helpers()) + len(mg_imp)
};

// How many lines the generator's body is: the files' own lines, one for one.
def mg_glines() -> long {
    len(mg_g)
};

// Where the block that holds slot `s` stands, as `file:line`.
def mg_where(s: long) -> str {
    let k = 0;
    let ln = 0;
    let f = 0;
    while (k < len(mg_bslot)) {
        if (mg_bslot[k] == s) { ln = mg_bline[k]; f = mg_bfile[k]; };
        k++;
    };
    let path = mg_root;
    if (f < len(mg_files)) { path = mg_files[f] };
    path + ":" + tostring(ln)
};

// ── the piece table ─────────────────────────────────────────────────────

// Split the pipe's bytes into pieces. A framing error means the generator did
// not run our helpers, which cannot happen unless the pass is broken.

def mg_unframe(data: str) -> void {
    let n = len(data);
    let i = 0;
    let bad = false;
    while (i < n && !bad) {
        let j = i;
        while (true && j < n && data[j] != 10) { j = j + 1; };
        if (j >= n) {
            bad = true;
        } else {
            let head = data[i:j];
            let sp = index_of(head, " ");
            if (sp < 0) {
                bad = true;
            } else {
                let slot = leading_long(head[:sp]);
                let take = leading_long(head[sp + 1:]);
                let body = data[j + 1:j + 1 + take];
                if (take < 0 || len(body) != take || slot < 0 || slot >= mg_next) {
                    bad = true;
                } else {
                    // the tables start empty and a piece may arrive in any
                    // order, so they grow to the slot it names
                    while (len(mg_piece) <= slot) { mg_piece += ""; mg_have += false; };
                    mg_piece[slot] = body;
                    mg_have[slot] = true;
                    i = j + 1 + take;
                };
            };
        };
    };
    if (bad) {
        mg_report("the meta generator wrote a malformed piece to fd 3 (this is the pass's own framing, so it is a bug)");
    } else {
        0
    }
};

// The first slot with no piece, or -1. A block at the top level always runs
// (the top level IS the generator's program), so a gap means the generator
// did not reach it -- and the message can name it.
def mg_first_missing() -> long {
    let at = -1;
    for i in 0..mg_next {
        if (!mg_have[i]) { at = i; };
    };
    at
};

// Read back what a run produced: check the child's fate, unframe, check every
// piece, and report the first thing that is wrong. Returns false if the
// generator died, having said as much as can be said.
def mg_take_pieces(status: long, sig: long, out: [byte]) -> void {
    let r = true;
    // sized FIRST: mg_blame asks which slots have no piece, so a generator
    // that died before writing anything must still leave the tables the right
    // length (mg_unframe only grows them for the slots a piece names)
    while (len(mg_piece) < mg_next) { mg_piece += ""; mg_have += false; };
    if (sig > 0) {
        mg_report("the meta generator died on signal " + tostring(sig) + mg_blame());
    };
    if (status != 0) {
        mg_report("the meta generator exited " + tostring(status) + mg_blame());
    };
    if (len(out) > MG_MAX) {
        mg_report("the meta generator emitted more than " + tostring(MG_MAX) + " bytes");
    };
    mg_unframe(from_bytes(out));
    mg_commit();
    for i in 0..mg_next {
        // A block that ran for real owes the table a piece, and one that did not
        // run does not: a nested block whose text was spliced into the block
        // around it already has its piece from the round that produced it.
        if (mg_live[i] && mg_bok[i] && !mg_have[i]) {
            mg_report("the block at " + mg_where(i) + " produced no output: every meta block runs once, in the generator's top level, so reaching it is not optional");
        };
        mg_check(i);
    };
    mg_ready = true;
    r
};

def mg_commit() -> void {
    for i in 0..mg_next {
        if (i < len(mg_have) && mg_have[i] && !mg_bok[i]) {
            mg_have[i] = false;
            mg_piece[i] = "";
        };
    };
};

// The stand-in a block runs when it cannot produce its text this round. Same
// helper and same position as the real call, with the body `0`: the statement
// around it still compiles and still type-checks exactly as it did. Its piece is
// "0", and mg_commit throws that away with everything else.
def mg_stub(slot: long, stmt: bool) -> str {
    let s = (stmt ? "ycc_meta_stmt" : "ycc_meta_expr") + "(" + tostring(slot) + ", tostring({ 0 }))";
    if (stmt) { s += ";" };
    s
};

// ", and the first block that produced nothing was at ..." when there is one.
def mg_blame() -> str {
    let m = mg_first_missing();
    if (m < 0) { "" } else { ", and the first block that produced nothing was at " + mg_where(m) }
};

// The checks a piece must pass before it is spliced into the program's
// source. Each names the block, because "the generator emitted something bad"
// is not a message a reader can act on.
def mg_check(s: long) -> void {
    let p = "";
    if (s < len(mg_piece)) { p = mg_piece[s] };
    if (index_of(p, "#{") >= 0) {
        mg_report("the block at " + mg_where(s) + " emitted a #{ … }# block: generated text is never re-scanned, so a block cannot emit one");
    };
    if (index_of(p, "\x00") >= 0) {
        mg_report("the block at " + mg_where(s) + " emitted a NUL byte, which cannot be in a source file");
    };
};

def mg_probe(src: str, dir: str) -> bool {
    let n = mg_next;
    let bs = mg_bslot;
    let bf = mg_bfile;
    let bl = mg_bline;
    let bp = mg_bp;
    let bo = mg_bpo;
    let bn = mg_nest;
    let bok = mg_bok;
    let bli = mg_live;
    let gn = mg_n;
    let gi = len(mg_imp);
    let gl = len(mg_g);
    let was_quiet = sg_quiet;
    sg_quiet = true;
    meta_scan(src, 0, dir);
    sg_quiet = was_quiet;
    let hit = mg_n > gn;
    mg_next = n;
    mg_bslot = bs;
    mg_bfile = bf;
    mg_bline = bl;
    mg_bp = bp;
    mg_bpo = bo;
    mg_nest = bn;
    mg_bok = bok;
    mg_live = bli;
    mg_n = gn;
    mg_imp = mg_imp[0:gi];
    mg_iol = mg_iol[0:gi];
    mg_g = mg_g[0:gl];
    mg_gol = mg_gol[0:gl];
    hit
};

// `import a from "./b.y"` normalized the way native.y's norm_path does: the
// splicer will normalize again on its own side, but this one decides WHICH file
// the path means, so it has to collapse the "/./" a nested base dir carries.
def mg_norm_path(p: str) -> str {
    let parts = split(p, "/");
    let out: [str] = [];
    parts.foreach((seg) => {
        if (seg != ".") { out += seg; };
    });
    join(out, "/")
};
// ── the splice ──────────────────────────────────────────────────────────

// text's physical lines, and NOT split(): split drops ONE trailing empty
// element, so split("a\n", "\n") is ["a"] and the line break a piece ends on
// would be swallowed. A piece is generated text, and every byte of it counts.
def mg_lines(text: str) -> [str] {
    let out: [str] = [];
    let n = len(text);
    let start = 0;
    for i in 0..n {
        if (text[i] == 10) {
            out += text[start:i];
            start = i + 1;
        };
    };
    out += text[start:];
    out
};

def mg_emit(segs: [str], sego: [long], segp: [bool], fid: long, nl: [str],
    nf: [long], nll: [long], ngen: [bool]) -> long {
    let cur = "";
    let curo = 0;
    let cgen = true;
    segs.foreach((text, s) => {
        let o = sego[s];
        let p = false;
        if (s < len(segp)) { p = segp[s] };
        mg_lines(text).foreach((e, k) => {
            if (k == 0) {
                // Empty splice boundaries contribute no bytes or provenance.
                // A real fragment starts the line or joins its existing text.
                if (e != "") {
                    if (cur == "") { curo = o; cgen = p; } else { cgen = cgen && p; };
                };
            } else {
                nl += cur;
                nf += fid;
                nll += curo;
                ngen += cgen;
                cur = "";
                curo = o;
                cgen = p;
            };
            cur += e;
        });
    });
    nl += cur;
    nf += fid;
    nll += curo;
    ngen += cgen;
    0
};

// Splice blocks [lo, hi) -- this file's -- into the scanned P. A no-op when the
// pieces are not known yet (the collecting pass).
def mg_splice(lo: long, hi: long) -> void {
    if (!mg_ready) { 0 }
    else {
        let lines = sg_p;
        let ols = sg_pol;
        let nl: [str] = [];
        let nf: [long] = [];
        let nll: [long] = [];
        let ngen: [bool] = [];
        lines.foreach((e, i) => {
            mg_splice_line(e, ols[i], i, lo, hi, nl, nf, nll, ngen);
        });
        sg_p = nl;
        sg_pf = nf;
        sg_pol = nll;
        sg_gen = ngen;
    }
};

// One line of P, with the pieces of the blocks that stand on it. `at` is the
// line's index in sg_p and the block table is in the order the scanner found
// the blocks, so the blocks for this line are the run that starts at the first
// entry at or after `at` -- the run is skipped to, not merely tested for.
def mg_splice_line(line: str, ol: long, at: long, lo: long, hi: long,
    nl: [str], nf: [long], nll: [long], ngen: [bool]) -> long {
    let segs: [str] = [];
    let sego: [long] = [];
    let segp: [bool] = [];
    let prev = 0;
    let k = lo;
    while (k < hi && mg_bp[k] < at) { k = k + 1; };
    let any = false;
    while (k < hi && mg_bp[k] == at) {
        any = true;
        let o = mg_bpo[k];
        if (o >= prev && o <= len(line)) {
            segs += line[prev:o];
            sego += ol;
            segp += false;
            segs += mg_piece[mg_bslot[k]];
            sego += mg_bline[k];
            segp += true;
            prev = o;
        };
        k = k + 1;
    };
    if (!any) {
        segs += line;
        sego += ol;
        segp += false;
    } else {
        segs += line[prev:];
        sego += ol;
        segp += false;
    };
    mg_emit(segs, sego, segp, sg_fid, nl, nf, nll, ngen)
};
export { run_image, pipe_fds, RunRes, Img, elf_img,
    meta_begin, mg_pass, mg_pending, mg_reduce_on, mg_nest,
    mg_set, mg_setup, mg_on, mg_check, mg_report,
    mg_probe, mg_take_pieces, meta_scan, Scan, scan_none,
    meta_gtext, mg_generator_files, mg_ghead, mg_glines, mg_gol, mg_gbase, mg_gexec, mg_pkgs, mg_roots,
    mg_build, mg_build_unset, mg_build_text, mg_quote, mg_target_os, mg_target_arch,
    mg_root, MG_NEST, MG_ROUND };
