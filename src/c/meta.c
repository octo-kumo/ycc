/* meta.c — compile-time code generation: the `#{ … }#` block, and the
 * image runner it needs.
 * 1:1 copy of src/y/meta.y (see PORTING.md): every def is one function,
 * same names, same parameter order, same control flow.
 *
 * Two things live here, in this order because the second sits on the first:
 *   1. run_image — run a compiled image in a FORKED child, at a scratch
 *      address, with its own fabricated stack. See "M1" in meta.y.
 *   2. the pass — scan a file for blocks, build the generator program G and
 *      the program P, run G, splice the pieces into P. See "M2" in meta.y.
 *
 * ── M1: why a child, and how ────────────────────────────────────────────
 * The generator (G) is an ordinary Y program, compiled for the host and run.
 * It must NOT run in ycc's own address space: src/y/arch/prelude.s has five
 * exit_group trap stubs, so a generator that divides by zero would write to
 * *ycc's* stdout and take ycc's exit status with it; exit(0) would make ycc
 * exit 0 having emitted nothing; and a guest spawn would repoint the
 * compiler's own %fs:24. A child dissolves all three: its memory is
 * copy-on-write, so a trap, an exit, an exec or a spawn there dies with it,
 * and waitpid turns its death into a diagnostic naming the block.
 *
 * The transfer into the child is a raw clone syscall (Linux x86-64, syscall
 * 56) with the new stack pointer as its second argument and SIGCHLD as the
 * exit signal — that is, fork with a chosen stack:
 *
 *     syscall(56, SIGCHLD, stack_top, 0, 0, 0)
 *
 * Without CLONE_VM the child gets a copy-on-write copy of the whole address
 * space (so it is a fork), and its %rsp becomes stack_top. MEASURED, and
 * the measurement matters: the kernel does NOT read an entry point out of
 * that stack. The child comes back from the syscall with %rax = 0, %rsp =
 * stack_top, and RIP at the instruction after the syscall — still running
 * THIS code, on the new stack. So the transfer is one jmp_at later, and
 * because jmp_at is `jmp *%rax` (ir.h F_JMP_IND) rather than `call`, %rsp is
 * still stack_top, which is where the fabricated
 *
 *     [stack_top]      = argc
 *     [stack_top + 8]  = argv[0] ... argv[argc-1], then NULL
 *
 * sits — exactly the [argc][argv…][NULL] a process entry point expects, and
 * nothing has to push a return address over the argc.
 *
 * The image is relocatable because label_addr (asm.c) returns segment
 * OFFSETS and every fixup is a difference of offsets, so no code byte holds an
 * absolute address: mapping it anywhere keeps every rip-relative reference
 * correct, as long as the layout *relative* to the mapping base is preserved.
 *
 * The image bytes cannot be copied in by ycc: Y has no pointer arithmetic that
 * turns a long into a writable *T. So they go through a memfd: write from
 * the compiler's own byte array, ftruncate to the whole span, then one mmap
 * of that file covering code+rodata AND .bss, mprotected R|X over the code
 * alone. One extra copy through the page cache, no temp file, no kernel exec
 * — and, unlike two separate mappings, no MAP_FIXED, which this kernel
 * refuses (EINVAL) at a fresh address immediately above an existing mapping,
 * which is exactly where the .bss wants to be.
 *
 * The guest writes each piece to fd 3 as it produces it (the parent dup2s the
 * pipe's write end there for the duration of the run), so there is no .bss
 * accumulator, no slot array in the image and no return value to read: the
 * pipe, the child's exit status and its byte count are the whole protocol.
 *
 * ── M2: the pass ────────────────────────────────────────────────────────
 * Read ideas/meta.md. This is the second half of it, and the shape is:
 *
 *     G = T with every block replaced by a call
 *     P = T with every block replaced by that call's text
 *
 * G is compiled for the host with THE PASS OFF and run in a forked child
 * (run_image, above); its output is the piece table; the pass splices the
 * pieces into P; P is handed to the existing lexer unchanged. There is exactly
 * one layer, so `#{ … }#` is the whole surface.
 *
 * Only the lexer: lit_end is the literal scanner, and the pass must not import
 * native.c (native.c imports this one -- see the driver note).
 *
 * ── two divergences from the Y twin, and one is the value model's ───────
 * A `[byte]` array is PACKED in the Y native runtime (one byte per element),
 * so meta.y can hand `&b[0]` straight to write(2) and read(2). yv.h stores a
 * `[byte]` array as an array of Yv longs (8 bytes per byte), so the image is
 * packed into a chunk buffer before it reaches the kernel and the pipe's bytes
 * are unpacked into Yv longs after. The bytes on the wire, the bytes in the
 * file and every diagnostic are unchanged; only the in-memory representation
 * differs, and only inside this module. (So `fab_stack`'s `stk: [byte; N]` is a
 * C array here and put64 is a direct 8-byte store.)
 *
 * `jmp_at` is a Y builtin (types.c types it, native.c emits it as F_JMP_IND);
 * this module needs it as a jump through a register of its own, which gcc
 * spells `jmp *%reg` — the same instruction the Y twin emits.
 */
#include "ylong.h"
#include <string.h>
#include "host.h"
#include <unistd.h>
#include "lexer.h"
#include "meta.h"
#include "yv.h"

/* Whether the pass runs at all. Off while G is compiled, on for the program. */
int mg_on = 0;
/* The next slot index. Slots are global and in RESOLVE order (the program's
 * own file first, then its modules as the splicer visits them), which is the
 * order the generator runs them in. */
ylong mg_next = 0;
/* G's body: the files' lines with each block as a call, and the source line
 * each of those lines came from. */
static Yv *mg_g = 0;
/* Each block: its slot, the file and line of its `#{`, and -- for a block at
 * file scope, whose text P really does drop -- the line of P and the byte
 * offset in that line the piece goes at. A nested block's text lives inside
 * its parent's call, so it has no P position. */
static Yv *mg_bslot = 0;
static Yv *mg_bfile = 0;
static Yv *mg_bline = 0;
static Yv *mg_bp = 0;
static Yv *mg_bpo = 0;
/* The imports hoisted out of blocks, and the line each is reported at. */
static Yv *mg_imp = 0;
static Yv *mg_iol = 0;
/* One piece per slot, and whether it arrived. The pieces come back over the pipe
 * framed as `<slot> <len>\n<body>`, so a piece is matched to its block by SLOT
 * and not by the order the generator happened to evaluate blocks in. That
 * matters: a nested block's text is produced BEFORE its parent's, so source order
 * and execution order differ.
 *
 * They are here rather than with the driver because the SCANNER reads them: a
 * nested block whose piece has arrived contributes that text to the source of the
 * block around it instead of a call (sg_open), which is the whole of nesting.
 * And they SURVIVE mg_pass, which is what makes the rounds work -- the piece
 * table is the one thing that carries from a round to the next, and a block's
 * slot is the same in every round because the block table is built the same way
 * every round. */
static Yv *mg_piece = 0;
static Yv *mg_have = 0;
/* How many blocks the whole resolve found, and whether any. */
ylong mg_n = 0;
/* How many of them sit inside another block. A program with none is the common
 * case and costs exactly one compile of the generator, whatever else changes
 * here (native.c meta_prepare: mg_nest is what decides whether the rounds run at
 * all). */
ylong mg_nest = 0;
/* Did each block's CHILDREN all have their text when it opened? A block whose
 * own source wanted a nested block's text cannot produce its text until it has
 * it, so the answer says whether the piece this round produced is the real one
 * (mg_commit keeps it) or a stand-in to throw away. */
static Yv *mg_bok = 0;
/* Did each block's call go into this round's G? A block that did not is one
 * whose text was already in the table and was spliced into the block around it,
 * or one inside such text, so it neither runs nor owes the table anything. */
static Yv *mg_live = 0;
/* Does each block's text have to exist at all? Always for a top-level one -- it
 * goes into the program. For a nested one, only while the block around it is
 * being compiled: inside text that was spliced whole, the text is already there. */
static Yv *mg_need = 0;
/* Whether each block has ever had a block open inside it. It is structural --
 * the same every round, and the block table is built the same way every round --
 * so it is never cleared, and it is what a round knows about a block's children
 * BEFORE it has scanned them: a block that may hold a nested block holds its
 * text (sg_hold), because a nested block's text goes into the enclosing block's
 * source and has to be known before that source is compiled. */
static Yv *mg_bkids = 0;
/* The emitted-text size cap (R8 is not negotiable). The piece table is read
 * into memory, so this is what bounds it. */
#define MG_MAX 33554432L
/* The pass's own nesting cap. It is a COST bound and not a parser bound: a level
 * of nesting costs one more compile and one more run of the generator, because
 * a nested block's text has to be known before the source of the block around it
 * can be compiled (mg_pending). The parser's own limit is ~333 effective (tags.h
 * MAX_NEST is 1000 and each nested block costs ~3 nest units), so 8 is far below
 * both, and MEASURED per level: see ideas/meta.md, "Nesting". */
#define MG_NEST 8L
/* How many rounds native.c meta_resolve will do before it calls the round logic
 * broken. One round per level of nesting plus one for a program that has none,
 * so a program the scanner accepted cannot reach it. */
#define MG_ROUND (MG_NEST + 2)
/* The reduction: on for a program that HAS nesting (mg_reduce), and off
 * otherwise. A round in which a block could not produce its text leaves a stub
 * where its call goes (sg_top_close), so a statement reading a name that block
 * was going to define would not compile -- and the statements in question bind
 * nothing, so dropping them costs the generator no name at all
 * (sg_region_close). */
static int mg_reduce = 0;
/* The collecting scan: the one that finds the blocks, before anything is known.
 * It never holds a block's text and never reduces, so the G it builds for a
 * program with no nesting is the G the pass has always built. */
static int mg_collect = 1;

Yv *mg_gol = 0;
Yv *mg_gbase = 0;
int mg_gexec = 1;
Yv *mg_pkgs = 0;
Yv *mg_roots = 0;
Yv *mg_root = 0;
static Yv *mg_files = 0;
static int mg_ready = 0;
static ylong mg_first = 0;
static ylong mg_p_at = -1;

/* `dst += src` for a Y array: the elements of src appended to dst. Arrays are
 * reference values here (rule 1), so this is ya_push per element -- which is
 * what the Y `+=` on an array already is, and what makes the `a[i:j]` slices
 * elsewhere copy (rule 4). */
static Yv *yadd(Yv *dst, Yv *src) {
    ylong i = 0;
    while (i < yv_len(src)) { dst = ya_push(dst, ya_get(src, i)); i = i + 1; };
    return dst;
}

/* `a + b` for two string values, spelled the way it reads. */
static Yv *scat3(Yv *a, Yv *b, Yv *c) {
    return ys_cat(ys_cat(a, b), c);
}

/* One file's scan: P's lines with their origins, G's lines for this file, and
 * the imports hoisted out of its blocks.
 * gen[i] says line i of p is wholly GENERATED (a block's piece), not the
 * user's own text. It is what tells lint which top-level statements the pass
 * put there, so "a top-level statement runs twice" does not fire on them.
 * Type Scan = { ok, err, eline, ecol, p, pf, pol, gen, g, gf, gol }. */

static Yv *scan_bad(Yv *err, ylong line, ylong col) {
    return yr(11, "ok", yv_bool(0), "err", err, "eline", yv_long(line),
              "ecol", yv_long(col), "p", yav(0), "pf", yav(0), "pol", yav(0),
              "gen", yav(0), "g", yav(0), "gf", yav(0), "gol", yav(0));
}

/* A file with no blocks: P is the file's own lines, G the same, and nothing
 * else changes. The common case costs one index_of per line.
 *
 * split() drops ONE trailing empty element, so a source ending in "\n" loses
 * that newline on the way back out -- which is what the splicer has always
 * done with a file's lines, and what its origins are sized for. The scanner
 * below breaks on every newline INCLUDING the last, so its line count is one
 * more and its output rejoins to the source; scan_none does not, and must not,
 * or the two paths would disagree on a file with no blocks in it. */
Yv *scan_none(Yv *src, ylong fid) {
    Yv *lines = ys_split(src, ys("\n"));
    Yv *f = yav(0);
    Yv *l = yav(0);
    ylong i = 0;
    Yv *gn = yav(0);
    while (i < yv_len(lines)) {
        f = ya_push(f, yv_long(fid));
        l = ya_push(l, yv_long(i + 1));
        gn = ya_push(gn, yv_bool(0));
        i = i + 1;
    };
    return yr(11, "ok", yv_bool(1), "err", ys(""), "eline", yv_long(0),
              "ecol", yv_long(0), "p", lines, "pf", f, "pol", l, "gen", gn,
              "g", lines, "gf", f, "gol", l);
}

/* ── byte classes (the lexer's own predicates, spelled here because they are
 * not exported, and they must agree with lexer.c's wordbyte/isspace) ────── */

static int m_word(ylong c) {
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9');
}

static int m_blank(ylong c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

/* The word at src[i], i known to be a word byte. */
static Yv *m_word_at(Yv *src, ylong i, ylong n) {
    ylong j = i + 1;
    while (j < n && m_word(ys_byte_at(src, j))) { j = j + 1; };
    return ys_slice(src, i, j);
}

/* Whether every byte of s is a blank. */
static int m_all_blank(Yv *s) {
    int ok = 1;
    ylong i = 0;
    while (ok && i < yv_len(s)) {
        if (!m_blank(ys_byte_at(s, i))) { ok = 0; };
        i = i + 1;
    };
    return ok;
}

/* The byte before src[i] (i > 0), or 0. (Unused by the pass, kept because
 * meta.y has it: a Y module-level def the checker never calls is not a
 * warning, a C `static` one is.) */
ylong m_prev(Yv *src, ylong i) {
    return i <= 0 ? 0 : ys_byte_at(src, i - 1);
}

/* Whether the byte before a `#{` ends a token -- a name, a number, a literal
 * or a closing bracket. Then the block has no operand position at its own byte
 * offset, and it is a MID-TOKEN block: the call cannot go there
 * (`def helper<call>()` is not a def), so its bytes are dropped from G and its
 * call is hoisted (see sg_open and sg_mids_move).
 *
 * "Immediately before" -- a space is enough to make it a separate token, and a
 * separate token that starts an operand is not mid-token: `return #{ … }#`,
 * `f(#{ … }#, 2)` and `a[#{ … }#]` all keep the call in place. */
static int m_token_end(ylong c) {
    if (c == 0) { return 0; }
    else if (c == ')' || c == ']' || c == '}' || c == '.' || c == '\'' || c == '"') { return 1; }
    else { return m_word(c); }
}

/* ── little-endian reads and writes ────────────────────────────────────── */

/* One byte of a [byte] value: asm.c's `bytes` is an array of longs, so a read
 * goes through ya_get where the Y twin reads b[at] directly. */
static ylong mbyte(const Yv *b, ylong at) {
    return yv_l(ya_get(b, at));
}

static ylong rd16(const Yv *b, ylong at) {
    return mbyte(b, at) + mbyte(b, at + 1) * 256;
}

static ylong rd32(const Yv *b, ylong at) {
    return mbyte(b, at) + mbyte(b, at + 1) * 256 +
           mbyte(b, at + 2) * 65536 + mbyte(b, at + 3) * 16777216;
}

static ylong rd64(const Yv *b, ylong at) {
    ylong lo = rd32(b, at);
    ylong hi = rd32(b, at + 4);
    return lo + hi * 4294967296L;
}

/* …and the same read over raw bytes, for the two places that hold a C array
 * rather than a [byte] value: pipe(2)'s fd pair and the wait status. */
static ylong crd32(const unsigned char *b, ylong at) {
    return b[at] + b[at + 1] * 256 + b[at + 2] * 65536 + b[at + 3] * 16777216;
}

/* One byte written into a byte array. (Kept for the same reason as m_prev.) */
ylong putb(Yv *buf, ylong at, ylong v) {
    ya_set(buf, at, yv_long(v));
    return 0;
}

/* ── the image's own header, read back ───────────────────────────────────
 * A compiled image is one flat ELF64 file (elf.c): [EHDR 64][PHDR 56 or 112]
 * [code][rodata][8 zeros], base vaddr 0x400000, and with a .bss a second
 * PT_LOAD (read+write, nothing from the file) on the page after the image's
 * last page. Everything the runner needs is in those two PHDRs, so the
 * segments are read back out of the bytes elf_build just wrote rather than
 * threading a new signature through asm.c.
 * Type Img = { ok, err, filesz, memsz, entry, bss_delta, bss_len }. */

static Yv *img_bad(Yv *e) {
    return yr(7, "ok", yv_bool(0), "err", e, "filesz", yv_long(0),
              "memsz", yv_long(0), "entry", yv_long(0), "bss_delta",
              yv_long(0), "bss_len", yv_long(0));
}

static Yv *img_ok(ylong bss_delta, ylong bss_len, ylong entry, ylong filesz,
                  ylong memsz) {
    return yr(7, "ok", yv_bool(1), "err", ys(""), "filesz", yv_long(filesz),
              "memsz", yv_long(memsz), "entry", yv_long(entry), "bss_delta",
              yv_long(bss_delta), "bss_len", yv_long(bss_len));
}

static Yv *elf_img_bss(Yv *b, ylong n, ylong phoff, ylong phentsize, ylong phnum,
                       ylong base, ylong eoff, ylong filesz, ylong memsz) {
    (void)n;  /* the twin keeps it for symmetry; the range check is the caller's */
    ylong k = 1;
    int found = 0;
    ylong vaddr = 0;
    ylong msize = 0;
    while (k < phnum && !found) {
        ylong ph = phoff + k * phentsize;
        if (rd32(b, ph + 4) == 6) {
            found = 1;
            vaddr = rd64(b, ph + 16);
            msize = rd64(b, ph + 40);
        };
        k = k + 1;
    };
    if (!found) {
        return img_ok(0, 0, eoff, filesz, memsz);
    } else if (msize > 0 && vaddr >= base) {
        return img_ok(vaddr - base, msize, eoff, filesz, memsz);
    } else {
        return img_bad(ys("the image's .bss segment is out of range"));
    }
}

static Yv *elf_img_ph(Yv *b, ylong n) {
    ylong entry = rd64(b, 24);
    ylong phoff = rd64(b, 32);
    ylong phentsize = rd16(b, 54);
    ylong phnum = rd16(b, 56);
    if (phentsize < 56 || phoff + phentsize * phnum > n || phnum < 1) {
        return img_bad(ys("the image's program headers are out of range"));
    } else {
        ylong base = rd64(b, phoff + 16);
        ylong filesz = rd64(b, phoff + 32);
        ylong memsz = rd64(b, phoff + 40);
        ylong eoff = entry - base;
        if (filesz > n || memsz < filesz || eoff < 0 || eoff >= filesz) {
            return img_bad(ys("the image's entry point is outside its own code"));
        } else if (phnum < 2) {
            return img_ok(0, 0, eoff, filesz, memsz);
        } else {
            return elf_img_bss(b, n, phoff, phentsize, phnum, base, eoff,
                               filesz, memsz);
        }
    }
}

Yv *elf_img(Yv *b) {
    ylong n = yv_len(b);
    if (n < 120) {
        return img_bad(ys("the image is too small to be an ELF file"));
    } else if (mbyte(b, 0) != 127 || mbyte(b, 1) != 69 || mbyte(b, 2) != 76 ||
               mbyte(b, 3) != 70) {
        return img_bad(ys("the image is not an ELF file"));
    } else if (mbyte(b, 4) != 2 || mbyte(b, 5) != 1) {
        return img_bad(ys("the image is not a little-endian ELF64 file"));
    } else {
        return elf_img_ph(b, n);
    }
}

/* ── the child's stack ───────────────────────────────────────────────────
 * The child's stack: [argc][argv...][NULL] from the top down, and the word
 * below them is left alone — the kernel does not read it, jmp_at does not
 * touch %rsp, and the child never returns to the code that laid it out.
 * Returns the address to hand clone as its stack: the child starts with
 * %rsp = S, so it reads argc at [S] and argv[0] at [S+8]. */
#define MG_STACK 131072

static ylong fab_stack(char *stk, Yv *av) {
    char *base = stk;
    char *p = base + MG_STACK;
    ylong m = yv_len(av);
    Yv *ptrs = yav(0);
    ylong k = 0;
    while (k < m) {
        Yv *s = ya_get(av, k);
        ylong n = yv_len(s);
        p = p - n - 1;
        ylong at = p - base;
        ylong j = 0;
        while (j < n) { stk[at + j] = (char)(unsigned char)ys_byte_at(s, j); j = j + 1; };
        stk[at + n] = 0;
        ptrs = ya_push(ptrs, yv_long((ylong)p));
        k = k + 1;
    };
    p = p - 8 * (m + 1);
    p = p - ((ylong)p % 8);
    k = 0;
    while (k < m) {
        ylong v = yv_l(ya_get(ptrs, k));
        memcpy(p + 8 * k, &v, 8);
        k = k + 1;
    };
    memset(p + 8 * m, 0, 8);
    p = p - 8;
    memcpy(p, &m, 8);
    return (ylong)p;
}

/* ── run_image ───────────────────────────────────────────────────────────
 * What run_image reports: `ok` false means ycc could not even start the child
 * (`err` says why); `ok` true means the child ran, and `status`/`sig` are its
 * fate -- status 0 with sig 0 is a clean exit, a non-zero `sig` a death by
 * signal. `out` is what the child wrote to fd 3, and is empty unless
 * `want_out`.
 * Type RunRes = { ok, status, sig, out, err }.
 * Type Mapd = { img, memsz, entry, span, rfd, keep } -- everything the child
 * needs mapped, so it can be undone in one place. */

/* The page sizes and syscall numbers the runner needs. native.c's arch_sysno
 * table has only the handful generated code uses, so the rest are spelled out
 * here, next to their one use. (Named MG_* so a system header's SIGCHLD and
 * F_DUPFD cannot shadow them.) */
#define MG_PROT_RX 5L      /* PROT_READ|PROT_EXEC */
#define MG_PROT_RW 3L      /* PROT_READ|PROT_WRITE */
#define MG_MAP_PRIVATE 2L
#define MG_SYS_READ 0L
#define MG_SYS_WRITE 1L
#define MG_SYS_CLOSE 3L
#define MG_SYS_MMAP 9L
#define MG_SYS_MPROTECT 10L
#define MG_SYS_MUNMAP 11L
#define MG_SYS_PIPE 22L
#define MG_SYS_DUP 32L
#define MG_SYS_DUP2 33L
#define MG_SYS_FCNTL 72L
#define MG_F_DUPFD 0L
#define MG_SYS_MEMFD 319L
#define MG_SYS_FTRUNCATE 77L
#define MG_SYS_CLONE 56L
#define MG_SYS_WAIT4 61L
#define MG_SIGCHLD 17L
#define GUEST_FD 3L        /* where a generator's pieces are written */

/* `jmp_at(addr)`: a jump through a register, leaving %rsp alone (a `call`
 * would push a return address where a process entry point reads its argc).
 * The Y twin gets this from the `jmp_at` builtin, emitted as ir.h F_JMP_IND;
 * here it is one line of asm, the same instruction.
 *
 * It is spelled INLINE in run_image_fork rather than in a function of its own,
 * for the same reason the clone syscall is: %rsp must still be `sp` -- the
 * fabricated argv starts there and the image's entry reads argc from it -- and
 * a `call` (which is what a helper is, at -O0) pushes a return address and
 * drops %rsp by eight. That alone made every program using argv() read a
 * garbage argc. */
#define mg_jmp_at(addr) __asm__ volatile ("jmp *%0" : : "r"(addr) : "memory")

static ylong page_up(ylong n) {
    return (n + 4095) / 4096 * 4096;
}

static Yv *run_fail(Yv *e) {
    return yr(5, "ok", yv_bool(0), "status", yv_long(-1), "sig", yv_long(0),
              "out", yav(0), "err", e);
}

static ylong map_release(Yv *m);

/* Put fd 3 back and unmap everything the run needed. ycc never frees, so this
 * is not about the heap: the mappings are outside it, and R8 counts them. */
static ylong map_release(Yv *m) {
    ylong keep = yv_l(yr_get(m, "keep"));
    ylong rfd = yv_l(yr_get(m, "rfd"));
    ylong img = yv_l(yr_get(m, "img"));
    ylong span = yv_l(yr_get(m, "span"));
    if (keep >= 0) {
        (void)syscall(MG_SYS_DUP2, keep, GUEST_FD, 0L);
        (void)syscall(MG_SYS_CLOSE, keep, 0L);
    } else if (rfd >= 0) {
        (void)syscall(MG_SYS_CLOSE, GUEST_FD, 0L);
    };
    if (rfd >= 0) { (void)syscall(MG_SYS_CLOSE, rfd, 0L); };
    if (img > 0) { (void)syscall(MG_SYS_MUNMAP, (void *)img, span, 0L); };
    return 0;
}

/* Drain the pipe BEFORE the wait: a child writing more than a pipe buffer
 * would block forever with nobody reading. */
static Yv *run_image_read(Yv *m, ylong pid) {
    Yv *out = yav(0);
    ylong rfd = yv_l(yr_get(m, "rfd"));
    if (rfd >= 0) {
        unsigned char buf[65536];
        int more = 1;
        while (more) {
            ylong k = (ylong)syscall(MG_SYS_READ, rfd, buf, 65536L);
            if (k <= 0) {
                more = 0;
            } else {
                ylong i = 0;
                while (i < k) { out = ya_push(out, yv_long(buf[i])); i = i + 1; };
            };
        };
    };
    unsigned char ws[8];
    (void)syscall(MG_SYS_WAIT4, pid, ws, 0L, 0L);
    ylong st = crd32(ws, 0);
    ylong low = st % 128;
    ylong status = 0;
    ylong sig = 0;
    if (low == 0) { status = (st / 256) % 256; }
    else if (low != 127) { sig = low; };
    (void)map_release(m);
    return yr(5, "ok", yv_bool(1), "status", yv_long(status), "sig",
              yv_long(sig), "out", out, "err", ys(""));
}

/* SIGCHLD, no CLONE_VM: a separate process with a copy-on-write copy of our
 * address space, reaped by wait4 -- the fork the whole design rests on. The
 * child comes back from the syscall with %rax = 0 and %rsp = `sp`, still
 * running THIS code, one instruction later; jmp_at then hands it to the
 * image with %rsp exactly where fab_stack put it. */
static Yv *run_image_fork(ylong sp, Yv *m, ylong wfd) {
    /* The clone(2) itself, in RAW asm and INLINE HERE -- not in a helper
     * function, and not through libc's syscall(). Both matter, and for the
     * same reason: the kernel sets the child's %rsp to the stack pointer we
     * hand it, so anything that returns through a stack frame after the
     * syscall -- a `call`, hence a `ret`, hence libc's syscall() as much as
     * our own helper -- pops a return address off the NEW stack and jumps to
     * whatever is there. A bare `syscall` instruction (what the Y twin's
     * `syscall` builtin compiles to) has no frame to unwind: the child simply
     * carries on at the next instruction, with %rsp = stack_top and %rax = 0.
     *
     * Registers are the kernel's: %rax the number, then %rdi %rsi %rdx %r10
     * %r8 %r9; %rcx and %r11 are clobbered. */
    ylong pid;
    __asm__ volatile ("syscall"
                      : "=a"(pid)
                      : "a"(MG_SYS_CLONE), "D"(MG_SIGCHLD), "S"(sp), "d"(0L),
                        "r"(0L), "r"(0L), "r"(0L)
                      : "rcx", "r11", "memory");
    if (pid <= 0) {
        mg_jmp_at(yv_l(yr_get(m, "img")) + yv_l(yr_get(m, "entry")));
        (void)map_release(m);
        return run_fail(ys("the image's entry point returned"));
    } else {
        /* The parent must not hold the write end: it is the only reader, and
         * the read below waits for end-of-file, which a pipe gives when EVERY
         * writer has closed. map_release puts the compiler's own fd 3 back. */
        if (wfd >= 0) { (void)syscall(MG_SYS_CLOSE, GUEST_FD, 0L); };
        return run_image_read(m, pid);
    }
}

static Yv *run_image_clone(Yv *av, Yv *m, ylong wfd) {
    static char stk[MG_STACK];
    ylong sp = fab_stack(stk, av);
    Yv *m2 = yr(6, "img", yr_get(m, "img"), "memsz", yr_get(m, "memsz"),
                "entry", yr_get(m, "entry"), "span", yr_get(m, "span"),
                "rfd", yr_get(m, "rfd"), "keep", yr_get(m, "keep"));
    if (wfd >= 0) {
        /* fd 3 is the child's way back: the injected helpers write pieces
         * there. fd 3 is saved and put back afterwards, so the compiler's own
         * fd 3 (if it had one) survives the run. */
        yr_set(m2, "keep", yv_long((ylong)syscall(MG_SYS_DUP, GUEST_FD, 0L)));
        (void)syscall(MG_SYS_DUP2, wfd, GUEST_FD, 0L);
        (void)syscall(MG_SYS_CLOSE, wfd, 0L);
    };
    return run_image_fork(sp, m2, wfd);
}

/* The image into a fresh memfd, sized to the whole span the child will need:
 * the ELF's own bytes, then the .bss at its own offset (elf_bss_from_ro puts
 * it a page past the image's last page, and that gap page is simply part of
 * the file's zeros). */
static ylong image_fd_write(Yv *b, ylong fd, ylong span) {
    ylong n = yv_len(b);
    ylong off = 0;
    unsigned char buf[65536];
    while (off < n) {
        /* the packed copy the Y twin gets from &b[0] (see the header note) */
        ylong take = n - off;
        ylong i = 0;
        if (take > 65536) { take = 65536; };
        while (i < take) { buf[i] = (unsigned char)(mbyte(b, off + i) & 0xFF); i = i + 1; };
        ylong k = (ylong)syscall(MG_SYS_WRITE, fd, buf, take);
        if (k <= 0) {
            (void)syscall(MG_SYS_CLOSE, fd, 0L);
            fd = -1;
            off = n;
        } else {
            off = off + k;
        };
    };
    /* Sized after the write: a memfd starts empty, and mmap past the end of a
     * file gives SIGBUS rather than zeros, so the .bss needs the file to be
     * as long as the span. */
    if (fd >= 0) {
        if ((ylong)syscall(MG_SYS_FTRUNCATE, fd, span, 0L, 0L, 0L) != 0) {
            (void)syscall(MG_SYS_CLOSE, fd, 0L);
            fd = -1;
        };
    };
    return fd;
}

static ylong image_fd(Yv *b, ylong span) {
    ylong fd = (ylong)syscall(MG_SYS_MEMFD, "ycc-image", 0L);
    if (fd < 3) {
        return -1;
    } else {
        return image_fd_write(b, fd, span);
    }
}

static Yv *run_image_fd(Yv *b, Yv *av, Yv *im, Yv *m0, ylong wfd) {
    ylong span = yv_l(yr_get(m0, "span"));
    ylong memsz = yv_l(yr_get(im, "memsz"));
    ylong fd = image_fd(b, span);
    if (fd < 0) {
        return run_fail(ys("cannot make an anonymous file for the image"));
    } else {
        /* Writable to start with, so the .bss (which the file zeroes) is
         * usable; the code part is then narrowed to R|X. */
        ylong img = (ylong)syscall(MG_SYS_MMAP, 0L, span, MG_PROT_RW,
                                 MG_MAP_PRIVATE, fd, 0L);
        (void)syscall(MG_SYS_CLOSE, fd, 0L);
        if (img < 0) {
            return run_fail(scat3(ys("cannot map the image ("),
                                  ys_tostring(yv_long(img)), ys(")")));
        } else if ((ylong)syscall(MG_SYS_MPROTECT, (void *)img, memsz,
                                 MG_PROT_RX, 0L, 0L) != 0) {
            (void)syscall(MG_SYS_MUNMAP, (void *)img, span, 0L);
            return run_fail(ys("cannot make the image's code read+execute"));
        } else {
            Yv *m = yr(6, "img", yv_long(img), "memsz", yv_long(memsz),
                       "entry", yr_get(im, "entry"), "span", yv_long(span),
                       "rfd", yr_get(m0, "rfd"), "keep", yr_get(m0, "keep"));
            return run_image_clone(av, m, wfd);
        }
    }
}

/* The bytes the child needs addressable: the ELF's own image, plus the .bss at
 * the offset past it the ELF header says. The mapping covers the whole span in
 * one go, so nothing needs MAP_FIXED. */
static ylong img_span(Yv *im) {
    if (yv_l(yr_get(im, "bss_len")) == 0) {
        return page_up(yv_l(yr_get(im, "memsz")));
    } else {
        return page_up(yv_l(yr_get(im, "bss_delta")) +
                       yv_l(yr_get(im, "bss_len")));
    }
}

/* pipe(): the two fds land as two 32-bit ints, so the buffer is 8 bytes and
 * not two longs -- a long would read the pair as one word.
 *
 * BOTH ends are moved above GUEST_FD first. A pipe lands on the lowest free fd,
 * and with nothing open that is 3 -- the fd the generator writes its pieces
 * to -- so the child's dup2 would land the write end on the read end and the
 * parent would read from a write-only fd (EBADF, measured). F_DUPFD with a
 * minimum of 4 does it without closing 3 first, which dup(2) could not: it
 * hands out the lowest free number again. */
static Yv *pipe_fds(void) {
    unsigned char pf[8];
    if ((ylong)syscall(MG_SYS_PIPE, pf, pf + 4, 0L, 0L) != 0) {
        return yr(3, "ok", yv_bool(0), "rfd", yv_long(-1), "wfd", yv_long(-1));
    } else {
        ylong r = crd32(pf, 0);
        ylong w = crd32(pf, 4);
        ylong r2 = (ylong)syscall(MG_SYS_FCNTL, r, MG_F_DUPFD, GUEST_FD + 1, 0L);
        ylong w2 = (ylong)syscall(MG_SYS_FCNTL, w, MG_F_DUPFD, GUEST_FD + 1, 0L);
        (void)syscall(MG_SYS_CLOSE, r, 0L);
        (void)syscall(MG_SYS_CLOSE, w, 0L);
        if (r2 < 0 || w2 < 0) {
            if (r2 >= 0) { (void)syscall(MG_SYS_CLOSE, r2, 0L); };
            if (w2 >= 0) { (void)syscall(MG_SYS_CLOSE, w2, 0L); };
            return yr(3, "ok", yv_bool(0), "rfd", yv_long(-1), "wfd", yv_long(-1));
        } else {
            return yr(3, "ok", yv_bool(1), "rfd", yv_long(r2), "wfd", yv_long(w2));
        }
    }
}

static Yv *run_image_go(Yv *b, Yv *av, int want_out, Yv *im) {
    Yv *m = yr(6, "img", yv_long(0), "memsz", yr_get(im, "memsz"),
               "entry", yr_get(im, "entry"), "span", yv_long(img_span(im)),
               "rfd", yv_long(-1), "keep", yv_long(-1));
    if (want_out) {
        Yv *pp = pipe_fds();
        if (!yv_truth(yr_get(pp, "ok"))) {
            return run_fail(ys("cannot create a pipe for the generator"));
        } else {
            yr_set(m, "rfd", yr_get(pp, "rfd"));
            yr_set(m, "keep", yv_long(-1));
            return run_image_fd(b, av, im, m, yv_l(yr_get(pp, "wfd")));
        }
    } else {
        return run_image_fd(b, av, im, m, -1);
    }
}

Yv *run_image(Yv *b, Yv *av, int want_out) {
    Yv *im = elf_img(b);
    if (!yv_truth(yr_get(im, "ok"))) {
        return run_fail(yr_get(im, "err"));
    } else {
        return run_image_go(b, av, want_out, im);
    }
}

/* ── the scanner ─────────────────────────────────────────────────────────
 * The scanner's state is module-level, the way native.c's import bookkeeping
 * is: one file at a time, reset by meta_scan, and the functions below take no
 * state arguments. See ideas/meta.md for why this exists at all; the short
 * version is that only CODE position is scanned, so a `#{` inside any literal
 * or comment is plain text, there is no escape character anywhere, and a
 * generator may emit string literals holding `#{` freely.
 *
 * The shape of the loop: one pass over the file's bytes, with the interesting
 * bytes being a quote, a slash (a comment opener), a brace, a `;` and a
 * newline. Everything between two of them is one slice, so the scan costs one
 * allocation per interesting byte rather than one per byte -- which matters,
 * because this runs over every byte of every file of a self-compile.
 *
 * The line map is built BY CONSTRUCTION and never repaired: every byte reaches
 * the two buffers through sg_put (which counts it) or sg_break (which ends a
 * line and starts the next), so a literal spanning four lines costs four lines
 * of P and four of G, and a P line that spans several source lines carries the
 * one it STARTED at -- the honest origin for generated text. */

static Yv *sg_src = 0;
static ylong sg_fid = 0;
/* The dir of the file being scanned: a hoisted import path normalizes against
 * it, not against G's own dir. */
static Yv *sg_dir = 0;
/* P: the program's text, each block's bytes dropped. G: the generator's, each
 * block's bytes replaced by the call. Both as (line, file, source line). */
static Yv *sg_p = 0;
static Yv *sg_pf = 0;
static Yv *sg_pol = 0;
/* Which P lines a block's piece is: filled by mg_splice, read back as
 * sc.gen. All false until the pieces arrive (the collecting pass). */
static Yv *sg_gen = 0;
static Yv *sg_g = 0;
static Yv *sg_gf = 0;
static Yv *sg_gol = 0;
/* The lines being built, and the source line each started at. A P line can
 * span several source lines -- a block covering lines 4-7 makes P's line 4
 * hold all four -- so sg_pline is where the line STARTED, not where it ended. */
static Yv *sg_pbuf = 0;
static Yv *sg_gbuf = 0;
static ylong sg_pline = 1;
static ylong sg_gline = 1;
/* Where the current G line starts inside sg_gbuf: what is between it and the
 * end is the code since the last newline, and that decides statement position. */
static ylong sg_gat = 0;
/* ── the mid-token buffers ────────────────────────────────────────────────
 * A block that has no operand position at its own byte offset cannot put its
 * call there (see sg_open), so its call is written HERE instead of into
 * sg_gbuf, and sg_mids_move puts it at the top-level statement that contains
 * it. The buffer is saved and restored per block, so a mid-token block nested
 * in one is hoisted out of it -- in close order, which is the order the calls
 * have to run in.
 *
 * The same machinery HOLDS the text of a block that has to give it up: a nested
 * block whose text is already in the table contributes TEXT to the block around
 * it, and a block that cannot produce its text this round contributes a stub --
 * so in both cases its own bytes are scanned (the slots of the blocks inside it
 * have to be the same every round) and then dropped, and sg_hold/sg_drop is how
 * that is said. Nothing is written to the live buffer while a block is held, so
 * the text before the block, the line it is on and the statement it belongs to
 * are all still exactly where they were.
 *
 * sg_mmid says a block is held, so sg_gadd and the writes below go here;
 * sg_mbuf is the text and sg_mol the source line each of its lines started at
 * (its lines move, so their origins travel with them). */
static int sg_mmid = 0;
static Yv *sg_mbuf = 0;
static Yv *sg_mol = 0;
static int sg_molast = 0;
static ylong sg_mline = 1;
/* The buffer of an enclosing block, saved while a nested one is held and
 * restored when it closes (so the nested call is hoisted out of it, not written
 * into it). */
static Yv *sg_midsave = 0;
static Yv *sg_molsave = 0;
static Yv *sg_mlastsave = 0;
static Yv *sg_mlinesave = 0;
/* The G line each held buffer started at, and the one for the file's own buffer.
 * sg_restore needs it to name the line the text after a held block continues,
 * and sg_drop to put it back where it was -- a dropped block's lines are gone,
 * so nothing may carry on counting from them. */
static Yv *sg_glsave = 0;
static ylong sg_glsaved = 1;
/* The hoisted calls, in CLOSE order: innermost first, then siblings in source
 * order -- which is exactly the order they have to run in. Each carries the
 * top-level statement it belongs to, so the move can order them per statement.
 * Type MidMove = { line, off, text, ol }. */
static Yv *sg_mids = 0;
/* The top-level statement in progress: its first token's position, and whether
 * one has been found yet (before it, everything is blanks and comments). */
static ylong sg_tsline = 1;
static ylong sg_tsoff = 0;
static int sg_tsp = 0;
/* The depth of the innermost held block, 0 for none, recomputed by sg_m_live
 * whenever a block closes. A top-level `;` or `}` only ends a statement when no
 * block is held, so the anchor cannot land inside one of these hoisted calls. */
static ylong sg_mdepth = 0;
static ylong sg_line = 1;
static ylong sg_col = 1;
/* 0 code, 1 a `//` comment, 2 a block comment, 3 a literal. */
static ylong sg_state = 0;
/* True when the next byte of code position may start a `def`, a `type`, an
 * `import` or a refused name: after a newline, a `;`, a `{`, a `}` or a `#{`.
 * Those are the only places a keyword can be, so the word is only read there --
 * which is what keeps this a byte scan and not a parse. */
static int sg_bound = 0;
/* The brace stack: 0 an ordinary brace, 1 a `def` body, 2 a `type` body. A block
 * may not open while any 1 or 2 is on the stack, nor while sg_pending is set
 * (the `def` keyword itself, so the header's parameter list counts as the body
 * too). sg_tkind is what is being declared: 0 a `def`, 2 a `type`. */
static Yv *sg_bkind = 0;
static ylong sg_tkind = 0;
static int sg_pending = 0;
/* Per open block: whether only blanks have been seen since its `#{` (an
 * import is only hoistable then), the brace depth at its `#{`, whether it is in
 * statement position, and whether it is mid-token (its call is hoisted, so the
 * bytes after its `}#` belong to the file's own G, not to its buffer). */
static Yv *sg_bclean = 0;
static Yv *sg_bbrace = 0;
static Yv *sg_bstmt = 0;
static Yv *sg_bmid = 0;
/* Per open block, for the nesting: its slot (mg_have is indexed by it), whether
 * every block opened inside it had its text when it opened, whether its text
 * was already in the table -- in which case it contributes TEXT to the block
 * around it and never runs -- whether it sits inside text that is not compiled
 * at all, and whether its own text is held rather than written into the live
 * buffer as it is scanned. */
static Yv *sg_bslot = 0;
static Yv *sg_bok = 0;
static Yv *sg_bsplice = 0;
static Yv *sg_bdead = 0;
static Yv *sg_bhold = 0;
static ylong sg_depth = 0;
/* The top-level statement in progress, for the reduction (mg_reduce): the line
 * of G it starts on, the text of the line in progress when it started and the
 * source line that line began at -- so a drop can put both back -- whether it is
 * a declaration, whether a block is inside it, and whether its first word has
 * not been read yet. */
static ylong sg_rfrom = 0;
static Yv *sg_rtext = 0;
static ylong sg_rgline = 1;
static ylong sg_rbrace = 0;
static int sg_rkeep = 0;
static int sg_rblk = 0;
static int sg_rpend = 1;
/* The first diagnostic, and where. The rest of the text is not scanned. */
static Yv *sg_err = 0;
static ylong sg_eline = 0;
static ylong sg_ecol = 0;
/* Set while mg_probe scans: the probe is asking "is there a block in this
 * text", not "is this text a legal file", so it must read PAST a diagnostic
 * (the text it is given is G's own, whose `ycc_meta_stmt` calls the program's
 * own pass would refuse) instead of stopping at the first one. */
static int sg_quiet = 0;

static ylong sg_fail(Yv *msg, ylong line, ylong col) {
    if (ys_eq_lit(sg_err, "") && !sg_quiet) {
        sg_err = msg;
        sg_eline = line;
        sg_ecol = col;
    };
    return 0;
}

/* Append text to whichever G buffer is live: the file's own, or a mid-token
 * block's (its call is written there and hoisted afterwards, so it does not
 * sit where the block stood). Blocks nest, so `mid` is the innermost block's. */
/* Defined further down (with the mid-token machinery): mg_lines splits text on
 * its newlines, sg_region_open opens the reduction's statement region,
 * sg_region_word reads the region's first word, mg_directive says whether that
 * word is one the reduction keeps, mg_stub is the stand-in a block runs when it
 * cannot produce its text, and mg_commit throws the stand-ins' pieces away. */
static Yv *mg_lines(Yv *text);
static ylong sg_region_open(void);
static ylong sg_region_word(Yv *w);
static int mg_directive(Yv *w);
static Yv *mg_stub(ylong slot, int stmt);
static ylong mg_commit(void);

static ylong sg_gadd(Yv *t, int mid) {
    if (mid) { sg_mbuf = ys_cat(sg_mbuf, t); }
    else { sg_gbuf = ys_cat(sg_gbuf, t); };
    return 0;
}

/* Hold this block's text: from here to its `}#` it goes to a buffer of its own
 * and nowhere else. sg_restore puts it back where it came from; sg_drop throws
 * it away. Nothing is written to the live buffer meanwhile, which is what makes
 * both safe. */
static ylong sg_hold(void) {
    sg_midsave = ya_push(sg_midsave, sg_mbuf);
    sg_molsave = ya_push(sg_molsave, sg_mol);
    sg_mlastsave = ya_push(sg_mlastsave, yv_bool(sg_molast));
    sg_mlinesave = ya_push(sg_mlinesave, yv_long(sg_mline));
    sg_glsave = ya_push(sg_glsave, yv_long(sg_glsaved));
    sg_mmid = 1;
    sg_mdepth = sg_depth;
    sg_glsaved = sg_gline;
    sg_mbuf = ys("");
    sg_mol = yav(0);
    sg_molast = 0;
    sg_mline = sg_gline;
    return 0;
}

/* The enclosing block's buffer back, whatever this one did with its own. */
static ylong sg_m_pop(void) {
    sg_mbuf = ya_get(sg_midsave, yv_len(sg_midsave) - 1);
    sg_midsave = ya_slice(sg_midsave, 0, yv_len(sg_midsave) - 1);
    sg_mol = ya_get(sg_molsave, yv_len(sg_molsave) - 1);
    sg_molsave = ya_slice(sg_molsave, 0, yv_len(sg_molsave) - 1);
    sg_molast = yv_truth(ya_get(sg_mlastsave, yv_len(sg_mlastsave) - 1));
    sg_mlastsave = ya_slice(sg_mlastsave, 0, yv_len(sg_mlastsave) - 1);
    sg_mline = yv_l(ya_get(sg_mlinesave, yv_len(sg_mlinesave) - 1));
    sg_mlinesave = ya_slice(sg_mlinesave, 0, yv_len(sg_mlinesave) - 1);
    sg_glsaved = yv_l(ya_get(sg_glsave, yv_len(sg_glsave) - 1));
    sg_glsave = ya_slice(sg_glsave, 0, yv_len(sg_glsave) - 1);
    return 0;
}

/* The held text, back in the buffer it came from, in place, between `pre` and
 * `post`. The live buffer has not moved -- nothing was written to it while the
 * block was held -- so this is an append, and each line goes back with the origin
 * it was scanned under. The line the text after the block continues is the one
 * the held text's last line started at, so that is what the G line counter goes
 * back to.
 *
 * `pre`/`post` are the block's own call: the prefix cannot be written at the
 * `#{` any more, because whether this round has the text of every block inside
 * is only known at the `}#` (see sg_top_close). */
static ylong sg_restore(Yv *pre, Yv *post) {
    Yv *segs = mg_lines(sg_mbuf);
    ylong last = yv_len(segs) - 1;
    ylong i = 0;
    if (!ys_eq_lit(pre, "")) { sg_gbuf = ys_cat(sg_gbuf, pre); };
    while (i < yv_len(segs)) {
        if (i < last) {
            sg_gbuf = ys_cat(sg_gbuf, ya_get(segs, i));
            sg_g = ya_push(sg_g, sg_gbuf);
            sg_gf = ya_push(sg_gf, yv_long(sg_fid));
            if (i < yv_len(sg_mol)) { sg_gol = ya_push(sg_gol, ya_get(sg_mol, i)); }
            else { sg_gol = ya_push(sg_gol, yv_long(sg_gline)); };
            sg_gbuf = ys("");
        } else {
            sg_gbuf = ys_cat(sg_gbuf, ya_get(segs, i));
        };
        i = i + 1;
    };
    if (!ys_eq_lit(post, "")) { sg_gbuf = ys_cat(sg_gbuf, post); };
    if (sg_molast) { sg_gline = sg_mline; };
    sg_gat = 0;
    return sg_m_pop();
}

/* The held text, thrown away: the block's lines are not in G and not in P, so
 * the line counter goes back to where the buffer began -- the text that follows
 * the block continues the line the block started on, not one of its own. */
static ylong sg_drop(void) {
    sg_gline = sg_glsaved;
    return sg_m_pop();
}

/* A block's own text, spliced into the source of the block AROUND it where the
 * block stood: this is what a nested block contributes once the table has its
 * text (sg_splice is the nesting, not a call in the enclosing block's source).
 * `at` is the line of its `#{` and every generated line takes it, for the same
 * reason the pieces spliced into P do (mg_splice): the text is this block's, so
 * the lines are its line, whatever line of G they land on.
 *
 * The block around it is always held, so the text goes to sg_mbuf; called
 * BEFORE sg_hold, because the text belongs to the enclosing block. */
static ylong sg_splice(ylong slot, ylong at) {
    Yv *lines = mg_lines(ya_get(mg_piece, slot));
    ylong last = yv_len(lines) - 1;
    ylong i = 0;
    while (i < yv_len(lines)) {
        sg_mbuf = ys_cat(sg_mbuf, ya_get(lines, i));
        if (i < last) {
            sg_mol = ya_push(sg_mol, yv_long(at));
            sg_mbuf = ys_cat(sg_mbuf, ys("\n"));
            sg_molast = 0;
            sg_gline = at;
        };
        i = i + 1;
    };
    return 0;
}

static ylong sg_ts_end(void) {
    sg_tsp = 0;
    return 0;
}

/* The top-level statement in progress: `t` is about to be written at
 * (sg_gline, len(sg_gbuf)) -- or into a mid-token block's buffer, where there
 * is no top-level statement to find. While one is being looked for, the first
 * byte of `t` that is not a blank IS its first token; after that the statement
 * has started and nothing moves it. Blanks and comments therefore never become
 * the anchor, which is what puts a `// note` before a statement above it
 * rather than inside it. */
static ylong sg_ts_go(Yv *t) {
    if (!sg_tsp) {
        ylong i = 0;
        int go = 1;
        while (go && i < yv_len(t)) {
            if (!m_blank(ys_byte_at(t, i))) {
                sg_tsline = sg_gline;
                sg_tsoff = yv_len(sg_gbuf) + i;
                sg_tsp = 1;
                go = 0;
            };
            i = i + 1;
        };
    };
    return 0;
}

/* The source line a mid-token buffer's LAST line started at: the first byte of
 * `t` that is not a blank, if there is one and none has been found yet (the
 * line began when the buffer began, at whatever `}`#` came closest to). */
static int sg_ml_go(Yv *t) {
    if (sg_molast) { return 1; }
    else {
        ylong i = 0;
        while (i < yv_len(t)) {
            if (!m_blank(ys_byte_at(t, i))) {
                sg_molast = 1;
                sg_mline = sg_gline;
                i = yv_len(t);
            };
            i = i + 1;
        };
        return sg_molast;
    }
}

/* One piece of text, into both buffers. A byte inside a block reaches G only:
 * P has to drop the block whole. Blanks do not count towards the enclosing
 * block's "nothing but blanks yet" flag, which is what decides whether an
 * `import` there is at the block's top level. */
static ylong sg_put(Yv *t) {
    if (yv_len(t) > 0) {
        int mid = sg_mmid;
        if (!mid) { (void)sg_ts_go(t); } else { sg_molast = sg_ml_go(t); };
        (void)sg_gadd(t, mid);
        if (sg_depth == 0) {
            sg_pbuf = ys_cat(sg_pbuf, t);
        } else if (!m_all_blank(t)) {
            ya_set(sg_bclean, sg_depth - 1, yv_bool(0));
        };
        sg_col = sg_col + yv_len(t);
    };
    return 0;
}

/* One byte that is never a blank: a delimiter, or a word's first byte. */
static ylong sg_put1(Yv *c) {
    if (sg_mmid) { if (!sg_molast) { sg_molast = 1; } }
    else { (void)sg_ts_go(c); };
    (void)sg_gadd(c, sg_mmid);
    if (sg_depth == 0) {
        sg_pbuf = ys_cat(sg_pbuf, c);
    } else {
        ya_set(sg_bclean, sg_depth - 1, yv_bool(0));
    };
    sg_col = sg_col + 1;
    return 0;
}

/* End the current line in both texts. G always breaks (its line count tracks
 * the source's, so a diagnostic in G has a line); P breaks only outside a
 * block, because a block's own newlines belong to the call in G and not to a
 * line of P. A line is a line: neither text keeps the newline, so the two
 * join back to their sources.
 *
 * A mid-token block's call breaks into ITS buffer, and its origin goes with
 * the line: the call is hoisted to another statement afterwards, so the two
 * have to travel together or a diagnostic in G would name the wrong line. */
static ylong sg_break(void) {
    if (sg_mmid) {
        sg_mol = ya_push(sg_mol, yv_long(sg_gline));
        sg_mbuf = ys_cat(sg_mbuf, ys("\n"));
    } else {
        sg_g = ya_push(sg_g, sg_gbuf);
        sg_gf = ya_push(sg_gf, yv_long(sg_fid));
        sg_gol = ya_push(sg_gol, yv_long(sg_gline));
    };
    sg_gbuf = ys("");
    sg_gline = sg_line + 1;
    sg_gat = 0;
    if (sg_depth == 0) {
        sg_p = ya_push(sg_p, sg_pbuf);
        sg_pf = ya_push(sg_pf, yv_long(sg_fid));
        sg_pol = ya_push(sg_pol, yv_long(sg_pline));
        sg_pbuf = ys("");
        sg_pline = sg_line + 1;
    };
    sg_line = sg_line + 1;
    sg_col = 1;
    return 0;
}

/* sg_src[a:b] into both buffers, breaking lines on the newlines it holds. So
 * a literal or a comment that spans lines costs the lines it really has, and
 * the two texts stay in step with the source without either counting. */
static ylong sg_out(ylong a, ylong b) {
    ylong i = a;
    while (i < b) {
        ylong nl = -1;
        ylong j = i;
        int go = 1;
        while (go && j < b) {
            if (ys_byte_at(sg_src, j) == 10) { nl = j; go = 0; }
            else { j = j + 1; };
        };
        if (nl < 0) {
            (void)sg_put(ys_slice(sg_src, i, b));
            i = b;
        } else {
            (void)sg_put(ys_slice(sg_src, i, nl));
            (void)sg_break();
            i = nl + 1;
        };
    };
    return 0;
}

static ylong sg_reset(Yv *src, ylong fid, Yv *dir) {
    sg_src = src;
    sg_fid = fid;
    sg_dir = dir;
    sg_p = yav(0);
    sg_pf = yav(0);
    sg_pol = yav(0);
    sg_gen = yav(0);
    sg_g = yav(0);
    sg_gf = yav(0);
    sg_gol = yav(0);
    sg_pbuf = ys("");
    sg_gbuf = ys("");
    sg_pline = 1;
    sg_gline = 1;
    sg_gat = 0;
    sg_line = 1;
    sg_col = 1;
    sg_state = 0;
    /* true, not false: line 1's first word is a keyword position like any
     * other, so a file whose first line is `def`/`import` is seen */
    sg_bound = 1;
    sg_bkind = yav(0);
    sg_pending = 0;
    sg_bclean = yav(0);
    sg_bbrace = yav(0);
    sg_bstmt = yav(0);
    sg_bslot = yav(0);
    sg_bok = yav(0);
    sg_bsplice = yav(0);
    sg_bdead = yav(0);
    sg_bhold = yav(0);
    sg_depth = 0;
    sg_err = ys("");
    sg_eline = 0;
    sg_ecol = 0;
    sg_mmid = 0;
    sg_mbuf = ys("");
    sg_mol = yav(0);
    sg_molast = 0;
    sg_mline = sg_gline;
    sg_mids = yav(0);
    sg_tsline = 1;
    sg_tsoff = 0;
    sg_tsp = 1;
    sg_mdepth = 0;
    sg_glsaved = 1;
    sg_glsave = yav(0);
    return sg_region_open();
}

/* Any brace on the stack a `def`/`type` BODY opened? A `type` body is marked
 * on the stack (2) and a `def` body by sg_pending together with its stack entry
 * (1): a `type` header has braces of its own, so one flag cannot cover both.
 * A mid-token block opens NO brace (its call is a statement somewhere else, so
 * there is nothing here to be inside), which is why sg_open asks the body
 * question and the header question separately. */
static int sg_in_body(void) {
    int hit = 0;
    ylong i = 0;
    while (i < yv_len(sg_bkind)) {
        ylong k = yv_l(ya_get(sg_bkind, i));
        if (k == 1 || k == 2) { hit = 1; };
        i = i + 1;
    };
    return hit;
}

/* The names a block may not use: the thread and process primitives. Under the
 * fork they are harmless -- a guest spawn's damage lands in the child and dies
 * with it -- but they are refused anyway, because a generator that spawns is
 * always a mistake and naming it is the whole value of the check. Only a CALL
 * (`name(`) or a DEF (`def name`) is refused, so a generator may still use the
 * word as a variable or a field. */
static int mg_thread(Yv *w) {
    return ys_eq_lit(w, "spawn") || ys_eq_lit(w, "fork") || ys_eq_lit(w, "join") ||
           ys_eq_lit(w, "mutex") || ys_eq_lit(w, "lock") ||
           ys_eq_lit(w, "try_lock") || ys_eq_lit(w, "sem") ||
           ys_eq_lit(w, "post") || ys_eq_lit(w, "wait");
}

/* The names the pass injects into G. `y_`-prefixed, so a module imported into
 * the generator namespaces its own names and cannot collide -- but the
 * program's OWN top level is flat, so a def there is the collision. */
static int mg_reserved(Yv *w) {
    return ys_eq_lit(w, "ycc_meta_expr") || ys_eq_lit(w, "ycc_meta_stmt") ||
           ys_eq_lit(w, "ycc_meta_emit");
}

/* The next byte at or after i the scanner must stop at, or n. Only meaningful
 * in code position: inside a comment or a literal everything is text.
 *
 * Outside a block the interesting bytes are all it needs, and a word is text
 * between two of them. INSIDE a block a word start is interesting too, because
 * that is where a refused name and an injected helper's name have to be caught,
 * and they can sit anywhere in an expression (`let t = spawn { … }` is not at
 * a statement boundary). So a block costs a check per word, and a file with no
 * blocks costs nothing. */
static ylong sg_next(ylong i, ylong n) {
    ylong j = i;
    int found = 0;
    while (j < n && !found) {
        ylong c = ys_byte_at(sg_src, j);
        if (c == '#' || c == '"' || c == '\'' || c == '/' || c == '{' ||
            c == '}' || c == ';' || c == 10) {
            found = 1;
        } else if (sg_depth > 0 && m_word(c)) {
            found = 1;
        } else {
            j = j + 1;
        };
    };
    return j;
}

/* `import a from "./b.y"` normalized the way native.c's norm_path does: the
 * splicer will normalize again on its own side, but this one decides WHICH file
 * the path means, so it has to collapse the "/./" a nested base dir carries. */
static Yv *mg_norm_path(Yv *p) {
    Yv *parts = ys_split(p, ys("/"));
    Yv *out = yav(0);
    ylong i = 0;
    while (i < yv_len(parts)) {
        Yv *seg = ya_get(parts, i);
        if (!ys_eq_lit(seg, ".")) { out = ya_push(out, seg); };
        i = i + 1;
    };
    return ys_join(out, ys("/"));
}

/* `import <rest>` with a path normalized the way native.c's norm_path does:
 * the splicer normalizes again on its own side, but this one decides WHICH file
 * the path means, so it has to collapse the "/./" a nested base dir carries. */
static Yv *mg_import_line(Yv *rest, Yv *dir) {
    ylong k = ys_index_of(rest, ys(" from "));
    if (k < 0) {
        return ys_cat(ys("import "), rest);
    } else {
        Yv *name = ys_slice(rest, 0, k);
        Yv *tail = ys_slice_from(rest, k + 6);
        Yv *path = tail;
        if (yv_len(path) >= 2 && ys_eq_lit(ys_slice(path, 0, 1), "\"") &&
            ys_eq_lit(ys_slice_from(path, yv_len(path) - 1), "\"")) {
            Yv *p = ys_slice(path, 1, yv_len(path) - 1);
            Yv *full = p;
            if (!ys_eq_lit(ys_slice(p, 0, 1), "/")) {
                full = ys_cat(ys_cat(dir, ys("/")), p);
            };
            path = scat3(ys("\""), mg_norm_path(full), ys("\""));
        };
        return scat3(ys("import "), name, ys_cat(ys(" from "), path));
    }
}

/* An `import` inside a block, hoisted to the top of G so the existing splicer
 * resolves it: its dedup, its namespacing, its cycle detection and its
 * depth-32 diagnostic all come free. `after` is past the `import` keyword. */
static ylong sg_import(ylong after, ylong n) {
    ylong ignored = 0;
    int top = 0;
    ylong k = sg_depth - 1;
    if (sg_depth > 0 && yv_truth(ya_get(sg_bclean, k)) &&
        yv_len(sg_bkind) == yv_l(ya_get(sg_bbrace, k))) { top = 1; };
    if (!top) {
        (void)sg_fail(ys("an import inside a meta block must come first in the block"), sg_line, sg_col);
        return after;
    } else {
        ylong j = after;
        int go = 1;
        ylong semi = 0;
        while (go && j < n) {
            ylong c = ys_byte_at(sg_src, j);
            if (c == '"' || c == '\'') {
                j = lit_end(sg_src, j, &ignored);
            } else if (c == ';') {
                semi = j + 1;
                go = 0;
            } else {
                j = j + 1;
            };
        };
        if (semi == 0) {
            (void)sg_fail(ys("an import inside a meta block must end with ';'"), sg_line, sg_col);
            return after;
        } else {
            mg_imp = ya_push(mg_imp, mg_import_line(ys_trim(ys_slice(sg_src, after, semi)), sg_dir));
            mg_iol = ya_push(mg_iol, yv_long(sg_line));
            sg_bound = 1;
            sg_pending = 0;
            return semi;
        }
    }
}

/* A name the pass has an opinion about, in a block: one of the injected
 * helpers, or a thread/process primitive being CALLED or DEFINED (a variable or
 * a field of that name is fine, and so is the bare word). */
static ylong sg_check_name(Yv *w, int called) {
    if (mg_reserved(w)) {
        (void)sg_fail(scat3(ys("'"), w,
                            ys("' is reserved: the meta pass injects it into the generator")),
                      sg_line, sg_col);
    } else if (sg_depth > 0 && mg_thread(w) && called) {
        (void)sg_fail(scat3(ys("'"), w,
                            ys("' cannot be used in a meta block: the generator runs in a forked child, and a thread or process primitive there is never what was meant")),
                      sg_line, sg_col);
    };
    return 0;
}

static ylong sg_word_go(Yv *w, ylong after, ylong n) {
    /* the first word of the statement in progress is what the reduction reads */
    if (mg_reduce && sg_depth == 0) { (void)sg_region_word(w); };
    ylong j = after;
    int go = 1;
    while (go && j < n && (ys_byte_at(sg_src, j) == 32 ||
                           ys_byte_at(sg_src, j) == 9)) {
        j = j + 1;
    };
    int called = j < n && (ys_byte_at(sg_src, j) == '(' ||
                            ys_byte_at(sg_src, j) == '{');
    if (ys_eq_lit(w, "def") || ys_eq_lit(w, "type")) {
        /* the NAME it defines, not the keyword: a collision with an injected
         * helper is a duplicate top-level def, and it is silent in the
         * generator the same way it would be in the program */
        if (j < n && m_word(ys_byte_at(sg_src, j))) {
            (void)sg_check_name(m_word_at(sg_src, j, n), 1);
        };
        sg_pending = 1;
        sg_tkind = 0;
        if (ys_eq_lit(w, "type")) { sg_tkind = 2; };
        return after;
    } else {
        (void)sg_check_name(w, called);
        return after;
    }
}

/* At a statement boundary: the word there, if any. Handles `def`, `type`,
 * `import` and the refused and reserved names; an ordinary name is nothing to
 * do. Returns where to carry on from -- which is past the word, and past an
 * `import` the caller must then not emit again. */
static ylong sg_word(ylong i, ylong n) {
    ylong k = i;
    int go = 1;
    while (go && k < n && (ys_byte_at(sg_src, k) == 32 ||
                           ys_byte_at(sg_src, k) == 9 ||
                           ys_byte_at(sg_src, k) == 13)) {
        k = k + 1;
    };
    if (k < n && m_word(ys_byte_at(sg_src, k))) {
        Yv *w = m_word_at(sg_src, k, n);
        ylong after = k + yv_len(w);
        if (ys_eq_lit(w, "import") && sg_depth > 0) {
            /* hoisted to the top of G, so it is not part of G's block text:
             * the blanks before it are, or the block's own column drifts */
            (void)sg_put(ys_slice(sg_src, i, k));
            return sg_import(after, n);
        } else {
            (void)sg_out(i, after);
            return sg_word_go(w, after, n);
        }
    } else {
        return i;
    }
}

/* ── the mid-token machinery ───────────────────────────────────────────── */

/* Which G buffer is live now that the block has closed and the per-block
 * stacks have been popped: a held block's own if one is still open, and
 * sg_mdepth says at what depth (0 = the file's own buffer). */
static ylong sg_m_live(void) {
    sg_mmid = 0;
    sg_mdepth = 0;
    ylong k = sg_depth - 1;
    while (k >= 0) {
        if (yv_truth(ya_get(sg_bhold, k))) { sg_mmid = 1; sg_mdepth = k + 1; };
        k = k - 1;
    };
    return 0;
}

/* Whether a block has ever had a block open inside it. Structural, so the table
 * is the same in every round and is never cleared; a slot nobody has reached yet
 * reads false. sg_open needs it BEFORE it has scanned the block's own body, to
 * know whether to hold that body. */
static int mg_bkids_had(ylong slot) {
    while (yv_len(mg_bkids) <= slot) { mg_bkids = ya_push(mg_bkids, yv_bool(0)); };
    return yv_truth(ya_get(mg_bkids, slot));
}

/* Record the nesting shape: a block that opens inside another one. */
static ylong mg_kid_note(ylong par) {
    while (yv_len(mg_bkids) <= par) { mg_bkids = ya_push(mg_bkids, yv_bool(0)); };
    ya_set(mg_bkids, par, yv_bool(1));
    return 0;
}

/* ── the reduction ────────────────────────────────────────────────────────
 * On for a program that HAS nesting (mg_reduce). A round in which a block could
 * not produce its text leaves a STUB where its call goes (sg_top_close), so a
 * statement reading a name that block was going to define would not compile:
 * `#{ let v = #{ "1+1" }#; let x = v; }#` then `print(x);` names `x` in a program
 * that has not been generated yet. So in such a round a top-level statement that
 * is neither a declaration nor carries a block is left out of G altogether.
 *
 * That costs the generator no name: the only statements dropped are ones that
 * begin with `print(`, `f(`, an operator -- none of which declares anything -- so
 * every binding G needs is still there, and a block reads exactly the same names.
 * It does cost a block the SIDE EFFECT of such a statement, which is what the
 * pass's own warning about top-level statements already says to avoid.
 *
 * The extent is exact and needs no parser. A top-level statement in Y ends at a
 * `;` or at the `}` that closes it (MEASURED: `print(1)` with no `;` is
 * "expected ';'"), so the regions here are exactly the statements. A block
 * statement has no terminator of its own and so runs on to the next one -- which
 * is harmless, because a region holding a block is never dropped. */
static ylong sg_region_open(void) {
    /* The line in progress when a region starts belongs to the region that ENDS
     * here, not to this one: so it is kept aside, and dropping this region puts
     * it back. Everything else this region adds is whole G lines, so a drop is a
     * truncation of those plus this one string.
     *
     * The line counter goes back with them: the dropped lines were not in G, so
     * nothing may carry on counting from them -- the same reason sg_drop rewinds
     * it for a dropped block. */
    sg_rtext = sg_gbuf;
    sg_rgline = sg_gline;
    sg_rbrace = yv_len(sg_bkind);
    sg_rfrom = yv_len(sg_g);
    sg_rkeep = 0;
    sg_rblk = 0;
    sg_rpend = 1;
    return 0;
}

/* The first word of the region in progress, if it has one yet: a declaration or
 * a splicer directive is kept, anything else is the statement the reduction is
 * about. A region whose first token is not a word (`#{`, a digit, `(`) leaves
 * sg_rpend set, which costs nothing -- the region is over at the next `;`. */
static ylong sg_region_word(Yv *w) {
    if (sg_rpend) {
        sg_rpend = 0;
        if (mg_directive(w)) { sg_rkeep = 1; };
    };
    return 0;
}

/* The words the reduction keeps: the four declarations, plus the splicer's own
 * whole-line directives (`import`, `export`, `embed`), which are consumed by the
 * resolve and never reach the lexer. */
static int mg_directive(Yv *w) {
    return ys_eq_lit(w, "def") || ys_eq_lit(w, "type") || ys_eq_lit(w, "let") ||
           ys_eq_lit(w, "const") || ys_eq_lit(w, "import") ||
           ys_eq_lit(w, "export") || ys_eq_lit(w, "embed");
}

/* The region is over. Drop it whole unless it is a declaration or holds a block:
 * its G lines go back to where it began. No hoisted call can point into a
 * dropped region -- a hoist belongs to a mid-token block, and a mid-token block
 * makes its region one that holds a block. */
static ylong sg_region_close(void) {
    if (!sg_rkeep && !sg_rblk) {
        sg_g = ya_slice(sg_g, 0, sg_rfrom);
        sg_gf = ya_slice(sg_gf, 0, sg_rfrom);
        sg_gol = ya_slice(sg_gol, 0, sg_rfrom);
        sg_gbuf = sg_rtext;
        sg_gline = sg_rgline;
        sg_gat = 0;
    };
    return sg_region_open();
}

/* `}#` of a top-level block that HELD its text: the call goes where the block
 * stood, wrapping either the block's own body or a stand-in for it.
 *
 * The stand-in is the whole of what a block that cannot produce its text this
 * round contributes. Its shape is the real call's -- same helper, same position,
 * same `;` -- with the body `0`, so the statement around it still compiles and
 * still type-checks the way it did when the block was a call. Its piece is "0",
 * and mg_commit throws that away with everything else.
 *
 * Which of the two it is cannot be decided at the `#{`, and is not: this is the
 * first point where every block opened inside this one has closed and said
 * whether its text was in the table. A block with nothing inside is never held
 * and never comes through here, which is what keeps a program with no nesting on
 * the path the pass has always taken. */
static ylong sg_top_close(ylong k) {
    ylong slot = yv_l(ya_get(sg_bslot, k));
    int stmt = yv_truth(ya_get(sg_bstmt, k));
    Yv *helper = ys("ycc_meta_expr");
    if (stmt) { helper = ys("ycc_meta_stmt"); };
    if (yv_truth(ya_get(sg_bok, k))) {
        Yv *post = ys("}))");
        if (stmt) { post = ys("}));"); };
        return sg_restore(scat3(helper, ys("("),
                                ys_cat(ys_tostring(yv_long(slot)),
                                       ys(", tostring({"))), post);
    } else {
        /* the stand-in: the held text is what cannot be compiled, so it goes
         * nowhere at all. The line counter goes back with it (sg_drop), and the
         * call goes where the block stood -- into the live buffer, which still
         * holds only the text from BEFORE the block, so the call lands in the
         * right place and the text after the block follows it. */
        (void)sg_drop();
        sg_gbuf = ys_cat(sg_gbuf, mg_stub(slot, stmt));
        return 0;
    };
}

/* The stand-in a block runs when it cannot produce its text this round. Same
 * helper and same position as the real call, with the body `0`: the statement
 * around it still compiles and still type-checks exactly as it did. Its piece is
 * "0", and mg_commit throws that away with everything else. */
static Yv *mg_stub(ylong slot, int stmt) {
    Yv *helper = ys("ycc_meta_expr");
    if (stmt) { helper = ys("ycc_meta_stmt"); };
    Yv *s = scat3(helper, ys("("),
                  ys_cat(ys_tostring(yv_long(slot)), ys(", tostring({ 0 }))")));
    if (stmt) { s = ys_cat(s, ys(";")); };
    return s;
}


/* text's physical lines, and NOT ys_split(): split drops ONE trailing empty
 * element, so split("a\n", "\n") is ["a"] and the line break a piece ends on
 * would be swallowed. A piece is generated text, and every byte of it counts. */
static Yv *mg_lines(Yv *text) {
    Yv *out = yav(0);
    ylong n = yv_len(text);
    ylong start = 0;
    ylong i = 0;
    while (i < n) {
        if (ys_byte_at(text, i) == 10) {
            out = ya_push(out, ys_slice(text, start, i));
            start = i + 1;
        };
        i = i + 1;
    };
    out = ya_push(out, ys_slice_from(text, start));
    return out;
}

/* A mid-token block, and any nested block that has not got its text yet: the
 * call goes to a buffer of its own, and sg_mids_move puts it at the top-level
 * statement that contains the block. The buffer of an enclosing block is saved
 * and restored, so a nested one is hoisted out of it -- and since the moves are
 * applied in close order, it runs first.
 *
 * The call is ALWAYS a statement (`ycc_meta_stmt`, with its `;`): a mid-token
 * block is one that could not be an operand where it stands, and a nested block
 * is one whose enclosing block cannot compile this round -- so neither is an
 * expression by construction, whatever the text around it looks like. */
static ylong sg_m_open(ylong slot) {
    (void)sg_hold();
    sg_mbuf = ys_cat(sg_mbuf, scat3(ys("ycc_meta_stmt("),
                                    ys_tostring(yv_long(slot)),
                                    ys(", tostring({")));
    sg_col = sg_col + 2;
    return 0;
}

/* `}#` of a held block whose call is hoisted -- a mid-token one, or any nested
 * one: close the call, record it with the statement to hoist it to, and give the
 * enclosing block its buffer back. Recorded in CLOSE order, which is the order
 * the calls have to run in. */
static ylong sg_m_close(ylong k) {
    /* A block that is hoisted is not compiled where it stands, so nothing about
     * its source is checked until the round that has its text -- and if one of
     * the blocks inside it has no text this round, its own source cannot compile
     * either, and it runs the stand-in too (mg_stub). Its body then contributes
     * nothing, which is what keeps a hole out of the text around it: the
     * enclosing block is stubbed for the same reason. */
    if (yv_truth(ya_get(sg_bok, k))) {
        sg_mbuf = ys_cat(sg_mbuf, ys("}));"));
    } else {
        sg_mbuf = mg_stub(yv_l(ya_get(sg_bslot, k)), 1);
        sg_mol = yav(0);
        sg_molast = 0;
        sg_mline = sg_gline;
    };
    Yv *lines = mg_lines(sg_mbuf);
    Yv *ol = yav(0);
    ylong i = 0;
    while (i < yv_len(lines)) {
        if (i < yv_len(sg_mol)) { ol = ya_push(ol, ya_get(sg_mol, i)); }
        else if (sg_molast) { ol = ya_push(ol, yv_long(sg_mline)); }
        else { ol = ya_push(ol, yv_long(sg_gline)); };
        i = i + 1;
    };
    ylong line = sg_tsline;
    ylong off = sg_tsoff;
    if (line < 1) { line = 1; };
    if (off < 0) { off = 0; };
    sg_mids = ya_push(sg_mids, yr(4, "line", yv_long(line), "off", yv_long(off),
                                  "text", lines, "ol", ol));
    return sg_m_pop();
}

/* One call, into sg_g at its statement: the statement's line is split at the
 * anchor, the call's lines go between the halves, and its origins go with them. */
static ylong sg_mids_one(ylong k) {
    Yv *m = ya_get(sg_mids, k);
    ylong line = yv_l(yr_get(m, "line"));
    ylong off = yv_l(yr_get(m, "off"));
    Yv *text = yr_get(m, "text");
    Yv *ol = yr_get(m, "ol");
    ylong ln = line - 1;
    if (ln < 0) { ln = 0; };
    Yv *cur = ys("");
    if (ln < yv_len(sg_g)) { cur = ya_get(sg_g, ln); };
    if (off > yv_len(cur)) { off = yv_len(cur); };
    Yv *head = ys_slice(cur, 0, off);
    Yv *tail = ys_slice_from(cur, off);
    Yv *rest = ya_slice(sg_g, 0, ln);
    Yv *restf = ya_slice(sg_gf, 0, ln);
    Yv *restl = ya_slice(sg_gol, 0, ln);
    if (!ys_eq_lit(head, "")) {
        rest = ya_push(rest, head);
        restf = ya_push(restf, yv_long(sg_fid));
        restl = ya_push(restl, yv_long(line));
    };
    ylong i = 0;
    while (i < yv_len(text)) {
        rest = ya_push(rest, ya_get(text, i));
        restf = ya_push(restf, yv_long(sg_fid));
        ylong o = 0;
        if (i < yv_len(ol)) { o = yv_l(ya_get(ol, i)); };
        restl = ya_push(restl, yv_long(o));
        i = i + 1;
    };
    if (!ys_eq_lit(tail, "")) {
        rest = ya_push(rest, tail);
        restf = ya_push(restf, yv_long(sg_fid));
        restl = ya_push(restl, yv_long(line));
    };
    ylong t = ln + 1;
    while (t < yv_len(sg_g)) {
        rest = ya_push(rest, ya_get(sg_g, t));
        restf = ya_push(restf, ya_get(sg_gf, t));
        restl = ya_push(restl, ya_get(sg_gol, t));
        t = t + 1;
    };
    sg_g = rest;
    sg_gf = restf;
    sg_gol = restl;
    return 0;
}

/* Whether move `a` belongs to a LATER statement (or the same one, further along
 * the list) than `b` -- so `a` is the next one out. */
static int mg_after(ylong a, ylong b) {
    Yv *ma = ya_get(sg_mids, a);
    Yv *mb = ya_get(sg_mids, b);
    ylong la = yv_l(yr_get(ma, "line"));
    ylong lb = yv_l(yr_get(mb, "line"));
    if (la != lb) { return la > lb; }
    else { return yv_l(yr_get(ma, "off")) > yv_l(yr_get(mb, "off")); }
}

/* Put every hoisted call at the top-level statement that contains its block.
 * The list is in close order -- innermost first, then siblings in source order
 * -- so within one statement the calls are inserted BACKWARDS, each landing
 * before the one already there, which leaves them in the list's order. And the
 * statements are done from the last to the first, so an insertion never moves a
 * position a later pass still has to read. */
static ylong sg_mids_move(void) {
    ylong n = yv_len(sg_mids);
    Yv *done = yav(0);
    ylong i = 0;
    while (i < n) { done = ya_push(done, yv_bool(0)); i = i + 1; };
    ylong left = n;
    while (left > 0) {
        ylong at = -1;
        ylong j = 0;
        while (j < n) {
            if (!yv_truth(ya_get(done, j))) {
                if (at < 0 || mg_after(j, at)) { at = j; };
            };
            j = j + 1;
        };
        if (at < 0) { left = 0; }
        else {
            (void)sg_mids_one(at);
            ya_set(done, at, yv_bool(1));
            left = left - 1;
        };
    };
    sg_mids = yav(0);
    return 0;
}

/* `#{` at i in code position: check it, record the block, open it, and read the
 * word after it (which may be an `import`). Returns where to carry on from, or
 * n when the block is refused. */
static ylong sg_open(ylong i, ylong n) {
    ylong prev = 0;
    if (i > 0) { prev = ys_byte_at(sg_src, i - 1); };
    int mid = sg_col > 1 && m_token_end(prev);
    /* A block may not be lexically inside a def or type body: in-place emission
     * there would give compile-time-fixed values and a silent "never ran" mode.
     * A MID-TOKEN one in a def's HEADER is not inside the body though --
     * `def helper#{...}#()` is generating the name, which is the point -- so a
     * body brace is what refuses it, not the `def` keyword. */
    if (sg_in_body()) {
        (void)sg_fail(ys("a meta block cannot be inside a def or type body: only the top level and other blocks"), sg_line, sg_col);
        return n;
    } else if (sg_pending && !mid) {
        /* In a header, at an operand position: the call cannot go in a header
         * (`def ycc_meta_stmt(...)(x)` is not a def) and the block is not
         * mid-token, so dropping its bytes is not a join of two adjacent tokens
         * -- for `def #{nm}#()` it would leave `def () -> long`. So a header
         * block has to be a fragment of the name, with the name on one side. */
        (void)sg_fail(ys("a meta block in a def or type header must be part of a name, with a character of the name beside it: a call cannot go in a header, and dropping the block's bytes would leave nothing behind"), sg_line, sg_col);
        return n;
    } else if (sg_depth + 1 > MG_NEST) {
        /* A COST bound, not the parser's: a level of nesting is a round, and a
         * round is a compile and a run of the generator (mg_pending). Naming the
         * cost here is the point -- the number is small because each step is a
         * whole program compiled again, not because the parser minds. */
        (void)sg_fail(scat3(ys("meta blocks nest deeper than "),
                           ys_tostring(yv_long(MG_NEST)),
                           ys(": each level of nesting costs another compile and run of the meta generator, so this is a cost limit, not the parser's")), sg_line, sg_col);
        return n;
    } else {
        int nested = sg_depth > 0;
        ylong slot = mg_next;
        mg_next = slot + 1;
        /* What the block around this one (if any) does with it. A parent whose
         * text was already in the table is not compiled this round -- its text
         * went into ITS parent as text -- so nothing inside it runs, needs a
         * text, or is even looked at beyond keeping its slot stable. That is the
         * DEAD chain, and it is what stops a block from being asked for a piece
         * it can never produce. */
        int pdead = 0;
        if (nested) {
            mg_nest = mg_nest + 1;
            pdead = yv_truth(ya_get(sg_bdead, sg_depth - 1));
            (void)mg_kid_note(yv_l(ya_get(sg_bslot, sg_depth - 1)));
        } else {
            /* a block at the top level keeps the reduction's region: it has one */
            sg_rblk = 1;
        };
        int dead = pdead || (nested && yv_truth(ya_get(sg_bsplice, sg_depth - 1)));
        int have = slot < yv_len(mg_have) && yv_truth(ya_get(mg_have, slot));
        /* A nested block whose text is already in the table contributes that TEXT
         * to the source of the block around it -- that is the whole of nesting --
         * so it never runs and its own bytes are only scanned, for the slots of
         * the blocks inside it, and then dropped. */
        int spliced = !dead && nested && have;
        mg_bfile = ya_push(mg_bfile, yv_long(sg_fid));
        mg_bline = ya_push(mg_bline, yv_long(sg_line));
        mg_p_at = -1;
        if (!nested) { mg_p_at = yv_len(sg_p); };
        mg_bslot = ya_push(mg_bslot, yv_long(slot));
        mg_bp = ya_push(mg_bp, yv_long(mg_p_at));
        mg_bpo = ya_push(mg_bpo, yv_long(yv_len(sg_pbuf)));
        mg_n = mg_n + 1;
        mg_live = ya_push(mg_live, yv_bool(!dead && !spliced));
        /* Does this block's text have to exist? A top-level block's does: it goes
         * into the program. A nested one's does only while the block around it is
         * being compiled -- inside spliced text it is already there. */
        mg_need = ya_push(mg_need, yv_bool(nested ? !dead : 1));
        mg_bok = ya_push(mg_bok, yv_bool(0));
        sg_bmid = ya_push(sg_bmid, yv_bool(mid));
        /* A statement-position block is one that held only blanks before it, and
         * a mid-token one is a statement by construction (it could not be an
         * expression there), so both want the `;` and the void helper. */
        int stmt = mid || m_all_blank(ys_slice_from(sg_gbuf, sg_gat));
        sg_bstmt = ya_push(sg_bstmt, yv_bool(stmt));
        sg_bclean = ya_push(sg_bclean, yv_bool(1));
        sg_bbrace = ya_push(sg_bbrace, yv_long(yv_len(sg_bkind)));
        sg_bslot = ya_push(sg_bslot, yv_long(slot));
        /* this block starts out able to produce its text; a child without its own
         * takes that away (there is exactly one child-fold per open block) */
        sg_bok = ya_push(sg_bok, yv_bool(1));
        if (nested && !dead && !have) {
            ya_set(sg_bok, sg_depth - 1, yv_bool(0));
        };
        sg_bsplice = ya_push(sg_bsplice, yv_bool(spliced));
        sg_bdead = ya_push(sg_bdead, yv_bool(dead));
        /* A top-level block holds its text only when it MAY hold another block,
         * because then this round can find it cannot produce its text and put a
         * stand-in in its place (sg_top_close). The collecting scan, which knows
         * nothing yet, never holds -- so the G it builds for a program with no
         * nesting is the one the pass has always built, and a program with no
         * nesting never pays for any of this. */
        int hold = !mg_collect && !nested && !dead && mg_bkids_had(slot);
        sg_bhold = ya_push(sg_bhold, yv_bool(hold));
        sg_depth = sg_depth + 1;
        sg_bound = 1;
        /* the `#{` is a token like any other, so a block that starts a statement
         * starts it here: the anchor of a hoisted call is this position, and the
         * call lands immediately before the block's own */
        if (!sg_tsp) {
            sg_tsline = sg_gline;
            sg_tsoff = yv_len(sg_gbuf);
            sg_tsp = 1;
        };
        if (dead) {
            /* inside text that is not compiled: scan the bytes for the slots and
             * put them nowhere */
            ya_set(mg_live, slot, yv_bool(0));
            ya_set(mg_need, slot, yv_bool(0));
            (void)sg_hold();
        } else if (spliced) {
            /* its text goes into the enclosing source where the block stood, and
             * its own bytes are held out of it */
            (void)sg_splice(slot, sg_line);
            (void)sg_hold();
        } else if (mid || nested) {
            /* The call is hoisted, which is the SAME rule for both reasons it
             * happens -- and that they are the same rule is the point:
             *
             *   mid-token: the bytes here cannot hold a call.
             *   nested:    the block around this one is not this block's own
             *              source to compile. Its text goes there (sg_splice) or
             *              it does not compile there at all.
             *
             * So a nested block's call goes to a buffer of its own and
             * sg_mids_move puts it at the top-level statement that contains it,
             * which is the statement the enclosing block is in. The enclosing
             * block is stubbed this round (its sg_bok is false, since this block
             * had no text), and a stub drops the enclosing source whole -- so
             * the hole this block leaves in it goes with it, and the two stay
             * consistent. When the text IS known the splice happens instead and
             * no call is emitted, so a nested block's call never runs twice. */
            (void)sg_m_open(slot);
        } else if (hold) {
            /* the prefix waits for the `}#`: only then is it known whether this
             * round has the text of every block inside (sg_top_close) */
            (void)sg_hold();
        } else {
            /* An ordinary call where the block stood. A NESTED one lands inside
             * the enclosing block's own source, which is exactly how a nested
             * block's round works: the enclosing source compiles this round and
             * its output is a stand-in to be thrown away (sg_bok), because the
             * enclosing block cannot produce its real text until the nested one
             * has. The round after, the nested block splices. */
            Yv *helper = ys("ycc_meta_expr");
            if (stmt) { helper = ys("ycc_meta_stmt"); };
            (void)sg_gadd(scat3(helper, ys("("),
                                ys_cat(ys_tostring(yv_long(slot)),
                                       ys(", tostring({"))),
                          sg_mmid);
            sg_col = sg_col + 2;
        };
        ylong k = sg_word(i + 2, n);
        sg_col = sg_col + (k - (i + 2));
        return k;
    }
}

/* `}#` with sg_depth == 0: nothing opened it. */
static ylong sg_stray(ylong i) {
    (void)sg_fail(ys("'}#' in code position with no open meta block"), sg_line, sg_col);
    return i;
}

/* Whether the quote at i opens an f-string: `f` before it, standing alone. */
static int sg_fstring(ylong i) {
    return ys_byte_at(sg_src, i) == '"' && i > 0 &&
           ys_byte_at(sg_src, i - 1) == 'f' &&
           (i == 1 || !m_word(ys_byte_at(sg_src, i - 2)));
}

/* A literal: lit_end finds where it ends and whether it closed, so the one
 * scanner both the lexer and this pass agree on. A literal is not
 * newline-terminated (lexer.c), so it may hold newlines.
 *
 * An f-string is the one form lit_end cannot be asked about: a field holds an
 * expression, and that expression may be a string literal, so its closing
 * quote is not the next quote in the source. The lexer's own fstr_walk finds
 * it, and it falls back to lit_end itself when the f-string is broken. */
static ylong sg_literal(ylong i, ylong n) {
    if (sg_fstring(i)) {
        Yv *w = fstr_walk(sg_src, i);
        (void)sg_out(i, yv_l(yr_get(w, "end")));
        sg_state = 0;
        return yv_l(yr_get(w, "end"));
    } else {
        ylong cl = 0;
        ylong end = lit_end(sg_src, i, &cl);
        if (cl == 0) {
            (void)sg_fail(ys("unterminated string literal"), sg_line, sg_col);
            return n;
        } else {
            (void)sg_out(i, end);
            sg_state = 0;
            return end;
        }
    }
}

/* A block comment: verbatim, comments do not nest, and one that never closes
 * is fatal (the lexer treats it the same way -- the rest of the file would
 * silently disappear). */
static ylong sg_block_comment(ylong i, ylong n) {
    ylong j = i;
    int go = 1;
    int found = 0;
    while (go && j + 1 < n) {
        if (ys_byte_at(sg_src, j) == '*' && ys_byte_at(sg_src, j + 1) == '/') {
            found = 1;
            go = 0;
        } else {
            j = j + 1;
        };
    };
    if (found) {
        (void)sg_out(i, j);
        (void)sg_put1(ys("*"));
        (void)sg_put1(ys("/"));
        sg_state = 0;
        return j + 2;
    } else {
        (void)sg_out(i, n);
        (void)sg_fail(ys("unterminated /* comment"), sg_line, sg_col);
        return n;
    }
}

/* A `//` comment: EVERYTHING to the newline is text, so the interesting bytes
 * in it are not interesting. */
static ylong sg_line_comment(ylong i, ylong n) {
    ylong j = i;
    int go = 1;
    while (go && j < n) {
        if (ys_byte_at(sg_src, j) == 10) { go = 0; } else { j = j + 1; };
    };
    (void)sg_out(i, j);
    sg_state = 0;
    if (j < n) {
        (void)sg_out(j, j + 1);
        sg_bound = 1;
        return j + 1;
    } else {
        return n;
    }
}

/* `#` in code position: `#{` opens a block, anything else is an error. A stray
 * `#` already reaches the lexer as "expected an expression, got '#'"; this is
 * the same refusal with a message that names the construct. */
static ylong sg_hash(ylong j, ylong n) {
    if (j + 1 < n && ys_byte_at(sg_src, j + 1) == '{') {
        return sg_open(j, n);
    } else {
        (void)sg_fail(ys("'#' in code position: a meta block is #{ … }#"), sg_line, sg_col);
        return n;
    }
}

/* `}`: the block's own close when it is followed by `#`, else an ordinary
 * brace. The block's `}` closes no Y brace -- its `{` was never pushed. */
static ylong sg_close_brace(ylong j, ylong n) {
    if (j + 1 < n && ys_byte_at(sg_src, j + 1) == '#') {
        if (sg_depth == 0) {
            (void)sg_stray(j);
            return n;
        } else {
            ylong k = sg_depth - 1;
            ya_set(mg_bok, yv_l(ya_get(sg_bslot, k)), ya_get(sg_bok, k));
            int stmt = yv_truth(ya_get(sg_bstmt, k));
            int ismid = yv_truth(ya_get(sg_bmid, k));
            if (yv_truth(ya_get(sg_bdead, k))) {
                /* inside text that is not compiled: nothing of this block's is in
                 * G, not even a call */
                (void)sg_drop();
            } else if (yv_truth(ya_get(sg_bsplice, k))) {
                /* its text went into the enclosing source; its own bytes are
                 * scanned (for the slots inside) and dropped */
                (void)sg_drop();
            } else if (ismid || sg_depth > 1) {
                /* mid-token, or nested: the call is not here, it is hoisted to the
                 * statement that contains the block */
                (void)sg_m_close(k);
            } else if (yv_truth(ya_get(sg_bhold, k))) {
                /* a top-level block that may hold another block: the call goes
                 * here, and whether the body it wraps is this block's own or a
                 * stand-in is known only now */
                (void)sg_top_close(k);
            } else {
                /* a statement-position call is a statement, and a statement
                 * wants its ';'; in expression position the call is the
                 * expression and a ';' there would be a syntax error */
                (void)sg_gadd(ys("}))"), sg_mmid);
                sg_col = sg_col + 2;
                if (stmt) {
                    (void)sg_gadd(ys(";"), sg_mmid);
                    sg_col = sg_col + 1;
                };
            };
            /* the per-block stacks are popped here, so `sg_depth - 1` is always
             * this block's entry and never one left over from a block that has
             * already closed */
            sg_bstmt = ya_slice(sg_bstmt, 0, yv_len(sg_bstmt) - 1);
            sg_bmid = ya_slice(sg_bmid, 0, yv_len(sg_bmid) - 1);
            sg_bclean = ya_slice(sg_bclean, 0, yv_len(sg_bclean) - 1);
            sg_bbrace = ya_slice(sg_bbrace, 0, yv_len(sg_bbrace) - 1);
            sg_bslot = ya_slice(sg_bslot, 0, yv_len(sg_bslot) - 1);
            sg_bok = ya_slice(sg_bok, 0, yv_len(sg_bok) - 1);
            sg_bsplice = ya_slice(sg_bsplice, 0, yv_len(sg_bsplice) - 1);
            sg_bdead = ya_slice(sg_bdead, 0, yv_len(sg_bdead) - 1);
            sg_bhold = ya_slice(sg_bhold, 0, yv_len(sg_bhold) - 1);
            sg_depth = sg_depth - 1;
            (void)sg_m_live();
            /* A block STATEMENT ends at its own `}#` -- there is no `;` after it
             * to end the region -- so the reduction treats it as a statement that
             * has finished. Not a mid-token one (`def as#{nm}#()` is inside a
             * statement that goes on) and not a block in expression position
             * (`let x = #{ … }#;`): both end at the `;` like any other. */
            if (mg_reduce && sg_depth == 0 && stmt && !ismid &&
                yv_len(sg_bkind) == sg_rbrace) {
                (void)sg_region_close();
            };
            return j + 2;
        }
    } else {
        if (yv_len(sg_bkind) > 0) {
            sg_bkind = ya_slice(sg_bkind, 0, yv_len(sg_bkind) - 1);
        };
        sg_bound = 1;
        (void)sg_put1(ys("}"));
        /* a top-level `}` closes whatever construct it was in, and the next
         * statement starts after it -- and the statement is over for the
         * reduction, since a top-level statement ends at a `;` or at the `}`
         * that closes it */
        if (sg_depth == 0 && sg_mdepth < 1) {
            (void)sg_ts_end();
            if (mg_reduce && yv_len(sg_bkind) == sg_rbrace) {
                (void)sg_region_close();
            };
        };
        return j + 1;
    }
}

/* `{`: remember whether this is a `def` body, a `type` body, or neither.
 * The two are told apart because only `def` marks its body with sg_pending: a
 * `type` header has braces of its own, so sg_in_body has to find its body on
 * the stack. `sg_tkind` is what is currently being declared. */
static ylong sg_open_brace(ylong j, ylong n) {
    if (sg_pending) {
        if (sg_tkind == 2) { sg_bkind = ya_push(sg_bkind, yv_long(2)); }
        else { sg_bkind = ya_push(sg_bkind, yv_long(1)); };
        sg_pending = 0;
    } else {
        sg_bkind = ya_push(sg_bkind, yv_long(0));
    };
    sg_bound = 1;
    (void)sg_put1(ys("{"));
    return sg_word(j + 1, n);
}

/* A slash: a line comment, a block comment, or division. */
static ylong sg_slash(ylong j, ylong n) {
    if (j + 1 < n && ys_byte_at(sg_src, j + 1) == '/') {
        sg_state = 1;
        (void)sg_put1(ys("/"));
        (void)sg_put1(ys("/"));
        return j + 2;
    } else if (j + 1 < n && ys_byte_at(sg_src, j + 1) == '*') {
        sg_state = 2;
        (void)sg_put1(ys("/"));
        (void)sg_put1(ys("*"));
        return j + 2;
    } else {
        (void)sg_put1(ys("/"));
        return j + 1;
    }
}

/* Code position. `sg_bound` says a keyword may start at i. */
static ylong sg_code(ylong i, ylong n) {
    if (sg_bound) {
        sg_bound = 0;
        ylong k = sg_word(i, n);
        if (k > i) { return k; }
    };
    ylong j = sg_next(i, n);
    (void)sg_out(i, j);
    ylong c = 0;
    if (j < n) { c = ys_byte_at(sg_src, j); };
    if (sg_depth > 0 && m_word(c)) {
        /* sg_next stops at a word start inside a block, so this is where a
         * name mid-expression gets read (sg_word emits the word as it goes) */
        return sg_word(j, n);
    } else if (c == 10) {
        sg_bound = 1;
        (void)sg_break();
        return j + 1;
    } else if (c == '"' || c == '\'') {
        /* a literal, taken whole: lit_end has the closing quote, so nothing
         * inside one is a block -- the f-string lowering's `#fmt` is inside a
         * literal in the source too */
        sg_state = 3;
        return j;
    } else if (c == '/') {
        return sg_slash(j, n);
    } else if (c == '{') {
        return sg_open_brace(j, n);
    } else if (c == '}') {
        return sg_close_brace(j, n);
    } else if (c == '#') {
        return sg_hash(j, n);
    } else if (c == ';') {
        sg_pending = 0;
        sg_bound = 1;
        (void)sg_put1(ys(";"));
        /* a top-level `;` ends the statement in progress, so the next one starts
         * after it (see sg_ts_go) and the statement is over for the reduction */
        if (sg_depth == 0 && sg_mdepth < 1) {
            (void)sg_ts_end();
            if (mg_reduce && yv_len(sg_bkind) == sg_rbrace) {
                (void)sg_region_close();
            };
        };
        return j + 1;
    } else {
        return j;
    }
}

/* ── the splice ──────────────────────────────────────────────────────────
 * A block's piece goes at the byte offset recorded when its `#{` was scanned,
 * in the P line recorded then. The line map is rebuilt here, not repaired: a
 * piece is text and may hold any number of newlines, so the lines after it
 * shift by however many it added, and every line the pass generates carries the
 * `#{` line -- which is the honest origin, there being no better one.
 *
 * Split the segments into physical lines: a segment's first part joins the line
 * being built if there is one, every part after the first starts a new line (a
 * newline was crossed), and the last line is flushed at the end.
 *
 * `segp[s]` says whether segment `s` is generated text, and `ngen` gets one
 * entry per line emitted saying whether that line is wholly generated. A line
 * is wholly generated when every segment feeding it is -- which is what lint's
 * "a top-level statement runs twice" check needs to tell the user's own
 * statement from the text a block put there. */
static ylong mg_emit(Yv *segs, Yv *sego, Yv *segp, ylong fid, Yv *nl, Yv *nf,
                    Yv *nll, Yv *ngen) {
    Yv *cur = ys("");
    ylong curo = 0;
    int cgen = 1;
    ylong s = 0;
    while (s < yv_len(segs)) {
        Yv *text = ya_get(segs, s);
        ylong o = yv_l(ya_get(sego, s));
        int p = 0;
        if (s < yv_len(segp)) { p = yv_truth(ya_get(segp, s)); };
        Yv *parts = mg_lines(text);
        ylong k = 0;
        while (k < yv_len(parts)) {
            if (k == 0) {
                /* this part joins the line being built: it is that line's
                 * first text if it is empty, and joins the rest otherwise */
                if (ys_eq_lit(cur, "")) { curo = o; cgen = p; }
                else { cgen = cgen && p; };
            } else {
                nl = ya_push(nl, cur);
                nf = ya_push(nf, yv_long(fid));
                nll = ya_push(nll, yv_long(curo));
                ngen = ya_push(ngen, yv_bool(cgen));
                cur = ys("");
                curo = o;
                cgen = p;
            };
            cur = ys_cat(cur, ya_get(parts, k));
            k = k + 1;
        };
        s = s + 1;
    };
    nl = ya_push(nl, cur);
    nf = ya_push(nf, yv_long(fid));
    nll = ya_push(nll, yv_long(curo));
    ngen = ya_push(ngen, yv_bool(cgen));
    /* The Y twin's `nl`/`nf`/`nll`/`ngen` are rebuilt inside, so the caller
     * reads them back; arrays are reference values here (rule 1), so the pushes
     * above already wrote through them. */
    return 0;
}

/* One line of P, with the pieces of the blocks that stand on it. `at` is the
 * line's index in sg_p and the block table is in the order the scanner found
 * the blocks, so the blocks for this line are the run that starts at the first
 * entry at or after `at` -- the run is skipped to, not merely tested for. */
static ylong mg_splice_line(Yv *line, ylong ol, ylong at, ylong lo, ylong hi,
                           Yv *nl, Yv *nf, Yv *nll, Yv *ngen) {
    Yv *segs = yav(0);
    Yv *sego = yav(0);
    Yv *segp = yav(0);
    ylong prev = 0;
    ylong k = lo;
    while (k < hi && yv_l(ya_get(mg_bp, k)) < at) { k = k + 1; };
    int any = 0;
    while (k < hi && yv_l(ya_get(mg_bp, k)) == at) {
        any = 1;
        ylong o = yv_l(ya_get(mg_bpo, k));
        if (o >= prev && o <= yv_len(line)) {
            segs = ya_push(segs, ys_slice(line, prev, o));
            sego = ya_push(sego, yv_long(ol));
            segp = ya_push(segp, yv_bool(0));
            ylong s = yv_l(ya_get(mg_bslot, k));
            segs = ya_push(segs, ya_get(mg_piece, s));
            sego = ya_push(sego, ya_get(mg_bline, k));
            segp = ya_push(segp, yv_bool(1));
            prev = o;
        };
        k = k + 1;
    };
    if (!any) {
        segs = ya_push(segs, line);
        sego = ya_push(sego, yv_long(ol));
        segp = ya_push(segp, yv_bool(0));
    } else {
        segs = ya_push(segs, ys_slice_from(line, prev));
        sego = ya_push(sego, yv_long(ol));
        segp = ya_push(segp, yv_bool(0));
    };
    return mg_emit(segs, sego, segp, sg_fid, nl, nf, nll, ngen);
}

/* Splice blocks [lo, hi) -- this file's -- into the scanned P. A no-op when the
 * pieces are not known yet (the collecting pass). */
static ylong mg_splice(ylong lo, ylong hi) {
    if (!mg_ready) { return 0; }
    else {
        Yv *lines = sg_p;
        Yv *ols = sg_pol;
        Yv *nl = yav(0);
        Yv *nf = yav(0);
        Yv *nll = yav(0);
        Yv *ngen = yav(0);
        ylong i = 0;
        while (i < yv_len(lines)) {
            (void)mg_splice_line(ya_get(lines, i), yv_l(ya_get(ols, i)), i, lo,
                                 hi, nl, nf, nll, ngen);
            i = i + 1;
        };
        sg_p = nl;
        sg_pf = nf;
        sg_pol = nll;
        sg_gen = ngen;
        return 0;
    }
}

static Yv *meta_scan_end(void) {
    if (ys_eq_lit(sg_err, "") && sg_depth > 0) {
        ylong ln = 1;
        if (mg_first < yv_len(mg_bline)) { ln = yv_l(ya_get(mg_bline, mg_first)); };
        (void)sg_fail(ys("unterminated #{ block: no }# before the end of the file"), ln, 1);
    };
    if (ys_eq_lit(sg_err, "")) {
        sg_p = ya_push(sg_p, sg_pbuf);
        sg_pf = ya_push(sg_pf, yv_long(sg_fid));
        sg_pol = ya_push(sg_pol, yv_long(sg_pline));
        if (sg_mmid) {
            /* a file that ends inside a mid-token block: an error above (the
             * block never closed), so nothing reads these */
            sg_mol = ya_push(sg_mol, yv_long(sg_gline));
            sg_mbuf = ys_cat(sg_mbuf, ys("\n"));
        } else {
            sg_g = ya_push(sg_g, sg_gbuf);
            sg_gf = ya_push(sg_gf, yv_long(sg_fid));
            /* the origin too, so sg_g and sg_gol stay the same length: the
             * hoisted calls below index both */
            sg_gol = ya_push(sg_gol, yv_long(sg_gline));
        };
        (void)sg_mids_move();
        sg_gbuf = ys("");
        sg_mdepth = 0;
        /* this file's G lines go onto the whole program's G, then the scanner
         * starts the next file clean. The Scan still carries this file's own
         * lines: `mg_probe` reads the result, and a caller may too. */
        Yv *mine = sg_g;
        Yv *minef = sg_gf;
        Yv *mineol = sg_gol;
        mg_g = yadd(mg_g, sg_g);
        mg_gol = yadd(mg_gol, sg_gol);
        (void)mg_splice(mg_first, mg_next);
        sg_g = yav(0);
        sg_gf = yav(0);
        sg_gol = yav(0);
        return yr(11, "ok", yv_bool(1), "err", ys(""), "eline", yv_long(0),
                  "ecol", yv_long(0), "p", sg_p, "pf", sg_pf, "pol", sg_pol,
                  "gen", sg_gen, "g", mine, "gf", minef, "gol", mineol);
    } else {
        return scan_bad(sg_err, sg_eline, sg_ecol);
    }
}

/* The scan. One pass over the file's bytes: P and G come out of it as (line,
 * file, source line) triples, and the block table and hoisted imports go into
 * the module-level lists. */
Yv *meta_scan(Yv *src, ylong fid, Yv *dir) {
    if (ys_index_of(src, ys("#")) < 0) {
        return scan_none(src, fid);
    } else {
        (void)sg_reset(src, fid, dir);
        mg_first = mg_next;
        ylong n = yv_len(src);
        ylong i = 0;
        while (i < n && ys_eq_lit(sg_err, "")) {
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
        return meta_scan_end();
    }
}

/* ── the driver ──────────────────────────────────────────────────────────
 * meta_begin/mg_* accumulate across a whole resolve; native.c's
 * meta_run_generator builds G and hands back its text, and mg_take_pieces
 * reads the pieces out of a run. The COMPILE and the RUN are in native.c:
 * they need emit_program and std_units, which live there, and meta.c must not
 * import native.c -- the two name each other's functions, and Y's splicer does
 * not survive a cycle: it dedups on the way down, so the file on the way back
 * up is spliced a second time and every def collides.
 *
 * The pieces come back over the pipe framed as `<slot> <len>\n<body>`, so a
 * piece is matched to its block by SLOT and not by the order the generator
 * happened to evaluate blocks in. That matters: a nested block's text is
 * produced BEFORE its parent's, so source order and execution order differ --
 * which is why the piece table (mg_piece, mg_have) lives up with the scanner's
 * state, which is where it is read.
 */

/* A new PASS over the same files -- and the block table, G's body and the
 * hoisted imports are all per-pass. A block's SLOT is its index in the block
 * table, and the table is rebuilt from scratch each pass, so the second pass
 * over the same files in the same order hands out the SAME slots: that is how
 * a piece the generator wrote is matched to the block that asked for it. The
 * pieces themselves survive -- they are what the second pass splices. */
ylong mg_pass(void) {
    sg_quiet = 0;
    mg_next = 0;
    mg_g = yav(0);
    mg_gol = yav(0);
    mg_bslot = yav(0);
    mg_bfile = yav(0);
    mg_bline = yav(0);
    mg_bp = yav(0);
    mg_bpo = yav(0);
    mg_imp = yav(0);
    mg_iol = yav(0);
    mg_bok = yav(0);
    mg_live = yav(0);
    mg_need = yav(0);
    mg_n = 0;
    mg_nest = 0;
    mg_collect = 0;
    return 0;
}

/* Is any block still without its text? That is the loop condition of the rounds,
 * and it is the same question as "did this round's generator leave a block out
 * of G": a block whose source wanted the text of a nested block inside it cannot
 * produce its own text until it has it, so it is stubbed, runs as a stand-in, and
 * its piece is discarded (mg_take_pieces) -- leaving it here, and so asking for
 * another round. False means every piece is in and the pass is done. */
int mg_pending(void) {
    ylong i = 0;
    int go = 0;
    while (i < mg_next) {
        if (yv_truth(ya_get(mg_need, i)) &&
            (i >= yv_len(mg_have) || !yv_truth(ya_get(mg_have, i)))) { go = 1; };
        i = i + 1;
    };
    return go;
}

ylong meta_begin(void) {
    mg_on = 1;
    mg_ready = 0;
    mg_root = ys("");
    mg_files = yav(0);
    mg_piece = yav(0);
    mg_have = yav(0);
    mg_gbase = ys("");
    mg_gexec = 1;
    mg_pkgs = yav(0);
    mg_roots = yav(0);
    /* mg_bkids is NOT reset here: it is structural, so every pass learns the same
     * thing from it (sg_open) -- which is what makes it usable at the `#{`, before
     * the children have been seen. Only the FIRST pass is the collecting one, and
     * only meta_begin says so. */
    mg_bkids = yav(0);
    mg_reduce = 0;
    (void)mg_pass();
    mg_collect = 1;
    return 0;
}

/* The reduction, turned on once a pass has found nesting. The collecting pass
 * never turns it on: it does not know yet, and a program with no nesting must
 * compile to exactly what it always did. */
ylong mg_reduce_on(void) {
    mg_reduce = 1;
    return 0;
}

/* native.c hands the generator its resolution over this, because
 * `meta.<field> = v` is a namespaced field ASSIGNMENT and strip_ns rewrites
 * only namespaced dot READS (it handles K.dot, not K.dotassign -- see
 * strip_ns), so a module cannot set another module's global by name. */
ylong mg_setup(Yv *root, Yv *files, Yv *base, int exec, Yv *pkgs, Yv *roots) {
    mg_root = root;
    mg_files = files;
    mg_gbase = base;
    mg_gexec = exec;
    mg_pkgs = pkgs;
    mg_roots = roots;
    return 0;
}

/* The pass is off for the generator's own compile: G is ordinary Y, and
 * anything a generator emits is never re-scanned, so nothing in it can open a
 * block. This is what makes "a block's output may not contain a block" true by
 * construction rather than by checking. */
ylong mg_set(int on) {
    mg_on = on;
    return 0;
}

/* (meta.y keeps mg_in: a Y module-level def the checker never calls is not a
 * warning, a C `static` one is.) */
int mg_in(Yv *xs, Yv *s) {
    int hit = 0;
    ylong i = 0;
    while (i < yv_len(xs)) {
        if (ys_eq(ya_get(xs, i), s)) { hit = 1; };
        i = i + 1;
    };
    return hit;
}

/* A fatal pass-level diagnostic. Every leak path out of the pass is one of
 * these, never a hand-off to the lexer (see the spec's invariant 1): whatever
 * `#{` the scanner was meant to catch is caught here, with its line. */
ylong mg_report(Yv *msg) {
    puts_(ys_cat(ys("error: "), ys_cat(msg, ys("\n"))));
    exit_(1);
    return 0;
}

/* The helpers G carries, and the one they share. `y_`-prefixed, so a module
 * imported into the generator namespaces its own names (rename.c) and cannot
 * collide with them; the program's own flat top level can, and that is
 * mg_reserved's diagnostic.
 *
 * Each writes its piece to fd 3 framed as `<slot> <len>\n<body>`, which is what
 * lets the parent read a piece back in any order and with any bytes in it --
 * including newlines, which most of them have. */
static Yv *mg_helpers(void) {
    return yav(16,
        ys("def ycc_meta_emit(slot: long, body: str) -> void {"),
        ys("    let h = tostring(slot) + \" \" + tostring(len(body)) + \"\\n\";"),
        ys("    let hb = bytes(h);"),
        ys("    syscall(1, 3, &hb[0], len(hb));"),
        ys("    let b = bytes(body);"),
        ys("    if (len(b) > 0) { syscall(1, 3, &b[0], len(b)); 0; };"),
        ys("    0"),
        ys("};"),
        ys("def ycc_meta_expr(slot: long, body: str) -> str {"),
        ys("    ycc_meta_emit(slot, body);"),
        ys("    body"),
        ys("};"),
        ys("def ycc_meta_stmt(slot: long, body: str) -> void {"),
        ys("    ycc_meta_emit(slot, body);"),
        ys("    0"),
        ys("};"));
}

/* G's text: the helpers, then the hoisted imports, then the files' own lines
 * with each block as a call. The imports go after the helpers and before the
 * body, so a hoisted module's own statements see the helpers. */
Yv *meta_gtext(void) {
    Yv *out = yav(0);
    Yv *hs = mg_helpers();
    ylong i = 0;
    while (i < yv_len(hs)) {
        out = ya_push(out, ya_get(hs, i));
        i = i + 1;
    };
    ylong k = 0;
    while (k < yv_len(mg_imp)) {
        out = ya_push(out, ya_get(mg_imp, k));
        k = k + 1;
    };
    out = yadd(out, mg_g);
    return ys_cat(ys_join(out, ys("\n")), ys("\n"));
}

/* How many lines of G's origin map are the helpers and the hoisted imports:
 * the generator's body starts here, so a line index has to know. */
ylong mg_ghead(void) {
    return yv_len(mg_helpers()) + yv_len(mg_imp);
}

/* How many lines the generator's body is: the files' own lines, one for one. */
ylong mg_glines(void) {
    return yv_len(mg_g);
}

/* Where the block that holds slot `s` stands, as `file:line`. */
static Yv *mg_where(ylong s) {
    ylong k = 0;
    ylong ln = 0;
    ylong f = 0;
    while (k < yv_len(mg_bslot)) {
        if (yv_l(ya_get(mg_bslot, k)) == s) {
            ln = yv_l(ya_get(mg_bline, k));
            f = yv_l(ya_get(mg_bfile, k));
        };
        k = k + 1;
    };
    Yv *path = mg_root;
    if (f < yv_len(mg_files)) { path = ya_get(mg_files, f); };
    return ys_cat(ys_cat(path, ys(":")), ys_tostring(yv_long(ln)));
}

/* ── the piece table ───────────────────────────────────────────────────── */

/* Split the pipe's bytes into pieces. A framing error means the generator did
 * not run our helpers, which cannot happen unless the pass is broken. */
static ylong mg_unframe(Yv *data) {
    ylong n = yv_len(data);
    ylong i = 0;
    int bad = 0;
    while (i < n && !bad) {
        ylong j = i;
        int go = 1;
        while (go && j < n && ys_byte_at(data, j) != 10) { j = j + 1; };
        if (j >= n) {
            bad = 1;
        } else {
            Yv *head = ys_slice(data, i, j);
            ylong sp = ys_index_of(head, ys(" "));
            if (sp < 0) {
                bad = 1;
            } else {
                ylong slot = ys_tolong(ys_slice(head, 0, sp));
                ylong take = ys_tolong(ys_slice_from(head, sp + 1));
                Yv *body = ys_slice(data, j + 1, j + 1 + take);
                if (take < 0 || yv_len(body) != take || slot < 0 || slot >= mg_next) {
                    bad = 1;
                } else {
                    /* the tables start empty and a piece may arrive in any
                     * order, so they grow to the slot it names */
                    while (yv_len(mg_piece) <= slot) {
                        mg_piece = ya_push(mg_piece, ys(""));
                        mg_have = ya_push(mg_have, yv_bool(0));
                    };
                    ya_set(mg_piece, slot, body);
                    ya_set(mg_have, slot, yv_bool(1));
                    i = j + 1 + take;
                };
            };
        };
    };
    if (bad) {
        (void)mg_report(ys("the meta generator wrote a malformed piece to fd 3 (this is the pass's own framing, so it is a bug)"));
        return 1;
    } else {
        return 0;
    }
}

/* The first slot with no piece, or -1. A block at the top level always runs
 * (the top level IS the generator's program), so a gap means the generator
 * did not reach it -- and the message can name it. */
static ylong mg_first_missing(void) {
    ylong at = -1;
    ylong i = 0;
    while (i < mg_next) {
        if (!yv_truth(ya_get(mg_have, i))) { at = i; };
        i = i + 1;
    };
    return at;
}

/* ", and the first block that produced nothing was at ..." when there is one. */
static Yv *mg_blame(void) {
    ylong m = mg_first_missing();
    if (m < 0) { return ys(""); }
    else {
        return ys_cat(ys(", and the first block that produced nothing was at "),
                      mg_where(m));
    }
}

/* The checks a piece must pass before it is spliced into the program's
 * source. Each names the block, because "the generator emitted something bad"
 * is not a message a reader can act on. */
ylong mg_check(ylong s) {
    Yv *p = ys("");
    if (s < yv_len(mg_piece)) { p = ya_get(mg_piece, s); };
    if (ys_index_of(p, ys("#{")) >= 0) {
        (void)mg_report(scat3(ys("the block at "), mg_where(s),
            ys(" emitted a #{ … }# block: generated text is never re-scanned, so a block cannot emit one")));
    };
    if (ys_index_of(p, ys("\x00")) >= 0) {
        (void)mg_report(scat3(ys("the block at "), mg_where(s),
            ys(" emitted a NUL byte, which cannot be in a source file")));
    };
    return 0;
}

/* Read back what a run produced: check the child's fate, unframe, check every
 * piece, and report the first thing that is wrong. Returns false if the
 * generator died, having said as much as can be said. */
int mg_take_pieces(ylong status, ylong sig, Yv *out) {
    int r = 1;
    /* sized FIRST: mg_blame asks which slots have no piece, so a generator
     * that died before writing anything must still leave the tables the right
     * length (mg_unframe only grows them for the slots a piece names) */
    while (yv_len(mg_piece) < mg_next) {
        mg_piece = ya_push(mg_piece, ys(""));
        mg_have = ya_push(mg_have, yv_bool(0));
    };
    if (sig > 0) {
        (void)mg_report(ys_cat(scat3(ys("the meta generator died on signal "),
                                     ys_tostring(yv_long(sig)), ys("")),
                                mg_blame()));
    };
    if (status != 0) {
        (void)mg_report(ys_cat(scat3(ys("the meta generator exited "),
                                     ys_tostring(yv_long(status)), ys("")),
                                mg_blame()));
    };
    if (yv_len(out) > MG_MAX) {
        (void)mg_report(scat3(ys("the meta generator emitted more than "),
                              ys_tostring(yv_long(MG_MAX)), ys(" bytes")));
    };
    (void)mg_unframe(from_bytes(out));
    /* A block that could not produce its text this round ran something whose
     * output is not its text -- a stand-in with the body `0`. Throw those away
     * first, so what is left in the table is this block's real text and nothing
     * downstream can mistake the rest for it. mg_pending is what asks for the
     * next round. */
    (void)mg_commit();
    ylong i = 0;
    while (i < mg_next) {
        /* A block that ran for real owes the table a piece, and one that did not
         * run does not: a nested block whose text was spliced into the block
         * around it already has its piece from the round that produced it. */
        if (yv_truth(ya_get(mg_live, i)) && yv_truth(ya_get(mg_bok, i)) &&
            !yv_truth(ya_get(mg_have, i))) {
            (void)mg_report(scat3(ys("the block at "), mg_where(i),
                ys(" produced no output: every meta block runs once, in the generator's top level, so reaching it is not optional")));
        };
        (void)mg_check(i);
        i = i + 1;
    };
    mg_ready = 1;
    return r;
}

/* Keep only the pieces that are really this block's text. A block that could not
 * produce its text this round ran a stand-in (sg_top_close) whose piece is "0";
 * it has to keep waiting (mg_pending), and so does everything around it.
 *
 * The rest is already true of the table mg_unframe writes: a piece is marked
 * present only when it is framed, so a slot holding its piece from an earlier
 * round is not disturbed by a round that stubbed the block. */
static ylong mg_commit(void) {
    ylong i = 0;
    while (i < mg_next) {
        if (i < yv_len(mg_have) && yv_truth(ya_get(mg_have, i)) &&
            !yv_truth(ya_get(mg_bok, i))) {
            ya_set(mg_have, i, yv_bool(0));
            ya_set(mg_piece, i, ys(""));
        };
        i = i + 1;
    };
    return 0;
}

/* A `#{` in the text the generator resolved -- which is to say in a module the
 * generator imported. G is compiled with the pass off, so such a block would
 * arrive at the lexer as a bare `#`, and "expected an expression, got '#'" is
 * not a message anyone can act on. Probed with the real scanner, with the
 * block table saved and put back, so the probe cannot perturb the program's
 * own pass. */
int mg_probe(Yv *src, Yv *dir) {
    ylong n = mg_next;
    Yv *bs = mg_bslot;
    Yv *bf = mg_bfile;
    Yv *bl = mg_bline;
    Yv *bp = mg_bp;
    Yv *bo = mg_bpo;
    ylong bn = mg_nest;
    Yv *bok = mg_bok;
    Yv *bli = mg_live;
    Yv *bne = mg_need;
    ylong gn = mg_n;
    ylong gi = yv_len(mg_imp);
    ylong gl = yv_len(mg_g);
    int was_quiet = sg_quiet;
    sg_quiet = 1;
    (void)meta_scan(src, 0, dir);
    sg_quiet = was_quiet;
    int hit = mg_n > gn;
    mg_next = n;
    mg_bslot = bs;
    mg_bfile = bf;
    mg_bline = bl;
    mg_bp = bp;
    mg_bpo = bo;
    mg_nest = bn;
    mg_bok = bok;
    mg_live = bli;
    mg_need = bne;
    mg_n = gn;
    mg_imp = ya_slice(mg_imp, 0, gi);
    mg_iol = ya_slice(mg_iol, 0, gi);
    mg_g = ya_slice(mg_g, 0, gl);
    mg_gol = ya_slice(mg_gol, 0, gl);
    return hit;
}