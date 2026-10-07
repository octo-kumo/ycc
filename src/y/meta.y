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

// The runtime's strtoll-shaped read, whose body rt.y owns: leading whitespace
// skipped, a sign allowed, digits to the first non-digit, 0 when there are none.
// The C copy reaches the same read through ys_tolong (strtoll), and the two
// compilers must agree byte for byte, so this must NOT be the checked tolong.
// The leading number in s, 0 when there is none: leading whitespace skipped, a
// sign allowed, digits run to the first byte that is not one, and a string with
// no digits at all is 0. THIS IS NOT tolong. The C copy reaches the same read
// through ys_tolong, which is strtoll, and the two compilers have to agree byte
// for byte: the emitter's own reads -- a slot mark, a .loc field, a pack size --
// were written against THAT, and using the checked tolong there traps on inputs
// the C side has always accepted (measured: the -g meta fixtures, where the two
// compilers produced different diagnostics). strtoll clamps rather than wraps.
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
// One piece per slot, and whether it arrived. The pieces come back over the pipe
// framed as `<slot> <len>\n<body>`, so a piece is matched to its block by SLOT
// and not by the order the generator happened to evaluate blocks in. That
// matters: a nested block's text is produced BEFORE its parent's, so source order
// and execution order differ.
//
// They are here rather than with the driver because the SCANNER reads them: a
// nested block whose piece has arrived contributes that text to the source of the
// block around it instead of a call (sg_open), which is the whole of nesting.
// And they SURVIVE mg_pass, which is what makes the rounds work -- the piece
// table is the one thing that carries from a round to the next, and a block's
// slot is the same in every round because the block table is built the same way
// every round.
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
// Whether each block has ever had a block open inside it. It is structural --
// the same every round, and the block table is built the same way every round --
// so it is never cleared, and it is what a round knows about a block's children
// BEFORE it has scanned them: a block that may hold a nested block holds its
// text (sg_hold), because a nested block's text goes into the enclosing block's
// source and has to be known before that source is compiled.
let mg_bkids: [bool] = [];
// The emitted-text size cap (R8 is not negotiable). The piece table is read
// into memory, so this is what bounds it.
const MG_MAX = 33554432;
// The pass's own nesting cap. It is a COST bound and not a parser bound: a level
// of nesting costs one more compile and one more run of the generator, because
// a nested block's text has to be known before the source of the block around it
// can be compiled (mg_pending). The parser's own limit is ~333 effective (tags.y
// MAX_NEST is 1000 and each nested block costs ~3 nest units), so 8 is far below
// both, and MEASURED per level: see ideas/meta.md, "Nesting".
const MG_NEST = 8;
// How many rounds meta_prepare will do before it calls the round logic broken.
// One round per level of nesting plus one for a program that has none, so a
// program the scanner accepted cannot reach it.
const MG_ROUND = MG_NEST + 2;
// The reduction: on for a program that HAS nesting, and off otherwise. A round
// in which a block could not produce its text leaves a stub where its call goes
// (sg_top_close), so a statement reading a name that block was going to define
// would not compile -- and the statements in question bind nothing, so dropping
// them costs the generator no name at all (sg_region_close).
let mg_reduce = false;
// The collecting scan: the one that finds the blocks, before anything is known.
// It never holds a block's text and never reduces, so the G it builds for a
// program with no nesting is the G the pass has always built.
let mg_collect = true;

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
    c == ' ' || c == '\t' || c == '\n' || c == '\r'
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
def m_prev(src: str, i: long) -> long {
    let c: byte = 0;
    if (i > 0) { c = src[i - 1]; };
    c
};

// Whether the byte before a `#{` ends a token -- a name, a number, a literal
// or a closing bracket. Then the block sits between two tokens of one
// expression, where a call cannot go (`def helper#{x++}#()`), and it is an
// error rather than a feature: generating a NAME has no expression position
// for the call to occupy.
// It is also what marks a MID-TOKEN block: the call cannot go at the block's
// own byte offset either (`def helper<call>()` is not a def), so such a block's
// bytes are dropped from G and its call hoisted (see sg_open and sg_mids_move).
def m_token_end(c: long) -> bool {
    if (c == 0) { false }
    else if (c == ')' || c == ']' || c == '}' || c == '.' || c == '\'' || c == '\"') { true }
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
        i++;
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
        for j in 0..n { stk[at + j] = s[j]; };
        stk[at + n] = 0;
        ptrs += p;
        k++;
    };
    p = p - 8 * (m + 1);
    p = p - p % 8;
    k = 0;
    while (k < m) {
        put64(stk, p - base + 8 * k, ptrs[k]);
        k++;
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
            off += k;
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
        // Once the text has passed MG_MAX, STOP KEEPING IT and keep draining:
        // a generator that emits without bound must not take the compiler's
        // memory with it, and the failure is already decided -- mg_take_pieces
        // reports "emitted more than MG_MAX" for exactly this. The drain is
        // not optional: the child is still writing, and a writer that fills
        // the pipe blocks forever with nobody reading it. (Found by the
        // fuzzer: the C copy boxes every byte, so collecting all of a 92 MiB
        // hostile emission first cost it GBs and it died with "out of memory"
        // where the Y copy reported the cap.)
        let capped = false;
        while (more) {
            let k = syscall(SYS_READ, m.rfd, at, 65536);
            if (k <= 0) {
                more = false;
            } else if (!capped) {
                for i in 0..k { out += buf[i]; };
                if (len(out) > MG_MAX) { capped = true; };
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
// The same machinery HOLDS the text of a block that has to give it up: a nested
// block whose text is already in the table contributes TEXT to the block around
// it, and a block that cannot produce its text this round contributes a stub --
// so in both cases its own bytes are scanned (the slots of the blocks inside it
// have to be the same every round) and then dropped, and sg_hold/sg_drop is how
// that is said. Nothing is written to the live buffer while a block is held, so
// the text before the block, the line it is on and the statement it belongs to
// are all still exactly where they were.
//
// sg_mmid says a block is held, so sg_gadd and the writes below go here;
// sg_mbuf is the text and sg_mol the source line each of its lines started at
// (its lines move, so their origins travel with them).
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
// Per open block, for the nesting: its slot (mg_have is indexed by it), whether
// every block opened inside it had its text when it closed, whether its text
// was already in the table -- in which case it contributes TEXT to the block
// around it and never runs -- and whether its own text is held rather than
// written into the live buffer as it is scanned.
let sg_bslot: [long] = [];
let sg_bok: [bool] = [];
let sg_bsplice: [bool] = [];
let sg_bdead: [bool] = [];
let sg_bhold: [bool] = [];
let sg_depth = 0;
// The top-level statement in progress, for the reduction (mg_reduce): the line
// of G it starts on, the text of the line in progress when it started and the
// source line that line began at -- so a drop can put both back -- whether it is
// a declaration, whether a block is inside it, and whether its first word has
// not been read yet.
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
def sg_gadd(t: str, mid: bool) -> long {
    if (mid) { sg_mbuf += t } else { sg_gbuf += t };
    0
};

// Hold this block's text: from here to its `}#` it goes to a buffer of its own
// and nowhere else. sg_restore puts it back where it came from; sg_drop throws
// it away. Nothing is written to the live buffer meanwhile, which is what makes
// both safe.
def sg_hold() -> long {
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
    0
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

// The held text, back in the buffer it came from, in place, between `pre` and
// `post`. The live buffer has not moved -- nothing was written to it while the
// block was held -- so this is an append, and each line goes back with the origin
// it was scanned under. The line the text after the block continues is the one
// the held text's last line started at, so that is what the G line counter goes
// back to.
//
// `pre`/`post` are the block's own call: the prefix cannot be written at the
// `#{` any more, because whether this round has the text of every block inside
// is only known at the `}#` (see sg_top_close).
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
def sg_drop() -> long {
    sg_gline = sg_glsaved;
    sg_m_pop()
};

// A block's own text, spliced into the source of the block AROUND it where the
// block stood: this is what a nested block contributes once the table has its
// text (sg_splice is the nesting, not a call in the enclosing block's source).
// `at` is the line of its `#{` and every generated line takes it, for the same
// reason the pieces spliced into P do (mg_splice): the text is this block's, so
// the lines are its line, whatever line of G they land on.
//
// The block around it is always held, so the text goes to sg_mbuf; called
// BEFORE sg_hold, because the text belongs to the enclosing block.
def sg_splice(slot: long, at: long) -> long {
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
        sg_col += len(t);
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
    sg_col++;
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
            if (!m_blank(t[i])) {
                sg_tsline = sg_gline;
                sg_tsoff = len(sg_gbuf) + i;
                sg_tsp = true;
                go = false;
            };
            i++;
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
    sg_line++;
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
    sg_bkind.foreach((e) => {
        let k = e;
        if (k == 1 || k == 2) { hit = true };
    });
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
        let c = sg_src[j];
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
    while (go && k < n && (sg_src[k] == 32 || sg_src[k] == 9 || sg_src[k] == 13)) {
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
    let go = true;
    while (go && j < n && (sg_src[j] == 32 || sg_src[j] == 9)) {
        j = j + 1;
    };
    let called = j < n && (sg_src[j] == 40 || sg_src[j] == 123);
    if (w == "def" || w == "type") {
        // the NAME it defines, not the keyword: a collision with an injected
        // helper is a duplicate top-level def, and it is silent in the
        // generator the same way it would be in the program
        if (j < n && m_word(sg_src[j])) {
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

// Whether a block has ever had a block open inside it. Structural, so the table
// is the same in every round and is never cleared; a slot nobody has reached yet
// reads false. sg_open needs it BEFORE it has scanned the block's own body, to
// know whether to hold that body.
def mg_bkids_had(slot: long) -> bool {
    while (len(mg_bkids) <= slot) { mg_bkids += false };
    mg_bkids[slot]
};

// Record the nesting shape: a block that opens inside another one.
def mg_kid_note(par: long) -> long {
    while (len(mg_bkids) <= par) { mg_bkids += false };
    mg_bkids[par] = true;
    0
};

// ── the reduction ─────────────────────────────────────────────────────────
// On for a program that HAS nesting (mg_reduce). A round in which a block could
// not produce its text leaves a STUB where its call goes (sg_top_close), so a
// statement reading a name that block was going to define would not compile:
// `#{ let v = #{ "1+1" }#; let x = v; }#` then `print(x);` names `x` in a program
// that has not been generated yet. So in such a round a top-level statement that
// is neither a declaration nor carries a block is left out of G altogether.
//
// That costs the generator no name: the only statements dropped are ones that
// begin with `print(`, `f(`, an operator -- none of which declares anything -- so
// every binding G needs is still there, and a block reads exactly the same names.
// It does cost a block the SIDE EFFECT of such a statement, which is what the
// pass's own warning about top-level statements already says to avoid.
//
// The extent is exact and needs no parser. A top-level statement in Y ends at a
// `;` or at the `}` that closes it (MEASURED: `print(1)` with no `;` is
// "expected ';'"), so the regions here are exactly the statements. A block
// statement has no terminator of its own and so runs on to the next one -- which
// is harmless, because a region holding a block is never dropped.
def sg_region_open() -> long {
    // The line in progress when a region starts belongs to the region that ENDS
    // here, not to this one: so it is kept aside, and dropping this region puts
    // it back. Everything else this region adds is whole G lines, so a drop is a
    // truncation of those plus this one string.
    //
    // The line counter goes back with them: the dropped lines were not in G, so
    // nothing may carry on counting from them -- the same reason sg_drop rewinds
    // it for a dropped block.
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
def sg_region_word(w: str) -> long {
    if (sg_rpend) {
        sg_rpend = false;
        if (mg_directive(w)) { sg_rkeep = true };
    };
    0
};

// The words the reduction keeps: the four declarations, plus the splicer's own
// whole-line directives (`import`, `export`, `embed`), which are consumed by the
// resolve and never reach the lexer.
def mg_directive(w: str) -> bool {
    w == "def" || w == "type" || w == "let" || w == "const" ||
    w == "import" || w == "export" || w == "embed"
};

// The region is over. Drop it whole unless it is a declaration or holds a block:
// its G lines go back to where it began and the line being built is cut back to
// what it held then. No hoisted call can point into a dropped region -- a hoist
// belongs to a mid-token block, and a mid-token block makes its region one that
// holds a block.
def sg_region_close() -> long {
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

// `#{` at i in code position: check it, record the block, open it, and read the
// word after it (which may be an `import`). Returns where to carry on from, or
// n when the block is refused.
//
// "Immediately before" -- a space is enough to make it a separate token, and a
// separate token that starts an operand is not mid-token: `return #{ … }#`,
// `f(#{ … }#, 2)` and `a[#{ … }#]` all keep the call in place.
def sg_open(i: long, n: long) -> long {
    let prev = 0;
    if (i > 0) { prev = sg_src[i - 1]; };
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
        // What the block around this one (if any) does with it. A parent whose
        // text was already in the table is not compiled this round -- its text
        // went into ITS parent as text -- so nothing inside it runs, needs a
        // text, or is even looked at beyond keeping its slot stable. That is the
        // DEAD chain, and it is what stops a block from being asked for a piece
        // it can never produce.
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
        mg_p_at = 0 - 1;
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
        // A top-level block holds its text only when it MAY hold another block,
        // because then this round can find it cannot produce its text and put a
        // stand-in in its place (sg_top_close). The collecting scan, which knows
        // nothing yet, never holds -- so the G it builds for a program with no
        // nesting is the one the pass has always built, and a program with no
        // nesting never pays for any of this.
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
            // The call is hoisted, which is the SAME rule for both reasons it
            // happens -- and that they are the same rule is the point:
            //
            //   mid-token: the bytes here cannot hold a call.
            //   nested:    the block around this one is not this block's own
            //              source to compile. Its text goes there (sg_splice) or
            //              it does not compile there at all.
            //
            // So a nested block's call goes to a buffer of its own and
            // sg_mids_move puts it at the top-level statement that contains it,
            // which is the statement the enclosing block is in. The enclosing
            // block is stubbed this round (its sg_bok is false, since this block
            // had no text), and a stub drops the enclosing source whole -- so
            // the hole this block leaves in it goes with it, and the two stay
            // consistent. When the text IS known the splice happens instead and
            // no call is emitted, so a nested block's call never runs twice.
            sg_m_open(slot)
        } else if (hold) {
            // the prefix waits for the `}#`: only then is it known whether this
            // round has the text of every block inside (sg_top_close)
            sg_hold()
        } else {
            // An ordinary call where the block stood. A NESTED one lands inside
            // the enclosing block's own source, which is exactly how a nested
            // block's round works: the enclosing source compiles this round and
            // its output is a stand-in to be thrown away (sg_bok), because the
            // enclosing block cannot produce its real text until the nested one
            // has. The round after, the nested block splices.
            let helper = stmt ? "ycc_meta_stmt" : "ycc_meta_expr";
            sg_gadd(helper + "(" + tostring(slot) + ", tostring({", sg_mmid);
            sg_col += 2;
        };
        let k = sg_word(i + 2, n);
        sg_col += (k - (i + 2));
        k
    }
};

// A mid-token block, and any nested block that has not got its text yet: the
// call goes to a buffer of its own, and sg_mids_move puts it at the top-level
// statement that contains the block. The buffer of an enclosing block is saved
// and restored, so a nested one is hoisted out of it -- and since the moves are
// applied in close order, it runs first.
//
// The call is ALWAYS a statement (`ycc_meta_stmt`, with its `;`): a mid-token
// block is one that could not be an operand where it stands, and a nested block
// is one whose enclosing block cannot compile this round -- so neither is an
// expression by construction, whatever the text around it looks like.
def sg_m_open(slot: long) -> long {
    sg_hold();
    sg_mbuf += "ycc_meta_stmt(" + tostring(slot) + ", tostring({";
    sg_col += 2;
    0
};

// `}#` of a top-level block that HELD its text: the call goes where the block
// stood, wrapping either the block's own body or a stand-in for it.
//
// The stand-in is the whole of what a block that cannot produce its text this
// round contributes. Its shape is the real call's -- same helper, same position,
// same `;` -- with an empty body, so the statement around it still compiles and
// still type-checks the way it did when the block was a call. Its piece is the
// empty string and mg_take_pieces throws it away (mg_bok is false), so nothing
// downstream ever sees it.
//
// Which of the two it is cannot be decided at the `#{`, and is not: this is the
// first point where every block opened inside this one has closed and said
// whether its text was in the table. A block with nothing inside is never held
// and never comes through here, which is what keeps a program with no nesting on
// the path the pass has always taken.
def sg_top_close(k: long) -> long {
    let slot = sg_bslot[k];
    let stmt = sg_bstmt[k];
    if (sg_bok[k]) {
        let helper = stmt ? "ycc_meta_stmt" : "ycc_meta_expr";
        let post = stmt ? "}));" : "}))";
        sg_restore(helper + "(" + tostring(slot) + ", tostring({", post)
    } else {
        // the stand-in: the held text is what cannot be compiled, so it goes
        // nowhere at all. The line counter goes back with it (sg_drop), and the
        // call goes where the block stood -- into the live buffer, which still
        // holds only the text from BEFORE the block, so the call lands in the
        // right place and the text after the block follows it.
        sg_drop();
        sg_gbuf += mg_stub(slot, stmt);
        0
    }
};

// `}#` of a held block whose call is hoisted -- a mid-token one, or any nested
// one: close the call, record it with the statement to hoist it to, and give the
// enclosing block its buffer back. Recorded in CLOSE order, which is the order
// the calls have to run in.
def sg_m_close(k: long) -> long {
    // A block that is hoisted is not compiled where it stands, so nothing about
    // its source is checked until the round that has its text -- and if one of
    // the blocks inside it has no text this round, its own source cannot compile
    // either, and it runs the stand-in too (mg_stub). Its body then contributes
    // nothing, which is what keeps a hole out of the text around it: the
    // enclosing block is stubbed for the same reason.
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
def sg_m_live() -> long {
    sg_mmid = false;
    sg_mdepth = 0;
    let k = sg_depth - 1;
    while (k >= 0) {
        if (sg_bhold[k]) { sg_mmid = true; sg_mdepth = k + 1 };
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
    for i in 0..n { done += false; };
    let left = n;
    while (left > 0) {
        let at = 0 - 1;
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
            // A block STATEMENT ends at its own `}#` -- there is no `;` after it
            // to end the region -- so the reduction treats it as a statement that
            // has finished. Not a mid-token one (`def as#{nm}#()` is inside a
            // statement that goes on) and not a block in expression position
            // (`let x = #{ … }#;`): both end at the `;` like any other.
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
    sg_src[i] == 34 && i > 0 && sg_src[i - 1] == 102 &&
        (i == 1 || !m_word(sg_src[i - 2]))
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
    // mg_bkids is NOT reset here: it is structural, so every pass learns the same
    // thing from it (sg_open) -- which is what makes it usable at the `#{`, before
    // the children have been seen. Only the FIRST pass is the collecting one, and
    // only meta_begin says so.
    mg_bkids = [];
    mg_reduce = false;
    mg_pass();
    mg_collect = true;
    0
};

// The reduction, turned on once a pass has found nesting. The collecting pass
// never turns it on: it does not know yet, and a program with no nesting must
// compile to exactly what it always did.
def mg_reduce_on() -> long {
    mg_reduce = true;
    0
};

// A new PASS over the same files -- and the block table, G's body and the
// hoisted imports are all per-pass. A block's SLOT is its index in the block
// table, and the table is rebuilt from scratch each pass, so the second pass
// over the same files in the same order hands out the SAME slots: that is how
// a piece the generator wrote is matched to the block that asked for it. The
// pieces themselves survive -- they are what the second pass splices.
//
// So do the pieces a ROUND produced, and the round's own verdicts: mg_bok (was
// every block inside this one known when it closed), mg_live (did this block's
// call go into this round's G) and mg_nest. Everything a pass produces is about
// this round, and mg_reset_rounds is what separates the two lifetimes.
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
    mg_bok = [];
    mg_live = [];
    mg_need = [];
    mg_n = 0;
    mg_nest = 0;
    mg_collect = false;
    0
};

// Is any block still without its text? That is the loop condition of the rounds,
// and it is the same question as "did this round's generator leave a block out
// of G": a block whose source wanted the text of a nested block inside it cannot
// produce its own text until it has it, so it is stubbed, runs as an empty
// stand-in, and its piece is discarded (mg_take_pieces) -- leaving it here, and
// so asking for another round. False means every piece is in and the pass is
// done.
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
    xs.foreach((e) => {
        if (e == s) { hit = true; };
    });
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
//
// The body each one takes is ALREADY a str: the pass wraps every block's own
// text in `tostring(...)` when it writes the call (sg_open, sg_m_open). That is
// not a detail of the wrapper -- it is what makes the pass's own round work. A
// nested block's text goes into the source of the block AROUND it, where it
// usually stands where an expression stood, so a block whose value is a `long`
// is the ordinary case (`#{ let a = #{ 1 + 1 }#; a }#`), and a wrapper typed
// `str` would reject exactly the blocks nesting is for.
//
// `ycc_meta_expr` and `ycc_meta_stmt` are the two shapes a block's call can take
// where the block stood: a value and a void statement. Both are load bearing --
// a top-level block in expression position needs the str the first returns and a
// statement-position one needs the `;` the second has -- and a nested block's
// call is always `ycc_meta_stmt`, because it is always hoisted out of the block
// around it (sg_open). `ycc_meta_emit` is what they share: the framing and the
// one write.
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
    hs.foreach((e) => {
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

def mg_unframe(data: str) -> long {
    let n = len(data);
    let i = 0;
    let bad = false;
    while (i < n && !bad) {
        let j = i;
        let go = true;
        while (go && j < n && data[j] != 10) { j = j + 1; };
        if (j >= n) {
            bad = true;
        } else {
            let head = data[i:j];
            let sp = index_of(head, " ");
            if (sp < 0) {
                bad = true;
            } else {
                // The header is "<slot> <take>", both decimal -- but this used
                // to lean on tolong stopping at the first non-digit, and the
                // text handed to it is not always exactly two numbers. tolong
                // requires a fully valid input now, so the digit prefix is
                // taken HERE, where the intent is visible, instead of being a
                // side effect of a lenient parser. leading_long reproduces the
                // old read exactly: the digits, or 0 when there are none.
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
    for i in 0..mg_next {
        if (!mg_have[i]) { at = i; };
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
    // A block that could not produce its text this round ran something whose
    // output is not its text -- a stand-in with an empty body, or (for a nested
    // block on the collecting round) a call whose value is the inner text as a
    // string. Throw those away first, so what is left in the table is this
    // block's real text and nothing downstream can mistake the rest for it.
    // mg_pending is what asks for the next round.
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

// Keep only the pieces that are really this block's text. A block that could not
// produce its text this round ran a stand-in (sg_top_close) whose piece is the
// empty string; it has to keep waiting (mg_pending), and so does everything
// around it.
//
// The rest is already true of the table mg_unframe writes: a piece is marked
// present only when it is framed, so a slot holding its piece from an earlier
// round is not disturbed by a round that stubbed the block.
def mg_commit() -> long {
    for i in 0..mg_next {
        if (i < len(mg_have) && mg_have[i] && !mg_bok[i]) {
            mg_have[i] = false;
            mg_piece[i] = "";
        };
    };
    0
};

// The stand-in a block runs when it cannot produce its text this round. Same
// helper and same position as the real call, with the body `0`: the statement
// around it still compiles and still type-checks exactly as it did. Its piece is
// "0", and mg_commit throws that away with everything else.
def mg_stub(slot: long, stmt: bool) -> str {
    let helper = stmt ? "ycc_meta_stmt" : "ycc_meta_expr";
    let s = helper + "(" + tostring(slot) + ", tostring({ 0 }))";
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
    parts.foreach((e) => {
        let seg = e;
        if (seg != ".") { out += seg; };
    });
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
    for i in 0..n {
        if (text[i] == 10) {
            out += text[start:i];
            start = i + 1;
        };
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
    segs.foreach((el, s) => {
        let text = el;
        let o = sego[s];
        let p = false;
        if (s < len(segp)) { p = segp[s] };
        let parts = mg_lines(text);
        parts.foreach((e, k) => {
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
def mg_splice(lo: long, hi: long) -> long {
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
         meta_begin, mg_pass, mg_pending, mg_reduce_on, mg_nest,
         mg_set, mg_setup, mg_on, mg_check, mg_report,
         mg_probe, mg_take_pieces, meta_scan, Scan, scan_none,
         meta_gtext, mg_ghead, mg_glines, mg_gol, mg_gbase, mg_gexec, mg_pkgs, mg_roots,
         mg_root, MG_NEST, MG_ROUND };