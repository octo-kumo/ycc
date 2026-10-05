// meta.y — compile-time code generation: the `#{ … }#` block, and the
// image runner it needs.
//
// Two things live here, in this order because the second sits on the first:
//   1. `run_image` — run a compiled image in a FORKED child, at a scratch
//      address, with its own fabricated stack. See "M1" below.
//   2. the pass — scan a file for blocks, build the generator program G and
//      the program P, run G, splice the pieces into P. See "M2" below.
//
// ── M1: why a child, and how ────────────────────────────────────────────
// The generator (G) is an ordinary Y program, compiled for the host and run.
// It must NOT run in ycc's own address space: `src/y/arch/prelude.s` has five
// `exit_group` trap stubs, so a generator that divides by zero would write to
// *ycc's* stdout and take ycc's exit status with it; `exit(0)` would make ycc
// exit 0 having emitted nothing; and a guest `spawn` would repoint the
// compiler's own `%fs:24`. A child dissolves all three: its memory is
// copy-on-write, so a trap, an `exit`, an `exec` or a `spawn` there dies with
// it, and `waitpid` turns its death into a diagnostic naming the block.
//
// The transfer into the child is a raw `clone` syscall (Linux x86-64, syscall
// 56) with the new stack pointer as its second argument and SIGCHLD as the
// exit signal — that is, fork with a chosen stack:
//
//     syscall(56, SIGCHLD, stack_top, 0, 0, 0)
//
// Without CLONE_VM the child gets a copy-on-write copy of the whole address
// space (so it is a fork), and its `%rsp` becomes `stack_top`. MEASURED, and
// the measurement matters: the kernel does NOT read an entry point out of
// that stack. The child comes back from the syscall with `%rax = 0`, `%rsp =
// stack_top`, and RIP at the instruction after the syscall — still running
// THIS code, on the new stack. So the transfer is one `jmp_at` later, and
// because `jmp_at` is `jmp *%rax` (ir.y F_JMP_IND) rather than `call`, %rsp is
// still `stack_top`, which is where the fabricated
//
//     [stack_top]      = argc
//     [stack_top + 8]  = argv[0] ... argv[argc-1], then NULL
//
// sits — exactly the `[argc][argv…][NULL]` a process entry point expects, and
// nothing has to push a return address over the argc.
//
// The image is relocatable because `label_addr` (asm.y) returns segment
// OFFSETS and every fixup is a difference of offsets, so no code byte holds an
// absolute address: mapping it anywhere keeps every rip-relative reference
// correct, as long as the layout *relative* to the mapping base is preserved.
// So the .bss — which the code reaches by `lea y_heap(%rip)` and
// `mov yg_0_x$2(%rip)` — goes at exactly its own offset past the code+rodata
// mapping, and the page the R+E segment leaves before it stays unmapped
// (elf_bss_from_ro puts the .bss a page past the image's last page).
//
// The image bytes cannot be copied in by ycc: Y has no pointer arithmetic that
// turns a `long` into a writable `*T` (a `*T` only ever comes from `&x`, and
// `*T` cannot be indexed — types.y). So they go through a memfd: `write` from
// the compiler's own byte array, `ftruncate` to the whole span, then one
// `mmap` of that file covering code+rodata AND .bss, `mprotect`ed R|X over
// the code alone. One extra copy through the page cache, no temp file, no
// kernel exec -- and, unlike two separate mappings, no MAP_FIXED, which this
// kernel refuses (EINVAL) at a fresh address immediately above an existing
// mapping, which is exactly where the .bss wants to be (MEASURED: `mmap` at
// mmap()+0x1000 fails EINVAL; at a constant unused address, and over an
// already-mapped page, it succeeds).
//
// The guest writes each piece to fd 3 as it produces it (the parent dup2s the
// pipe's write end there for the duration of the run), so there is no .bss
// accumulator, no slot array in the image and no return value to read: the
// pipe, the child's exit status and its byte count are the whole protocol.

// Only the lexer: lit_end is the literal scanner, and the pass must not
// import native.y (native.y imports this file -- see the driver note).
import lexer from "./lexer.y";

// ── little-endian reads and writes ──────────────────────────────────────

// ── M2: the pass ────────────────────────────────────────────────────────
// Read `ideas/meta.md`. This is the second half of it, and the shape is:
//
//     G = T with every block replaced by a call
//     P = T with every block replaced by that call's text
//
// G is compiled for the host with THE PASS OFF and run in a forked child
// (run_image, above); its output is the piece table; the pass splices the
// pieces into P; P is handed to the existing lexer unchanged. There is exactly
// one layer, so `#{ … }#` is the whole surface: no `#if`, no `#meta`, no
// escaping (only CODE position is scanned, and there is no valid Y text with a
// `#` in code position -- the corpus has none), and no re-scan, so a
// generator may emit a string literal holding `#{` freely.
//
// A few facts about Y that the whole design rests on, all measured:
//
//   - a block's value is its last statement WITHOUT a trailing `;`, and void
//     does not coerce, so a void block is an existing type error rather than a
//     new diagnostic;
//   - `import` never reaches the lexer or the parser -- the splicer consumes
//     whole lines at file scope -- so an import inside a block is hoisted into
//     text the splicer already understands, and cycle detection, dedup,
//     namespacing and the depth-32 diagnostic all come free;
//   - the scanner needs a literal scanner, and lexer.y's lit_end is now
//     exported with an out-param that says whether the literal closed.
//
// Why the scan is per file, at the top of native_resolve_seen and before its
// line loop: `embed` is expanded INSIDE that loop, so scanning first leaves an
// embedded file's bytes inert; each file's own base_dir is in scope, so a
// hoisted import path normalizes against the file the block came from; and the
// scan runs before words_seen, so std-unit selection sees the GENERATED text.

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
// How many blocks the whole resolve found, and whether any.
let mg_n = 0;
// The emitted-text size cap (R8 is not negotiable). The piece table is read
// into memory, so this is what bounds it.
const MG_MAX = 33554432;
// The pass's own nesting cap, well below the parser's ~333 effective limit
// (tags.y MAX_NEST is 1000 and each nested block costs ~3 nest units), so a
// runaway nest is a diagnostic naming the block rather than `too_deep` firing
// inside a file that does not exist.
const MG_NEST = 100;

// One file's scan: P's lines with their origins, G's lines for this file, and
// the imports hoisted out of its blocks.
// gen[i] says line i of p is wholly GENERATED (a block's piece), not the
// user's own text. It is what tells lint which top-level statements the pass
// put there, so "a top-level statement runs twice" does not fire on them.
type Scan = { ok: bool, err: str, eline: long, ecol: long,
              p: [str], pf: [long], pol: [long], gen: [bool],
              g: [str], gf: [long], gol: [long] };

def scan_bad(err: str, line: long, col: long) -> Scan {
    { ok: false, err: err, eline: line, ecol: col, p: [], pf: [], pol: [],
      gen: [], g: [], gf: [], gol: [] }
};

// A file with no blocks: P is the file's own lines, G the same, and nothing
// else changes. The common case costs one index_of per line.
//
// split() drops ONE trailing empty element, so a source ending in "\n" loses
// that newline on the way back out -- which is what the splicer has always
// done with a file's lines, and what its origins are sized for. The scanner
// below breaks on every newline INCLUDING the last, so its line count is one
// more and its output rejoins to the source; scan_none does not, and must not,
// or the two paths would disagree on a file with no blocks in it.
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
        i = i + 1;
    };
    { ok: true, err: "", eline: 0, ecol: 0, p: lines, pf: f, pol: l, gen: gn,
      g: lines, gf: f, gol: l }
};

// ── byte classes (the lexer's own predicates, spelled here because they are
// not exported, and they must agree with lexer.y's wordbyte/isspace) ──────

def m_word(c: long) -> bool {
    c == c'_' || (c >= c'a' && c <= c'z') || (c >= c'A' && c <= c'Z') ||
    (c >= c'0' && c <= c'9')
};

def m_blank(c: long) -> bool {
    c == c' ' || c == c'\t' || c == c'\n' || c == c'\r'
};

// The word at src[i], i known to be a word byte.
def m_word_at(src: str, i: long, n: long) -> str {
    let j = i + 1;
    while (j < n && m_word(byte_at(src, j))) { j = j + 1; };
    src[i:j]
};

// Whether every byte of s is a blank.
def m_all_blank(s: str) -> bool {
    let ok = true;
    let i = 0;
    while (ok && i < len(s)) {
        if (!m_blank(byte_at(s, i))) { ok = false; };
        i = i + 1;
    };
    ok
};

// The byte before src[i] (i > 0), or 0.
def m_prev(src: str, i: long) -> long {
    if (i <= 0) { 0 } else { byte_at(src, i - 1) }
};

// Whether the byte before a `#{` ends a token -- a name, a number, a literal
// or a closing bracket. Then the block sits between two tokens of one
// expression, where a call cannot go (`def helper#{x++}#()`), and it is an
// error rather than a feature: generating a NAME has no expression position
// for the call to occupy.
def m_token_end(c: long) -> bool {
    if (c == 0) { false }
    else if (c == c')' || c == c']' || c == c'}' || c == c'.' || c == c'\'' || c == c'\"') { true }
    else { m_word(c) }
};

def rd16(b: [byte], at: long) -> long {
    b[at] + b[at + 1] * 256
};

def rd32(b: [byte], at: long) -> long {
    b[at] + b[at + 1] * 256 + b[at + 2] * 65536 + b[at + 3] * 16777216
};

def rd64(b: [byte], at: long) -> long {
    let lo = rd32(b, at);
    let hi = rd32(b, at + 4);
    lo + hi * 4294967296
};

// One byte written into a byte array.
def putb(buf: [byte], at: long, v: long) -> long {
    buf[at] = v;
    0
};

// One 64-bit word, little endian, into a byte array.
def put64(buf: [byte], at: long, v: long) -> long {
    let i = 0;
    let x = v;
    while (i < 8) {
        buf[at + i] = x % 256;
        x = x / 256;
        i = i + 1;
    };
    0
};

// ── the image's own header, read back ───────────────────────────────────
// A compiled image is one flat ELF64 file (elf.y): [EHDR 64][PHDR 56 or 112]
// [code][rodata][8 zeros], base vaddr 0x400000, and with a .bss a second
// PT_LOAD (read+write, nothing from the file) on the page after the image's
// last page. Everything the runner needs is in those two PHDRs, so the
// segments are read back out of the bytes elf_build just wrote rather than
// threading a new signature through asm.y.
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
        k = k + 1;
    };
    if (!found) {
        img_ok(0, 0, eoff, filesz, memsz)
    } else if (msize > 0 && vaddr >= base) {
        img_ok(vaddr - base, msize, eoff, filesz, memsz)
    } else {
        img_bad("the image's .bss segment is out of range")
    }
};

// ── the child's stack ───────────────────────────────────────────────────
// The child's stack: [argc][argv...][NULL] from the top down, and the word
// below them is left alone — the kernel does not read it, `jmp_at` does not
// touch %rsp, and the child never returns to the code that laid it out.
// Returns the address to hand clone as its stack: the child starts with
// %rsp = S, so it reads argc at [S] and argv[0] at [S+8].
def fab_stack(stk: [byte], av: [str]) -> long {
    let base = ptr_addr(&stk[0]);
    let p = base + len(stk);
    let m = len(av);
    let ptrs: [long] = [];
    let k = 0;
    while (k < m) {
        let s = av[k];
        let n = len(s);
        p = p - n - 1;
        let at = p - base;
        let j = 0;
        while (j < n) { stk[at + j] = byte_at(s, j); j = j + 1; };
        stk[at + n] = 0;
        ptrs += p;
        k = k + 1;
    };
    p = p - 8 * (m + 1);
    p = p - p % 8;
    k = 0;
    while (k < m) {
        put64(stk, p - base + 8 * k, ptrs[k]);
        k = k + 1;
    };
    put64(stk, p - base + 8 * m, 0);
    p = p - 8;
    put64(stk, p - base, m);
    p
};

// ── run_image ───────────────────────────────────────────────────────────
// What run_image reports: `ok` false means ycc could not even start the child
// (`err` says why); `ok` true means the child ran, and `status`/`sig` are its
// fate -- status 0 with sig 0 is a clean exit, a non-zero `sig` a death by
// signal. `out` is what the child wrote to fd 3, and is empty unless
// `want_out`.
type RunRes = { ok: bool, status: long, sig: long, out: [byte], err: str };

// Everything the child needs mapped, so it can be undone in one place.
type Mapd = { img: long, memsz: long, entry: long, span: long,
              rfd: long, keep: long };

// The page sizes and syscall numbers the runner needs. arch_x64's arch_sysno
// table has only the handful generated code uses, so the rest are spelled out
// here, next to their one use.
const PROT_RX = 5;      // PROT_READ|PROT_EXEC
const PROT_RW = 3;      // PROT_READ|PROT_WRITE
const MAP_PRIVATE = 2;
const SYS_READ = 0;
const SYS_WRITE = 1;
const SYS_CLOSE = 3;
const SYS_MMAP = 9;
const SYS_MPROTECT = 10;
const SYS_MUNMAP = 11;
const SYS_PIPE = 22;
const SYS_DUP = 32;
const SYS_DUP2 = 33;
const SYS_FCNTL = 72;
const F_DUPFD = 0;
const SYS_MEMFD = 319;
const SYS_FTRUNCATE = 77;
const SYS_CLONE = 56;
const SYS_WAIT4 = 61;
const SIGCHLD = 17;
const GUEST_FD = 3;     // where a generator's pieces are written

def page_up(n: long) -> long {
    (n + 4095) / 4096 * 4096
};

def run_fail(e: str) -> RunRes {
    { ok: false, status: 0 - 1, sig: 0, out: [], err: e }
};

def run_image(b: [byte], av: [str], want_out: bool) -> RunRes {
    let im = elf_img(b);
    if (!im.ok) {
        run_fail(im.err)
    } else {
        run_image_go(b, av, want_out, im)
    }
};

// pipe(): the two fds land as two 32-bit ints, so the buffer is 8 bytes of
// `[byte]` and not a `[long; 2]` -- a long would read the pair as one word.
//
// BOTH ends are moved above GUEST_FD first. A pipe lands on the lowest free fd,
// and with nothing open that is 3 -- the fd the generator writes its pieces
// to -- so the child's dup2 would land the write end on the read end and the
// parent would read from a write-only fd (EBADF, measured). F_DUPFD with a
// minimum of 4 does it without closing 3 first, which dup(2) could not: it
// hands out the lowest free number again.
def pipe_fds() -> { ok: bool, rfd: long, wfd: long } {
    let pf: [byte; 8] = [0; 8];
    if (syscall(SYS_PIPE, &pf[0], ptr_addr(&pf[0]) + 4, 0, 0, 0) != 0) {
        { ok: false, rfd: 0 - 1, wfd: 0 - 1 }
    } else {
        let r = rd32(pf[0:8], 0);
        let w = rd32(pf[0:8], 4);
        let r2 = syscall(SYS_FCNTL, r, F_DUPFD, GUEST_FD + 1, 0, 0);
        let w2 = syscall(SYS_FCNTL, w, F_DUPFD, GUEST_FD + 1, 0, 0);
        syscall(SYS_CLOSE, r, 0, 0, 0, 0);
        syscall(SYS_CLOSE, w, 0, 0, 0, 0);
        if (r2 < 0 || w2 < 0) {
            if (r2 >= 0) { syscall(SYS_CLOSE, r2, 0, 0, 0, 0); };
            if (w2 >= 0) { syscall(SYS_CLOSE, w2, 0, 0, 0, 0); };
            { ok: false, rfd: 0 - 1, wfd: 0 - 1 }
        } else {
            { ok: true, rfd: r2, wfd: w2 }
        }
    }
};

// The image into a fresh memfd, sized to the whole span the child will need:
// the ELF's own bytes, then the .bss at its own offset (elf_bss_from_ro puts
// it a page past the image's last page, and that gap page is simply part of
// the file's zeros). `b` is the compiler's own byte array, so no pointer
// arithmetic is needed: ptr_addr gives the address and the kernel does the
// copy.
def image_fd(b: [byte], span: long) -> long {
    let fd = syscall(SYS_MEMFD, "ycc-image", 0);
    if (fd < 3) {
        0 - 1
    } else {
        image_fd_write(b, fd, span)
    }
};

def image_fd_write(b: [byte], fd: long, span: long) -> long {
    let n = len(b);
    let at = ptr_addr(&b[0]);
    let off = 0;
    while (off < n) {
        let k = syscall(SYS_WRITE, fd, at + off, n - off);
        if (k <= 0) {
            syscall(SYS_CLOSE, fd, 0, 0, 0, 0);
            fd = 0 - 1;
            off = n;
        } else {
            off = off + k;
        };
    };
    // Sized after the write: a memfd starts empty, and mmap past the end of a
    // file gives SIGBUS rather than zeros, so the .bss needs the file to be
    // as long as the span.
    if (fd >= 0) {
        if (syscall(SYS_FTRUNCATE, fd, span, 0, 0, 0) != 0) {
            syscall(SYS_CLOSE, fd, 0, 0, 0, 0);
            fd = 0 - 1;
        };
    };
    fd
};

// The bytes the child needs addressable: the ELF's own image, plus the .bss at
// the offset past it the ELF header says. The mapping covers the whole span in
// one go, so nothing needs MAP_FIXED.
def img_span(im: Img) -> long {
    if (im.bss_len == 0) { page_up(im.memsz) }
    else { page_up(im.bss_delta + im.bss_len) }
};

def run_image_go(b: [byte], av: [str], want_out: bool, im: Img) -> RunRes {
    let m: Mapd = { img: 0, memsz: im.memsz, entry: im.entry, span: img_span(im),
                    rfd: 0 - 1, keep: 0 - 1 };
    if (want_out) {
        let pp = pipe_fds();
        if (!pp.ok) {
            run_fail("cannot create a pipe for the generator")
        } else {
            m.rfd = pp.rfd;
            m.keep = 0 - 1;
            run_image_fd(b, av, want_out, im, m, pp.wfd)
        }
    } else {
        run_image_fd(b, av, want_out, im, m, 0 - 1)
    }
};

def run_image_fd(b: [byte], av: [str], want_out: bool, im: Img, m0: Mapd, wfd: long) -> RunRes {
    let fd = image_fd(b, m0.span);
    if (fd < 0) {
        run_fail("cannot make an anonymous file for the image")
    } else {
        // Writable to start with, so the .bss (which the file zeroes) is
        // usable; the code part is then narrowed to R|X.
        let img = syscall(SYS_MMAP, 0, m0.span, PROT_RW, MAP_PRIVATE, fd, 0);
        syscall(SYS_CLOSE, fd, 0, 0, 0, 0);
        if (img < 0) {
            run_fail("cannot map the image (" + tostring(img) + ")")
        } else if (syscall(SYS_MPROTECT, img, im.memsz, PROT_RX, 0, 0, 0) != 0) {
            syscall(SYS_MUNMAP, img, m0.span, 0, 0, 0);
            run_fail("cannot make the image's code read+execute")
        } else {
            let m: Mapd = { img: img, memsz: im.memsz, entry: im.entry, span: m0.span,
                            rfd: m0.rfd, keep: m0.keep };
            run_image_clone(av, want_out, m, wfd)
        }
    }
};

def run_image_clone(av: [str], want_out: bool, m: Mapd, wfd: long) -> RunRes {
    let stk: [byte; 131072] = [0; 131072];
    let sp = fab_stack(stk[0:131072], av);
    let m2: Mapd = { img: m.img, memsz: m.memsz, entry: m.entry, span: m.span,
                     rfd: m.rfd, keep: m.keep };
    if (wfd >= 0) {
        // fd 3 is the child's way back: the injected helpers write pieces
        // there. fd 3 is saved and put back afterwards, so the compiler's own
        // fd 3 (if it had one) survives the run.
        m2.keep = syscall(SYS_DUP, GUEST_FD, 0);
        syscall(SYS_DUP2, wfd, GUEST_FD, 0, 0, 0);
        syscall(SYS_CLOSE, wfd, 0, 0, 0, 0);
    };
    run_image_fork(stk[0:131072], sp, m2, wfd)
};

// SIGCHLD, no CLONE_VM: a separate process with a copy-on-write copy of our
// address space, reaped by wait4 -- the fork the whole design rests on. The
// child comes back from the syscall with %rax = 0 and %rsp = `sp`, still
// running THIS code, one instruction later; `jmp_at` then hands it to the
// image with %rsp exactly where fab_stack put it.
def run_image_fork(stk: [byte], sp: long, m: Mapd, wfd: long) -> RunRes {
    let pid = syscall(SYS_CLONE, SIGCHLD, sp, 0, 0, 0);
    if (pid <= 0) {
        // The child: never returns.
        jmp_at(m.img + m.entry);
        map_release(m);
        run_fail("the image's entry point returned")
    } else {
        // The parent must not hold the write end: it is the only reader, and
        // the read below waits for end-of-file, which a pipe gives when EVERY
        // writer has closed. map_release puts the compiler's own fd 3 back.
        if (wfd >= 0) { syscall(SYS_CLOSE, GUEST_FD, 0, 0, 0, 0); };
        run_image_read(stk, m, pid)
    }
};

// Drain the pipe BEFORE the wait: a child writing more than a pipe buffer
// would block forever with nobody reading.
def run_image_read(stk: [byte], m: Mapd, pid: long) -> RunRes {
    let out: [byte] = [];
    if (m.rfd >= 0) {
        let buf: [byte; 65536] = [0; 65536];
        let at = ptr_addr(&buf[0]);
        let more = true;
        while (more) {
            let k = syscall(SYS_READ, m.rfd, at, 65536);
            if (k <= 0) {
                more = false;
            } else {
                let i = 0;
                while (i < k) { out += buf[i]; i = i + 1; };
            };
        };
    };
    let ws: [byte; 8] = [0; 8];
    syscall(SYS_WAIT4, pid, &ws[0], 0, 0, 0);
    let st = rd32(ws[0:8], 0);
    let low = st % 128;
    let status = 0;
    let sig = 0;
    if (low == 0) { status = (st / 256) % 256; }
    else if (low != 127) { sig = low; };
    map_release(m);
    { ok: true, status: status, sig: sig, out: out, err: "" }
};

// Put fd 3 back and unmap everything the run needed. ycc never frees, so this
// is not about the heap: the mappings are outside it, and R8 counts them.
def map_release(m: Mapd) -> long {
    if (m.keep >= 0) {
        syscall(SYS_DUP2, m.keep, GUEST_FD, 0, 0, 0);
        syscall(SYS_CLOSE, m.keep, 0, 0, 0, 0);
    } else if (m.rfd >= 0) {
        syscall(SYS_CLOSE, GUEST_FD, 0, 0, 0, 0);
    };
    if (m.rfd >= 0) { syscall(SYS_CLOSE, m.rfd, 0, 0, 0, 0); };
    if (m.img > 0) { syscall(SYS_MUNMAP, m.img, m.span, 0, 0, 0); };
    0
};


// ── the scanner ─────────────────────────────────────────────────────────
// The scanner's state is module-level, the way native.y's import bookkeeping
// is: one file at a time, reset by meta_scan, and the defs below take no
// state arguments. See `ideas/meta.md` for why this exists at all; the short
// version is that only CODE position is scanned, so a `#{` inside any literal
// or comment is plain text, there is no escape character anywhere, and a
// generator may emit string literals holding `#{` freely.
//
// The shape of the loop: one pass over the file's bytes, with the interesting
// bytes being a quote, a slash (a comment opener), a brace, a `;` and a
// newline. Everything between two of them is one slice, so the scan costs one
// allocation per interesting byte rather than one per byte -- which matters,
// because this runs over every byte of every file of a self-compile.
//
// The line map is built BY CONSTRUCTION and never repaired: every byte reaches
// the two buffers through sg_put (which counts it) or sg_break (which ends a
// line and starts the next), so a literal spanning four lines costs four lines
// of P and four of G, and a P line that spans several source lines carries the
// one it STARTED at -- the honest origin for generated text.

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
// A block that has no operand position at its own byte offset cannot put its
// call there (see sg_open), so its call is written HERE instead of into
// sg_gbuf, and sg_mids_move puts it at the top-level statement that contains
// it. The buffer is saved and restored per block, so a mid-token block nested
// in one is hoisted out of it -- in close order, which is the order the calls
// have to run in.
//
// sg_mmid says the innermost open block is mid-token, so sg_gadd and the
// writes below go here; sg_mbuf is the text and sg_mol the source line each of
// its lines started at (its lines move, so their origins travel with them).
let sg_mmid = false;
let sg_mbuf = "";
let sg_mol: [long] = [];
let sg_molast = false;
let sg_mline = 1;
// The buffer of an enclosing mid-token block, saved while a nested one is open
// and restored when it closes (so the nested call is hoisted out of it, not
// written into it).
let sg_midsave: [str] = [];
let sg_molsave: [[long]] = [];
let sg_mlastsave: [bool] = [];
let sg_mlinesave: [long] = [];
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
// The depth of the innermost open mid-token block, 0 for none, recomputed by
// sg_m_live whenever a block closes. A top-level `;` or `}` only ends a
// statement when no mid-token block is open, so the anchor cannot land inside
// one of these hoisted calls.
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
let sg_depth = 0;
// The block array index this file's first block takes, and the P line a block
// being opened sits on (-1 for a nested one, whose text P does not hold).
let mg_first = 0;
let mg_p_at = 0 - 1;
// The first diagnostic, and where. The rest of the text is not scanned.
let sg_err = "";
let sg_eline = 0;
let sg_ecol = 0;

def sg_reset(src: str, fid: long, dir: str) -> long {
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
    0
};

// Append text to whichever G buffer is live: the file's own, or a mid-token
// block's (its call is written there and hoisted afterwards, so it does not
// sit where the block stood). Blocks nest, so `mid` is the innermost block's.
def sg_gadd(t: str, mid: bool) -> long {
    if (mid) { sg_mbuf += t } else { sg_gbuf += t };
    0
};

// One piece of text, into both buffers. A byte inside a block reaches G only:
// P has to drop the block whole. Blanks do not count towards the enclosing
// block's "nothing but blanks yet" flag, which is what decides whether an
// `import` there is at the block's top level.
def sg_put(t: str) -> long {
    if (len(t) > 0) {
        let mid = sg_mmid;
        if (!mid) { sg_ts_go(t) } else { sg_molast = sg_ml_go(t) };
        sg_gadd(t, mid);
        if (sg_depth == 0) {
            sg_pbuf += t;
        } else if (!m_all_blank(t)) {
            sg_bclean[sg_depth - 1] = false;
        };
        sg_col = sg_col + len(t);
    };
    0
};

// One byte that is never a blank: a delimiter, or a word's first byte.
def sg_put1(c: str) -> long {
    if (sg_mmid) { if (!sg_molast) { sg_molast = true } }
    else { sg_ts_go(c) };
    sg_gadd(c, sg_mmid);
    if (sg_depth == 0) {
        sg_pbuf += c;
    } else {
        sg_bclean[sg_depth - 1] = false;
    };
    sg_col = sg_col + 1;
    0
};

// The top-level statement in progress: `t` is about to be written at
// (sg_gline, len(sg_gbuf)) -- or into a mid-token block's buffer, where there
// is no top-level statement to find. While one is being looked for, the first
// byte of `t` that is not a blank IS its first token; after that the statement
// has started and nothing moves it. Blanks and comments therefore never become
// the anchor, which is what puts a `// note` before a statement above it
// rather than inside it.
def sg_ts_go(t: str) -> long {
    if (!sg_tsp) {
        let i = 0;
        let go = true;
        while (go && i < len(t)) {
            if (!m_blank(byte_at(t, i))) {
                sg_tsline = sg_gline;
                sg_tsoff = len(sg_gbuf) + i;
                sg_tsp = true;
                go = false;
            };
            i = i + 1;
        };
    };
    0
};

// The source line a mid-token buffer's LAST line started at: the first byte of
// `t` that is not a blank, if there is one and none has been found yet (the
// line began when the buffer began, at whatever `}`#` came closest to).
def sg_ml_go(t: str) -> bool {
    if (sg_molast) { true }
    else {
        let i = 0;
        while (i < len(t)) {
            if (!m_blank(byte_at(t, i))) {
                sg_molast = true;
                sg_mline = sg_gline;
                i = len(t);
            };
            i = i + 1;
        };
        sg_molast
    }
};

// A top-level statement ends here, so the next one starts after what follows.
def sg_ts_end() -> long {
    sg_tsp = false;
    0
};

// End the current line in both texts. G always breaks (its line count tracks
// the source's, so a diagnostic in G has a line); P breaks only outside a
// block, because a block's own newlines belong to the call in G and not to a
// line of P. A line is a line: neither text keeps the newline, so the two
// join back to their sources.
//
// A mid-token block's call breaks into ITS buffer, and its origin goes with
// the line: the call is hoisted to another statement afterwards, so the two
// have to travel together or a diagnostic in G would name the wrong line.
def sg_break() -> long {
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
    sg_line = sg_line + 1;
    sg_col = 1;
    0
};

// sg_src[a:b] into both buffers, breaking lines on the newlines it holds. So
// a literal or a comment that spans lines costs the lines it really has, and
// the two texts stay in step with the source without either counting.
def sg_out(a: long, b: long) -> long {
    let i = a;
    while (i < b) {
        let nl = 0 - 1;
        let j = i;
        let go = true;
        while (go && j < b) {
            if (byte_at(sg_src, j) == 10) { nl = j; go = false; } else { j = j + 1; };
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
    0
};

// Set while `mg_probe` scans: the probe is asking "is there a block in this
// text", not "is this text a legal file", so it must read PAST a diagnostic
// (the text it is given is G's own, whose `ycc_meta_stmt` calls the program's
// own pass would refuse) instead of stopping at the first one.
let sg_quiet = false;

def sg_fail(msg: str, line: long, col: long) -> long {
    if (sg_err == "" && !sg_quiet) {
        sg_err = msg;
        sg_eline = line;
        sg_ecol = col;
    };
    0
};

// Any brace on the stack a `def`/`type` BODY opened? A `type` body is marked
// on the stack (2) and a `def` body by sg_pending together with its stack entry
// (1): a `type` header has braces of its own, so one flag cannot cover both.
// A mid-token block opens NO brace (its call is a statement somewhere else, so
// there is nothing here to be inside), which is why sg_open asks the body
// question and the header question separately.
def sg_in_body() -> bool {
    let hit = false;
    let i = 0;
    while (i < len(sg_bkind)) {
        let k = sg_bkind[i];
        if (k == 1 || k == 2) { hit = true };
        i = i + 1;
    };
    hit
};

// The names a block may not use: the thread and process primitives. Under the
// fork they are harmless -- a guest spawn's damage lands in the child and dies
// with it -- but they are refused anyway, because a generator that spawns is
// always a mistake and naming it is the whole value of the check. Only a CALL
// (`name(`) or a DEF (`def name`) is refused, so a generator may still use the
// word as a variable or a field.
def mg_thread(w: str) -> bool {
    w == "spawn" || w == "fork" || w == "join" || w == "mutex" || w == "lock" ||
    w == "try_lock" || w == "sem" || w == "post" || w == "wait"
};

// The names the pass injects into G. `y_`-prefixed, so a module imported into
// the generator namespaces its own names and cannot collide -- but the
// program's OWN top level is flat, so a def there is the collision.
def mg_reserved(w: str) -> bool {
    w == "ycc_meta_expr" || w == "ycc_meta_stmt" || w == "ycc_meta_emit"
};

// The next byte at or after i the scanner must stop at, or n. Only meaningful
// in code position: inside a comment or a literal everything is text.
//
// Outside a block the interesting bytes are all it needs, and a word is text
// between two of them. INSIDE a block a word start is interesting too, because
// that is where a refused name and an injected helper's name have to be caught,
// and they can sit anywhere in an expression (`let t = spawn { … }` is not at
// a statement boundary). So a block costs a check per word, and a file with no
// blocks costs nothing.
def sg_next(i: long, n: long) -> long {
    let j = i;
    let found = false;
    while (j < n && !found) {
        let c = byte_at(sg_src, j);
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
    let go = true;
    while (go && k < n && (byte_at(sg_src, k) == 32 || byte_at(sg_src, k) == 9 || byte_at(sg_src, k) == 13)) {
        k = k + 1;
    };
    if (k < n && m_word(byte_at(sg_src, k))) {
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
    let j = after;
    let go = true;
    while (go && j < n && (byte_at(sg_src, j) == 32 || byte_at(sg_src, j) == 9)) {
        j = j + 1;
    };
    let called = j < n && (byte_at(sg_src, j) == 40 || byte_at(sg_src, j) == 123);
    if (w == "def" || w == "type") {
        // the NAME it defines, not the keyword: a collision with an injected
        // helper is a duplicate top-level def, and it is silent in the
        // generator the same way it would be in the program
        if (j < n && m_word(byte_at(sg_src, j))) {
            sg_check_name(m_word_at(sg_src, j, n), true);
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
def sg_check_name(w: str, called: bool) -> long {
    if (mg_reserved(w)) {
        sg_fail("'" + w + "' is reserved: the meta pass injects it into the generator", sg_line, sg_col);
    } else if (sg_depth > 0 && mg_thread(w) && called) {
        sg_fail("'" + w + "' cannot be used in a meta block: the generator runs in a forked child, and a thread or process primitive there is never what was meant", sg_line, sg_col);
    };
    0
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
            let c = byte_at(sg_src, j);
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
def mg_import_line(rest: str, dir: str) -> str {
    let k = index_of(rest, " from ");
    if (k < 0) {
        "import " + rest
    } else {
        let name = rest[:k];
        let tail = rest[k + 6:];
        let path = tail;
        if (len(path) >= 2 && path[0:1] == "\"" && path[len(path) - 1:] == "\"") {
            let p = path[1:len(path) - 1];
            let full = p;
            if (p[:1] != "/") { full = dir + "/" + p; };
            path = "\"" + mg_norm_path(full) + "\"";
        };
        "import " + name + " from " + path
    }
};

// Whether the byte before src[i] ends a token -- a name, a number, a literal
// or a closing bracket. Then the block has no operand position at its own byte
// offset, and it is a MID-TOKEN block: the call cannot go there
// (`def helper<call>()` is not a def), so its bytes are dropped from G and its
// call is hoisted (see sg_open and sg_mids_move).
//
// "Immediately before" -- a space is enough to make it a separate token, and a
// separate token that starts an operand is not mid-token: `return #{ … }#`,
// `f(#{ … }#, 2)` and `a[#{ … }#]` all keep the call in place.
def m_token_end(c: long) -> bool {
    if (c == 0) { false }
    else if (c == c')' || c == c']' || c == c'}' || c == c'.' || c == c'\'' || c == c'\"') { true }
    else { m_word(c) }
};

// `#{` at i in code position: check it, record the block, open it, and read the
// word after it (which may be an `import`). Returns where to carry on from, or
// n when the block is refused.
def sg_open(i: long, n: long) -> long {
    let prev = 0;
    if (i > 0) { prev = byte_at(sg_src, i - 1); };
    let mid = sg_col > 1 && m_token_end(prev);
    // A block may not be lexically inside a def or type body: in-place emission
    // there would give compile-time-fixed values and a silent "never ran" mode.
    // A MID-TOKEN one in a def's HEADER is not inside the body though --
    // `def helper#{...}#()` is generating the name, which is the point -- so a
    // body brace is what refuses it, not the `def` keyword.
    if (sg_in_body()) {
        sg_fail("a meta block cannot be inside a def or type body: only the top level and other blocks", sg_line, sg_col);
        n
    } else if (sg_pending && !mid) {
        // In a header, at an operand position: the call cannot go in a header
        // (`def ycc_meta_stmt(...)(x)` is not a def) and the block is not
        // mid-token, so dropping its bytes is not a join of two adjacent tokens
        // -- for `def #{nm}#()` it would leave `def () -> long`. So a header
        // block has to be a fragment of the name, with the name on one side.
        sg_fail("a meta block in a def or type header must be part of a name, with a character of the name beside it: a call cannot go in a header, and dropping the block's bytes would leave nothing behind", sg_line, sg_col);
        n
    } else if (sg_depth + 1 > MG_NEST) {
        sg_fail("meta blocks nest deeper than " + tostring(MG_NEST) + ", the pass's limit", sg_line, sg_col);
        n
    } else {
        let slot = mg_next;
        mg_next = slot + 1;
        mg_bfile += sg_fid;
        mg_bline += sg_line;
        mg_p_at = 0 - 1;
        if (sg_depth == 0) { mg_p_at = len(sg_p); };
        mg_bslot += slot;
        mg_bp += mg_p_at;
        mg_bpo += len(sg_pbuf);
        mg_n = mg_n + 1;
        sg_bmid += mid;
        // A statement-position block is one that held only blanks before it, and
        // a mid-token one is a statement by construction (it could not be an
        // expression there), so both want the `;` and the void helper.
        let stmt = mid || m_all_blank(sg_gbuf[sg_gat:]);
        sg_bstmt += stmt;
        sg_bclean += true;
        sg_bbrace += len(sg_bkind);
        sg_depth = sg_depth + 1;
        sg_bound = true;
        if (mid) {
            sg_m_open(slot)
        } else {
            let helper = "ycc_meta_expr";
            if (stmt) { helper = "ycc_meta_stmt" };
            sg_gadd(helper + "(" + tostring(slot) + ", {", sg_mmid);
            sg_col = sg_col + 2;
        };
        let k = sg_word(i + 2, n);
        sg_col = sg_col + (k - (i + 2));
        k
    }
};

// A mid-token block: the call goes to a buffer of its own, and sg_mids_move
// puts it at the top-level statement that contains the block. The buffer of an
// enclosing mid-token block is saved and restored, so a nested one is hoisted
// out of it -- and since the moves are applied in close order, it runs first.
//
// The call is ALWAYS a statement (`ycc_meta_stmt`, with its `;`): a mid-token
// block is one that could not be an operand where it stands, so it is a
// statement by construction, whatever the text around it looks like.
def sg_m_open(slot: long) -> long {
    sg_midsave += sg_mbuf;
    sg_molsave += sg_mol;
    sg_mlastsave += sg_molast;
    sg_mlinesave += sg_mline;
    sg_mmid = true;
    sg_mdepth = sg_depth;
    sg_mbuf = "";
    sg_mol = [];
    sg_molast = false;
    sg_mline = sg_gline;
    sg_mbuf += "ycc_meta_stmt(" + tostring(slot) + ", {";
    sg_col = sg_col + 2;
    0
};

// `}#` of a mid-token block: close the call, record it with the statement to
// hoist it to, and restore whatever buffer was live (the enclosing block's own,
// or an enclosing mid-token block's). Recorded in CLOSE order, which is the
// order the calls have to run in.
def sg_m_close() -> long {
    sg_mbuf += "});";
    let lines = mg_lines(sg_mbuf);
    let ol: [long] = [];
    let i = 0;
    while (i < len(lines)) {
        if (i < len(sg_mol)) { ol += sg_mol[i] }
        else if (sg_molast) { ol += sg_mline }
        else { ol += sg_gline };
        i = i + 1;
    };
    let line = sg_tsline;
    let off = sg_tsoff;
    if (line < 1) { line = 1 };
    if (off < 0) { off = 0 };
    sg_mids += { line: line, off: off, text: lines, ol: ol };
    sg_mbuf = sg_midsave[len(sg_midsave) - 1];
    sg_midsave = sg_midsave[0:len(sg_midsave) - 1];
    sg_mol = sg_molsave[len(sg_molsave) - 1];
    sg_molsave = sg_molsave[0:len(sg_molsave) - 1];
    sg_molast = sg_mlastsave[len(sg_mlastsave) - 1];
    sg_mlastsave = sg_mlastsave[0:len(sg_mlastsave) - 1];
    sg_mline = sg_mlinesave[len(sg_mlinesave) - 1];
    sg_mlinesave = sg_mlinesave[0:len(sg_mlinesave) - 1];
    0
};

// Which G buffer is live now that the block has closed and the per-block
// stacks have been popped: a mid-token block's own if one is still open, and
// sg_mdepth says at what depth (0 = the file's own buffer).
def sg_m_live() -> long {
    sg_mmid = false;
    sg_mdepth = 0;
    let k = sg_depth - 1;
    while (k >= 0) {
        if (sg_bmid[k]) { sg_mmid = true; sg_mdepth = k + 1 };
        k = k - 1;
    };
    0
};

// Put every hoisted call at the top-level statement that contains its block.
// The list is in close order -- innermost first, then siblings in source order
// -- so within one statement the calls are inserted BACKWARDS, each landing
// before the one already there, which leaves them in the list's order. And the
// statements are done from the last to the first, so an insertion never moves a
// position a later pass still has to read.
def sg_mids_move() -> long {
    let n = len(sg_mids);
    let done: [bool] = [];
    let i = 0;
    while (i < n) { done += false; i = i + 1; };
    let left = n;
    while (left > 0) {
        let at = 0 - 1;
        let j = 0;
        while (j < n) {
            if (!done[j]) {
                if (at < 0 || mg_after(j, at)) { at = j };
            };
            j = j + 1;
        };
        if (at < 0) { left = 0 }
        else {
            sg_mids_one(at);
            done[at] = true;
            left = left - 1;
        };
    };
    sg_mids = [];
    0
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
def sg_mids_one(k: long) -> long {
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
    let i = 0;
    while (i < len(m.text)) {
        rest += m.text[i];
        restf += sg_fid;
        let o = 0;
        if (i < len(m.ol)) { o = m.ol[i] };
        restl += o;
        i = i + 1;
    };
    if (tail != "") { rest += tail; restf += sg_fid; restl += m.line };
    let t = ln + 1;
    while (t < len(sg_g)) {
        rest += sg_g[t];
        restf += sg_gf[t];
        restl += sg_gol[t];
        t = t + 1;
    };
    sg_g = rest;
    sg_gf = restf;
    sg_gol = restl;
    0
};

// `}#` with sg_depth == 0: nothing opened it.
def sg_stray(i: long) -> long {
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
        mg_g += sg_g;
        mg_gol += sg_gol;
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
    if (j < n) { c = byte_at(sg_src, j) };
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
        // after it (see sg_ts_go)
        if (sg_depth == 0 && sg_mdepth < 1) { sg_ts_end() };
        j + 1
    } else {
        j
    }
};

// A `/`: `//`, `/*`, or division.
def sg_slash(j: long, n: long) -> long {
    if (j + 1 < n && byte_at(sg_src, j + 1) == 47) {
        sg_state = 1;
        sg_put1("/");
        sg_put1("/");
        j + 2
    } else if (j + 1 < n && byte_at(sg_src, j + 1) == 42) {
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
    if (j + 1 < n && byte_at(sg_src, j + 1) == 35) {
        if (sg_depth == 0) {
            sg_stray(j);
            n
        } else {
            let was_mid = sg_bmid[sg_depth - 1];
            if (was_mid) {
                // the call is not here: sg_m_close hoists it to the statement
                sg_m_close()
            } else {
                // a statement-position call is a statement, and a statement
                // wants its ';'; in expression position the call is the
                // expression and a ';' there would be a syntax error
                sg_gadd("})", sg_mmid);
                sg_col = sg_col + 2;
                if (sg_bstmt[sg_depth - 1]) { sg_gadd(";", sg_mmid); sg_col = sg_col + 1; };
            };
            // the per-block stacks are popped here, so `sg_depth - 1` is always
            // this block's entry and never one left over from a block that has
            // already closed
            sg_bstmt = sg_bstmt[0:len(sg_bstmt) - 1];
            sg_bmid = sg_bmid[0:len(sg_bmid) - 1];
            sg_bclean = sg_bclean[0:len(sg_bclean) - 1];
            sg_bbrace = sg_bbrace[0:len(sg_bbrace) - 1];
            sg_depth = sg_depth - 1;
            if (was_mid) { sg_m_live() };
            j + 2
        }
    } else {
        if (len(sg_bkind) > 0) {
            sg_bkind = sg_bkind[0:len(sg_bkind) - 1];
        };
        sg_bound = true;
        sg_put1("}");
        // a top-level `}` closes whatever construct it was in, and the next
        // statement starts after it
        if (sg_depth == 0 && sg_mdepth < 1) { sg_ts_end() };
        j + 1
    }
};

// `#` in code position: `#{` opens a block, anything else is an error. A stray
// `#` already reaches the lexer as "expected an expression, got '#'"; this is
// the same refusal with a message that names the construct.
def sg_hash(j: long, n: long) -> long {
    if (j + 1 < n && byte_at(sg_src, j + 1) == 123) {
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
        if (byte_at(sg_src, j) == 10) { go = false; } else { j = j + 1; };
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
        if (byte_at(sg_src, j) == 42 && byte_at(sg_src, j + 1) == 47) {
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

// A literal: lit_end finds where it ends and whether it closed, so the one
// scanner both the lexer and this pass agree on. A literal is not
// newline-terminated (lexer.y), so it may hold newlines.
//
// An f-string is the one form lit_end cannot be asked about: a field holds an
// expression, and that expression may be a string literal, so its closing
// quote is not the next quote in the source. The lexer's own fstr_walk finds
// it, and it falls back to lit_end itself when the f-string is broken.
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
    byte_at(sg_src, i) == 34 && i > 0 && byte_at(sg_src, i - 1) == 102 &&
        (i == 1 || !m_word(byte_at(sg_src, i - 2)))
};
// ── the driver ──────────────────────────────────────────────────────────
// `meta_begin`/`mg_*` accumulate across a whole resolve; `meta_run_gen` builds
// G and hands back its text, and `mg_take_pieces` reads the pieces out of a
// run. The COMPILE and the RUN are in native.y (`meta_run_generator`): they
// need emit_program and std_units, which live there, and meta.y must not
// import native.y -- the two import each other (native.y owns the pass's
// position, meta.y the pass itself) and Y's splicer does not survive a cycle:
// it dedups on the way down, so the file on the way back up is spliced a second
// time and every def collides.
//
// The pieces come back over the pipe framed as `<slot> <len>\n<body>`, so a
// piece is matched to its block by SLOT and not by the order the generator
// happened to evaluate blocks in. That matters: a nested block's text is
// produced BEFORE its parent's, so source order and execution order differ.

// One piece per slot, and whether it arrived.
let mg_piece: [str] = [];
let mg_have: [bool] = [];
// Whether the pieces are known: false while scanning to collect the blocks,
// true on the second pass, when the scanner can splice.
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

def meta_begin() -> long {
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
    mg_pass()
};

// A new PASS over the same files -- and the block table, G's body and the
// hoisted imports are all per-pass. A block's SLOT is its index in the block
// table, and the table is rebuilt from scratch each pass, so the second pass
// over the same files in the same order hands out the SAME slots: that is how
// a piece the generator wrote is matched to the block that asked for it. The
// pieces themselves survive -- they are what the second pass splices.
def mg_pass() -> long {
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
    mg_n = 0;
    0
};

// native.y hands the generator its resolution over this, because
// `meta.<field> = v` is a namespaced field ASSIGNMENT and strip_ns rewrites
// only namespaced dot READS (it handles K.dot, not K.dotassign -- see
// strip_ns), so a module cannot set another module's global by name.
def mg_setup(root: str, files: [str], base: str, exec: bool, pkgs: [str], roots: [str]) -> long {
    mg_root = root;
    mg_files = files;
    mg_gbase = base;
    mg_gexec = exec;
    mg_pkgs = pkgs;
    mg_roots = roots;
    0
};

// The pass is off for the generator's own compile: G is ordinary Y, and
// anything a generator emits is never re-scanned, so nothing in it can open a
// block. This is what makes "a block's output may not contain a block" true by
// construction rather than by checking.
def mg_set(on: bool) -> long {
    mg_on = on;
    0
};

def mg_in(xs: [str], s: str) -> bool {
    let hit = false;
    let i = 0;
    while (i < len(xs)) {
        if (xs[i] == s) { hit = true; };
        i = i + 1;
    };
    hit
};

// A fatal pass-level diagnostic. Every leak path out of the pass is one of
// these, never a hand-off to the lexer (see the spec's invariant 1): whatever
// `#{` the scanner was meant to catch is caught here, with its line.
def mg_report(msg: str) -> long {
    puts("error: " + msg + "\n");
    exit(1);
    0
};

// The helpers G carries, and the one they share. `y_`-prefixed, so a module
// imported into the generator namespaces its own names (rename.y) and cannot
// collide with them; the program's own flat top level can, and that is
// mg_reserved's diagnostic.
//
// Each writes its piece to fd 3 framed as `<slot> <len>\n<body>`, which is what
// lets the parent read a piece back in any order and with any bytes in it --
// including newlines, which most of them have.
def mg_helpers() -> [str] {
    [
"def ycc_meta_emit(slot: long, body: str) -> void {",
"    let h = tostring(slot) + \" \" + tostring(len(body)) + \"\\n\";",
"    let hb = bytes(h);",
"    syscall(1, 3, &hb[0], len(hb));",
"    let b = bytes(body);",
"    if (len(b) > 0) { syscall(1, 3, &b[0], len(b)); 0; };",
"    0",
"};",
"def ycc_meta_expr(slot: long, body: str) -> str {",
"    ycc_meta_emit(slot, body);",
"    body",
"};",
"def ycc_meta_stmt(slot: long, body: str) -> void {",
"    ycc_meta_emit(slot, body);",
"    0",
"};",
    ]
};

// G's text: the helpers, then the hoisted imports, then the files' own lines
// with each block as a call. The imports go after the helpers and before the
// body, so a hoisted module's own statements see the helpers.
def meta_gtext() -> str {
    let out: [str] = [];
    let hs = mg_helpers();
    let i = 0;
    while (i < len(hs)) {
        out += hs[i];
        i = i + 1;
    };
    let k = 0;
    while (k < len(mg_imp)) {
        out += mg_imp[k];
        k = k + 1;
    };
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
        k = k + 1;
    };
    let path = mg_root;
    if (f < len(mg_files)) { path = mg_files[f] };
    path + ":" + tostring(ln)
};

// ── the piece table ─────────────────────────────────────────────────────

// Split the pipe's bytes into pieces. A framing error means the generator did
// not run our helpers, which cannot happen unless the pass is broken.
def mg_unframe(data: str) -> long {
    let n = len(data);
    let i = 0;
    let bad = false;
    while (i < n && !bad) {
        let j = i;
        let go = true;
        while (go && j < n && byte_at(data, j) != 10) { j = j + 1; };
        if (j >= n) {
            bad = true;
        } else {
            let head = data[i:j];
            let sp = index_of(head, " ");
            if (sp < 0) {
                bad = true;
            } else {
                let slot = tonum(head[:sp]);
                let take = tonum(head[sp + 1:]);
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
        1
    } else {
        0
    }
};

// The first slot with no piece, or -1. A block at the top level always runs
// (the top level IS the generator's program), so a gap means the generator
// did not reach it -- and the message can name it.
def mg_first_missing() -> long {
    let at = 0 - 1;
    let i = 0;
    while (i < mg_next) {
        if (!mg_have[i]) { at = i; };
        i = i + 1;
    };
    at
};

// Read back what a run produced: check the child's fate, unframe, check every
// piece, and report the first thing that is wrong. Returns false if the
// generator died, having said as much as can be said.
def mg_take_pieces(status: long, sig: long, out: [byte]) -> bool {
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
    let i = 0;
    while (i < mg_next) {
        if (!mg_have[i]) {
            mg_report("the block at " + mg_where(i) + " produced no output: every meta block runs once, in the generator's top level, so reaching it is not optional");
        };
        mg_check(i);
        i = i + 1;
    };
    mg_ready = true;
    r
};

// ", and the first block that produced nothing was at ..." when there is one.
def mg_blame() -> str {
    let m = mg_first_missing();
    if (m < 0) { "" } else { ", and the first block that produced nothing was at " + mg_where(m) }
};

// The checks a piece must pass before it is spliced into the program's
// source. Each names the block, because "the generator emitted something bad"
// is not a message a reader can act on.
def mg_check(s: long) -> long {
    let p = "";
    if (s < len(mg_piece)) { p = mg_piece[s] };
    if (index_of(p, "#{") >= 0) {
        mg_report("the block at " + mg_where(s) + " emitted a #{ … }# block: generated text is never re-scanned, so a block cannot emit one");
    };
    if (index_of(p, "\x00") >= 0) {
        mg_report("the block at " + mg_where(s) + " emitted a NUL byte, which cannot be in a source file");
    };
    0
};

// A `#{` in the text the generator resolved -- which is to say in a module the
// generator imported. G is compiled with the pass off, so such a block would
// arrive at the lexer as a bare `#`, and "expected an expression, got '#'" is
// not a message anyone can act on. Probed with the real scanner, with the
// block table saved and put back, so the probe cannot perturb the program's
// own pass.
def mg_probe(src: str, dir: str) -> bool {
    let n = mg_next;
    let bs = mg_bslot;
    let bf = mg_bfile;
    let bl = mg_bline;
    let bp = mg_bp;
    let bo = mg_bpo;
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
    let i = 0;
    while (i < len(parts)) {
        let seg = parts[i];
        if (seg != ".") { out += seg; };
        i = i + 1;
    };
    join(out, "/")
};
// ── the splice ──────────────────────────────────────────────────────────
// A block's piece goes at the byte offset recorded when its `#{` was scanned,
// in the P line recorded then. The line map is rebuilt here, not repaired: a
// piece is text and may hold any number of newlines, so the lines after it
// shift by however many it added, and every line the pass generates carries the
// `#{` line -- which is the honest origin, there being no better one.

// text's physical lines, and NOT split(): split drops ONE trailing empty
// element, so split("a\n", "\n") is ["a"] and the line break a piece ends on
// would be swallowed. A piece is generated text, and every byte of it counts.
def mg_lines(text: str) -> [str] {
    let out: [str] = [];
    let n = len(text);
    let start = 0;
    let i = 0;
    while (i < n) {
        if (byte_at(text, i) == 10) {
            out += text[start:i];
            start = i + 1;
        };
        i = i + 1;
    };
    out += text[start:];
    out
};

// Split the segments into physical lines: a segment's first part joins the
// line being built if there is one, every part after the first starts a new
// line (a newline was crossed), and the last line is flushed at the end.
//
// `segp[s]` says whether segment `s` is generated text, and `ngen` gets one
// entry per line emitted saying whether that line is wholly generated. A line
// is wholly generated when every segment feeding it is -- which is what lint's
// "a top-level statement runs twice" check needs to tell the user's own
// statement from the text a block put there.
def mg_emit(segs: [str], sego: [long], segp: [bool], fid: long, nl: [str],
            nf: [long], nll: [long], ngen: [bool]) -> long {
    let cur = "";
    let curo = 0;
    let cgen = true;
    let s = 0;
    while (s < len(segs)) {
        let text = segs[s];
        let o = sego[s];
        let p = false;
        if (s < len(segp)) { p = segp[s] };
        let parts = mg_lines(text);
        let k = 0;
        while (k < len(parts)) {
            if (k == 0) {
                // this part joins the line being built: it is that line's
                // first text if it is empty, and joins the rest otherwise
                if (cur == "") { curo = o; cgen = p; } else { cgen = cgen && p; };
            } else {
                nl += cur;
                nf += fid;
                nll += curo;
                ngen += cgen;
                cur = "";
                curo = o;
                cgen = p;
            };
            cur += parts[k];
            k = k + 1;
        };
        s = s + 1;
    };
    nl += cur;
    nf += fid;
    nll += curo;
    ngen += cgen;
    0
};

// Splice blocks [lo, hi) -- this file's -- into the scanned P. A no-op when the
// pieces are not known yet (the collecting pass).
def mg_splice(lo: long, hi: long) -> long {
    if (!mg_ready) { 0 }
    else {
        let lines = sg_p;
        let ols = sg_pol;
        let nl: [str] = [];
        let nf: [long] = [];
        let nll: [long] = [];
        let ngen: [bool] = [];
        let i = 0;
        while (i < len(lines)) {
            mg_splice_line(lines[i], ols[i], i, lo, hi, nl, nf, nll, ngen);
            i = i + 1;
        };
        sg_p = nl;
        sg_pf = nf;
        sg_pol = nll;
        sg_gen = ngen;
        0
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
            let s = mg_bslot[k];
            segs += mg_piece[s];
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
export { run_image, RunRes, Img, elf_img,
         meta_begin, mg_pass, mg_set, mg_setup, mg_on, mg_check, mg_report,
         mg_probe, mg_take_pieces, meta_scan, Scan, scan_none,
         meta_gtext, mg_ghead, mg_glines, mg_gol, mg_gbase, mg_gexec, mg_pkgs, mg_roots,
         mg_root };