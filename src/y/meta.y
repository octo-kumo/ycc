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

// ── little-endian reads and writes ──────────────────────────────────────

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
def pipe_fds() -> { ok: bool, rfd: long, wfd: long } {
    let pf: [byte; 8] = [0; 8];
    if (syscall(SYS_PIPE, &pf[0], ptr_addr(&pf[0]) + 4, 0, 0, 0) != 0) {
        { ok: false, rfd: 0 - 1, wfd: 0 - 1 }
    } else {
        { ok: true, rfd: rd32(pf[0:8], 0), wfd: rd32(pf[0:8], 4) }
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
    run_image_fork(stk[0:131072], sp, m2)
};

// SIGCHLD, no CLONE_VM: a separate process with a copy-on-write copy of our
// address space, reaped by wait4 -- the fork the whole design rests on. The
// child comes back from the syscall with %rax = 0 and %rsp = `sp`, still
// running THIS code, one instruction later; `jmp_at` then hands it to the
// image with %rsp exactly where fab_stack put it.
def run_image_fork(stk: [byte], sp: long, m: Mapd) -> RunRes {
    let pid = syscall(SYS_CLONE, SIGCHLD, sp, 0, 0, 0);
    if (pid <= 0) {
        // The child: never returns.
        jmp_at(m.img + m.entry);
        map_release(m);
        run_fail("the image's entry point returned")
    } else {
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

// `ycc -E`: the resolved text, each line tagged with the file and line it
// came from. The tag is a trailing comment on the FIRST line of each run of
// lines from one file, so line numbers survive the round trip and the markers
// do not move anything: comments never reach the lexer, so compiling a dump
// gives the same bytes as compiling the file it came from.
def meta_dump(src: str, origin: Origin) -> long {
    let lines = split(src, "\n");
    let prev = "\x01none";
    let i = 0;
    while (i < len(lines)) {
        let l = lines[i];
        let at = nativelib.origin_at(origin, i + 1, false);
        if (at == prev) {
            puts(l + "\n");
        } else {
            puts(l + "\t// " + at + "\n");
            prev = at;
        };
        i = i + 1;
    };
    0
};

export { run_image, RunRes, Img, elf_img, meta_dump };