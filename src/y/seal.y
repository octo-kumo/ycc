// seal.y -- the plaintext bootstrap page and the image cipher.
//
// A sealed ELF starts at y_obf_start, a page-aligned stub that is never
// encrypted. The stub unseals [y_obf_clear_end, y_obf_image_end) -- every
// byte of code after the stub and all of .rodata -- either at startup
// ("seal") or one page at a time on SIGSEGV ("full").
//
// The cipher is a per-build, page-keyed byte stream. The recipe (mix
// multipliers, shifts, stream constants and a one- or two-key mode) is derived
// from the stream key, so two builds do not share a cipher shape; byte i uses a
// key derived from its 4 KiB page and its offset in that page, so a stream
// recovered from one page says nothing about the next. It is O(1)-seekable:
// the page handler starts at an arbitrary byte without replaying the stream.

import wintgt from "./target.y";
let GOLDEN = 0x9E3779B97F4A7C15;
let MIX1 = 0xBF58476D1CE4E5B9;
let MIX2 = 0x94D049BB133111EB;
// The first eight bytes of .rodata are a key check, not program data.
let MAGIC = 0x594F42464D414749;
// Domain separated from the image hash: page MACs and the file hash must not
// be the same function of one key.
const MAC_DOMAIN = 0x504147454D4143;
let HASH_DOMAIN = 0x594F424648415348;

// splitmix64's finalizer, without the state increment: one round for one
// word. The stub's assembly is this function, instruction for instruction.
def mix_final(x: long) -> long {
    let z = x;
    z = (z ^ (z >>> 30)) * MIX1;
    z = (z ^ (z >>> 27)) * MIX2;
    z ^ (z >>> 31)
};

// A per-build recipe derived from the stream key. The loader emits these
// constants, so two builds do not share a cipher shape; the page key means a
// stream recovered from one page says nothing about the next.
type Recipe = { cpage: long, golden: long, golden2: long, mix1: long, mix2: long,
    s1: long, s2: long, s3: long, mode: long };

def recipe(key: long) -> Recipe {
    let h = mix_final(key ^ 0x9E3779B97F4A7C15);
    let cpage = mix_final(h ^ 0x243F6A8885A308D3) | 1;
    let golden = mix_final(h ^ 0x13198A2E03707344) | 1;
    let golden2 = mix_final(h ^ 0xA4093822299F31D0) | 1;
    let mix1 = mix_final(h ^ 0x082EFA98EC4E6C89) | 1;
    let mix2 = mix_final(h ^ 0x452821E638D01377) | 1;
    let s1 = 1 + ((h >>> 4) % 62);
    let s2 = 1 + ((h >>> 11) % 62);
    let s3 = 1 + ((h >>> 18) % 62);
    { cpage: cpage, golden: golden, golden2: golden2, mix1: mix1,
        mix2: mix2, s1: s1, s2: s2, s3: s3, mode: h & 1 }
};

def mix_rec(x: long, r: Recipe) -> long {
    let z = x;
    z = (z ^ (z >>> r.s1)) * r.mix1;
    z = (z ^ (z >>> r.s2)) * r.mix2;
    z ^ (z >>> r.s3)
};

def page_key(key: long, page: long, r: Recipe) -> long {
    mix_rec(key ^ ((page + 1) * r.cpage), r) | 1
};

def stream_byte(key: long, idx: long, r: Recipe) -> long {
    let page = idx >>> 12;
    let po = idx & 4095;
    let pk = page_key(key, page, r) | 1;
    // The page key also chooses this page's stream constants and whether the
    // second term contributes, so two pages do not share a cipher shape.
    let gp = mix_rec(pk ^ r.golden, r) | 1;
    let gp2 = mix_rec(pk ^ r.golden2, r) | 1;
    let a = mix_rec(pk + po * gp, r);
    let pk2 = mix_rec(pk ^ r.cpage, r) | 1;
    let b = mix_rec(pk2 + po * gp2, r);
    let mask = 0;
    if (((pk ^ page) & 1) != 0) { mask = -1; };
    (a ^ (b & mask)) & 255
};

// `n` bytes at `off`, xored with the page-keyed stream starting at index
// `first`. A byte per round is slower than a word, but it makes the sealed
// range start wherever the assembler put the label: no alignment contract.
def crypt_range(buf: [byte], off: long, n: long, key: long, first: long,
        r: Recipe) -> void {
    let i = 0;
    while (i < n) {
        let idx = first + i;
        let b: long = buf[off + i];
        buf[off + i] = b ^ stream_byte(key, idx, r);
        i += 1;
    };
};

// A keyed hash over the ciphertext of the sealed range. It is checked before
// the first byte is decrypted, so a patched file page is a clean failure
// rather than a page of garbage. The build folds `code` and `rodata` into one
// buffer because that is how the loader sees them (code, then rodata).
def hash_image(key: long, b: [byte], off: long, n: long) -> long {
    let h = mix_final(key ^ HASH_DOMAIN) | 1;
    let i = 0;
    while (i + 8 <= n) {
        let w = 0;
        let k = 0;
        while (k < 8) {
            w |= (b[off + i + k] & 255) << (8 * k);
            k += 1;
        };
        h = mix_final(h ^ w);
        i += 8;
    };
    // Always fold the tail word, even when it is empty: the loader does the
    // same, so a length that is a multiple of eight matches.
    let w = 0;
    let k = 0;
    while (i + k < n) {
        w |= (b[off + i + k] & 255) << (8 * k);
        k += 1;
    };
    h = mix_final(h ^ w ^ (k << 56));
    h
};

// The external key file is sixteen bytes; its two little-endian words are
// folded into the stream key. The same fold is in the stub.
def key_from_bytes(b: [byte]) -> long {
    if (len(b) < 16) {
        0
    } else {
        let k = 0;
        let i = 0;
        while (i < 8) { k |= b[i] << (8 * i); i += 1; };
        i = 0;
        while (i < 8) { k ^= b[8 + i] << (8 * i); i += 1; };
        if (k == 0) { 1 } else { k }
    }
};

// Random bytes behind a jump, and a branch on the incoming scratch value,
// both in the plaintext loader. Neither changes what the loader does; a
// linear disassembler sees more code and a reader has to decide the branch.
def loader_bytes(key: long) -> str {
    let h = mix_final(key ^ 0x6C6F61646572);
    let n = 12 + (h % 52);
    let parts: [str] = [];
    let i = 0;
    let x = h;
    while (i < n) {
        x = mix_final(x + 0x9E3779B97F4A7C15);
        parts += tostring(x & 255);
        i += 1;
    };
    "    jmp y_obf_lj_end\ny_obf_lj:\n    .byte " + join(parts, ",") +
        "\ny_obf_lj_end:\n"
};

def loader_guard(key: long) -> str {
    let h = mix_final(key ^ 0x6775617264);
    let mask = 1 + 2 * (h % 8);
    let skip = "y_obf_lg_skip";
    "    test $" + tostring(mask) + ", %r11\n" +
    "    jz " + skip + "\n" +
    "    mov $" + tostring(h) + ", %r9\n" +
    "    add $" + tostring(mix_final(h) & 0xFFFF) + ", %r9\n" +
    "    xor $" + tostring(mix_final(h ^ 1) & 0xFFFF) + ", %r9\n" +
    skip + ":\n"
};

// Four mov/xor shares instead of one readable literal. The stub needs the
// key, not a single immediate; an external key file loads it from .bss.
def key_text(key: long, key_file: str) -> str {
    if (len(key_file) > 0) {
        "    mov y_obf_key(%rip), %rcx\n"
    } else {
        let a = mix_final(key ^ 0x243F6A8885A308D3);
        let b = mix_final(a ^ 0x13198A2E03707344);
        let c = mix_final(b ^ 0xA4093822299F31D0);
        let d = key ^ a ^ b ^ c;
        let sh: [long] = [a, b, c, d];
        let h = mix_final(key ^ 0x7368617265);
        let i = 3;
        while (i > 0) {
            let j = (mix_final(h + i) >>> 1) % (i + 1);
            let t = sh[i];
            sh[i] = sh[j];
            sh[j] = t;
            i -= 1;
        };
        let out = "    mov $" + tostring(sh[0]) + ", %rcx\n";
        let k = 1;
        while (k < 4) {
            out += "    mov $" + tostring(sh[k]) + ", %rdx\n" +
                "    xor %rdx, %rcx\n";
            if (k == 2) {
                out += "    mov $" + tostring(mix_final(h) & 0xFFFF) + ", %r9\n";
            };
            k += 1;
        };
        out
    }
};

// The first eight bytes of .rodata are a key check, not program data. The
// value is derived from the stream key, so it is per-build (a fixed literal
// here would be a signature and a known plaintext).
def canary(key: long) -> long {
    mix_final(key ^ MAGIC) | 1
};

def magic_text(key: long) -> str {
    let v = canary(key);
    let out = ".section .rodata\ny_obf_magic:\n";
    let i = 0;
    while (i < 8) {
        out += "    .byte " + tostring((v >>> (8 * i)) & 255) + "\n";
        i += 1;
    };
    out
};

def magic_check_text(key: long) -> str {
    "    lea y_obf_magic(%rip), %rax\n" +
    "    mov (%rax), %rax\n" +
    "    mov $" + tostring(canary(key)) + ", %rdx\n" +
    "    cmp %rdx, %rax\n" +
    "    jne y_obf_fail\n"
};

def path_text(p: str, k: long) -> str {
    let out = "";
    let i = 0;
    while (i < len(p)) {
        out += "    .byte " + tostring((p[i] ^ (k & 255) ^ i) & 255) + "\n";
        i += 1;
    };
    out + "    .byte 0\n"
};

// PR_SET_DUMPABLE keeps a core or a /proc/self/mem read away. Bulk mode can
// also call PTRACE_TRACEME: if a debugger already owns the process the call
// fails and the loader exits before _start. Full mode must not become a
// tracee, because the lazy SIGSEGV would then be delivered to the tracer; it
// reads TracerPid from /proc/self/status instead, which detects an attached
// debugger without changing the tracing state.
def dumpable_text() -> str {
    "    mov $157, %rax\n    mov $4, %rdi\n" +
    "    xor %rsi, %rsi\n    xor %rdx, %rdx\n" +
    "    xor %r10, %r10\n    syscall\n" +
    "    test %rax, %rax\n    js y_obf_fail\n"
};

def tracer_check_text() -> str {
    "    mov $-100, %rdi\n" +
    "    lea y_obf_status(%rip), %rsi\n" +
    "    xor %rdx, %rdx\n    xor %r10, %r10\n" +
    "    mov $257, %rax\n    syscall\n" +
    "    test %rax, %rax\n    js y_obf_fail\n" +
    "    mov %rax, %rdi\n" +
    "    lea y_obf_procbuf(%rip), %rsi\n" +
    "    mov $1024, %rdx\n" +
    "    xor %rax, %rax\n    syscall\n" +
    "    test %rax, %rax\n    jle y_obf_fail\n" +
    "    mov %rax, %r15\n" +
    "    mov $3, %rax\n    syscall\n" +
    "    lea y_obf_procbuf(%rip), %rsi\n" +
    "    xor %rdx, %rdx\n" +
    "y_obf_tr_scan:\n" +
    "    lea 10(%rdx), %rax\n" +
    "    cmp %r15, %rax\n" +
    "    ja y_obf_fail\n" +
    "    movzbq (%rsi,%rdx), %rax\n" +
    "    cmp $84, %rax\n    jne y_obf_tr_next\n" +
    "    movzbq 1(%rsi,%rdx), %rax\n" +
    "    cmp $114, %rax\n    jne y_obf_tr_next\n" +
    "    movzbq 2(%rsi,%rdx), %rax\n" +
    "    cmp $97, %rax\n    jne y_obf_tr_next\n" +
    "    movzbq 3(%rsi,%rdx), %rax\n" +
    "    cmp $99, %rax\n    jne y_obf_tr_next\n" +
    "    movzbq 4(%rsi,%rdx), %rax\n" +
    "    cmp $101, %rax\n    jne y_obf_tr_next\n" +
    "    movzbq 5(%rsi,%rdx), %rax\n" +
    "    cmp $114, %rax\n    jne y_obf_tr_next\n" +
    "    movzbq 6(%rsi,%rdx), %rax\n" +
    "    cmp $80, %rax\n    jne y_obf_tr_next\n" +
    "    movzbq 7(%rsi,%rdx), %rax\n" +
    "    cmp $105, %rax\n    jne y_obf_tr_next\n" +
    "    movzbq 8(%rsi,%rdx), %rax\n" +
    "    cmp $100, %rax\n    jne y_obf_tr_next\n" +
    "    movzbq 9(%rsi,%rdx), %rax\n" +
    "    cmp $58, %rax\n    jne y_obf_tr_next\n" +
    "    add $10, %rdx\n" +
    "y_obf_tr_skip:\n" +
    "    movzbq (%rsi,%rdx), %rax\n" +
    "    cmp $32, %rax\n    je y_obf_tr_space\n" +
    "    cmp $9, %rax\n    jne y_obf_tr_digit\n" +
    "y_obf_tr_space:\n" +
    "    add $1, %rdx\n    jmp y_obf_tr_skip\n" +
    "y_obf_tr_digit:\n" +
    "    cmp $48, %rax\n    jne y_obf_fail\n" +
    "    movzbq 1(%rsi,%rdx), %rax\n" +
    "    cmp $48, %rax\n    jb y_obf_ok\n" +
    "    cmp $57, %rax\n    jbe y_obf_fail\n" +
    "    jmp y_obf_ok\n" +
    "y_obf_tr_next:\n" +
    "    add $1, %rdx\n    jmp y_obf_tr_scan\n" +
    "y_obf_ok:\n"
};

def guard_text(anti_debug: bool, lazy: bool) -> str {
    if (!anti_debug) {
        ""
    } else if (lazy) {
        tracer_check_text() + dumpable_text()
    } else {
        "    xor %rdi, %rdi\n    xor %rsi, %rsi\n" +
        "    xor %rdx, %rdx\n    xor %r10, %r10\n" +
        "    mov $101, %rax\n    syscall\n" +
        "    test %rax, %rax\n    js y_obf_fail\n" +
        dumpable_text()
    }
};

def status_text() -> str {
    let p = "/proc/self/status";
    let out = "y_obf_status:\n";
    let i = 0;
    while (i < len(p)) {
        out += "    .byte " + tostring(p[i]) + "\n";
        i += 1;
    };
    out + "    .byte 0\n"
};

def read_call_text(key_file: str, key_fd: long) -> str {
    if (key_fd >= 0) { "    call y_obf_readkey\n" }
    else if (len(key_file) == 0) { "" }
    else { "    call y_obf_readkey\n" }
};

// The file's bytes are no longer needed once the key is folded; wipe them and
// ask the kernel to keep the key page out of a core. mlock may fail (no
// CAP_IPC_LOCK), so its result is deliberately ignored.
def key_wipe_text() -> str {
    "    xor %rax, %rax\n" +
    "    mov %rax, y_obf_keybuf(%rip)\n" +
    "    mov %rax, y_obf_keybuf+8(%rip)\n" +
    "    mov %rax, y_obf_keybuf+16(%rip)\n" +
    "    mov %rax, y_obf_keybuf+24(%rip)\n" +
    "    mov $149, %rax\n" +
    "    lea y_obf_key(%rip), %rdi\n" +
    "    and $-4096, %rdi\n" +
    "    mov $4096, %rsi\n" +
    "    syscall\n"
};

def readkey_text(key_file: str, key_fd: long, path_key: long) -> str {
    if (key_fd >= 0) {
        "y_obf_readkey:\n" +
        "    mov $" + tostring(key_fd) + ", %rdi\n" +
        "    xor %r15, %r15\n" +
        "y_obf_kread:\n" +
        "    lea y_obf_keybuf(%rip), %rsi\n" +
        "    add %r15, %rsi\n" +
        "    mov $16, %rdx\n" +
        "    sub %r15, %rdx\n" +
        "    xor %rax, %rax\n    syscall\n" +
        "    test %rax, %rax\n    jle y_obf_fail\n" +
        "    add %rax, %r15\n" +
        "    cmp $16, %r15\n    jl y_obf_kread\n" +
        "    mov $3, %rax\n    syscall\n" +
        "    lea y_obf_keybuf(%rip), %rsi\n" +
        "    mov (%rsi), %rax\n" +
        "    mov 8(%rsi), %rdx\n" +
        "    xor %rdx, %rax\n" +
        "    test %rax, %rax\n    jnz y_obf_kok\n" +
        "    mov $1, %rax\n" +
        "y_obf_kok:\n" +
        "    mov %rax, y_obf_key(%rip)\n" +
        key_wipe_text() +
        "    ret\n"
    } else if (len(key_file) == 0) {
        ""
    } else {
        "y_obf_readkey:\n" +
        "    lea y_obf_keypath(%rip), %rsi\n" +
        "    lea y_obf_pathbuf(%rip), %rdi\n" +
        "    mov $" + tostring(len(key_file)) + ", %rcx\n" +
        "    mov $" + tostring(path_key & 255) + ", %r10\n" +
        "    xor %rdx, %rdx\n" +
        "y_obf_kpath:\n" +
        "    movzbq (%rsi,%rdx), %rax\n" +
        "    xor %r10, %rax\n" +
        "    xor %rdx, %rax\n" +
        "    movb %al, (%rdi,%rdx)\n" +
        "    add $1, %rdx\n" +
        "    cmp %rcx, %rdx\n" +
        "    jl y_obf_kpath\n" +
        "    movb $0, (%rdi,%rcx)\n" +
        "    lea y_obf_pathbuf(%rip), %rsi\n" +
        "    mov $-100, %rdi\n" +
        "    xor %rdx, %rdx\n" +
        "    xor %r10, %r10\n" +
        "    mov $257, %rax\n    syscall\n" +
        "    test %rax, %rax\n    js y_obf_fail\n" +
        "    mov %rax, %rdi\n" +
        "    xor %r15, %r15\n" +
        "y_obf_kread:\n" +
        "    lea y_obf_keybuf(%rip), %rsi\n" +
        "    add %r15, %rsi\n" +
        "    mov $16, %rdx\n" +
        "    sub %r15, %rdx\n" +
        "    xor %rax, %rax\n    syscall\n" +
        "    test %rax, %rax\n    jle y_obf_fail\n" +
        "    add %rax, %r15\n" +
        "    cmp $16, %r15\n    jl y_obf_kread\n" +
        "    mov $3, %rax\n    syscall\n" +
        "    lea y_obf_keybuf(%rip), %rsi\n" +
        "    mov (%rsi), %rax\n" +
        "    mov 8(%rsi), %rdx\n" +
        "    xor %rdx, %rax\n" +
        "    test %rax, %rax\n    jnz y_obf_kok\n" +
        "    mov $1, %rax\n" +
        "y_obf_kok:\n" +
        "    mov %rax, y_obf_key(%rip)\n" +
        key_wipe_text() +
        "    ret\n" +
        "y_obf_keypath:\n" + path_text(key_file, path_key)
    }
};

def mix_reg(reg: str, r: Recipe) -> str {
    "    mov " + reg + ", %r9\n" +
    "    shr $" + tostring(r.s1) + ", %r9\n" +
    "    xor %r9, " + reg + "\n" +
    "    mov $" + tostring(r.mix1) + ", %r9\n" +
    "    imul %r9, " + reg + "\n" +
    "    mov " + reg + ", %r9\n" +
    "    shr $" + tostring(r.s2) + ", %r9\n" +
    "    xor %r9, " + reg + "\n" +
    "    mov $" + tostring(r.mix2) + ", %r9\n" +
    "    imul %r9, " + reg + "\n" +
    "    mov " + reg + ", %r9\n" +
    "    shr $" + tostring(r.s3) + ", %r9\n" +
    "    xor %r9, " + reg + "\n"
};

def dec_text(r: Recipe) -> str {
    // Per byte: form the page key, derive this page's stream constants and
    // mask, then xor. The signal restorer rebuilds the interrupted context,
    // and the lazy handler keeps no state in these registers. %r15 is a
    // scratch.
    "y_obf_dec:\n" +
    "    cmp %rsi, %rdi\n" +
    "    jae y_obf_dec_done\n" +
    "y_obf_dec_loop:\n" +
    // page key in %rax
    "    mov %r8, %rax\n" +
    "    shr $12, %rax\n" +
    "    add $1, %rax\n" +
    "    mov $" + tostring(r.cpage) + ", %r9\n" +
    "    imul %r9, %rax\n" +
    "    xor %rcx, %rax\n" +
    mix_reg("%rax", r) +
    "    or $1, %rax\n" +
    // gp in %r10
    "    mov %rax, %r10\n" +
    "    mov $" + tostring(r.golden) + ", %r9\n" +
    "    xor %r9, %r10\n" +
    mix_reg("%r10", r) +
    "    or $1, %r10\n" +
    // a in %rdx
    "    mov %r8, %rdx\n" +
    "    and $4095, %rdx\n" +
    "    imul %r10, %rdx\n" +
    "    add %rax, %rdx\n" +
    mix_reg("%rdx", r) +
    // pk2 in %r10
    "    mov %rax, %r10\n" +
    "    mov $" + tostring(r.cpage) + ", %r9\n" +
    "    xor %r9, %r10\n" +
    mix_reg("%r10", r) +
    "    or $1, %r10\n" +
    // gp2 in %r11
    "    mov %rax, %r11\n" +
    "    mov $" + tostring(r.golden2) + ", %r9\n" +
    "    xor %r9, %r11\n" +
    mix_reg("%r11", r) +
    "    or $1, %r11\n" +
    // b in %r15
    "    mov %r8, %r15\n" +
    "    and $4095, %r15\n" +
    "    imul %r11, %r15\n" +
    "    add %r10, %r15\n" +
    mix_reg("%r15", r) +
    // mask = -( (pk ^ page) & 1 )
    "    mov %rax, %r9\n" +
    "    mov %r8, %r10\n" +
    "    shr $12, %r10\n" +
    "    xor %r10, %r9\n" +
    "    and $1, %r9\n" +
    "    neg %r9\n" +
    "    and %r9, %r15\n" +
    "    xor %r15, %rdx\n" +
    "    movzbq (%rdi), %rax\n" +
    "    xor %rdx, %rax\n" +
    "    movb %al, (%rdi)\n" +
    "    add $1, %rdi\n" +
    "    add $1, %r8\n" +
    "    cmp %rsi, %rdi\n" +
    "    jb y_obf_dec_loop\n" +
    "y_obf_dec_done:\n" +
    "    ret\n"
};

def mix8(reg: str) -> str {
    "    mov " + reg + ", %rax\n" +
    "    shr $30, %rax\n" +
    "    xor %rax, " + reg + "\n" +
    "    mov $" + tostring(MIX1) + ", %rax\n" +
    "    imul %rax, " + reg + "\n" +
    "    mov " + reg + ", %rax\n" +
    "    shr $27, %rax\n" +
    "    xor %rax, " + reg + "\n" +
    "    mov $" + tostring(MIX2) + ", %rax\n" +
    "    imul %rax, " + reg + "\n" +
    "    mov " + reg + ", %rax\n" +
    "    shr $31, %rax\n" +
    "    xor %rax, " + reg + "\n"
};

// The loader's half of hash_image. It hashes the ciphertext before any page
// is decrypted; a patched file is a clean exit, not a garbage page.
def hash_text() -> str {
    "y_obf_hash:\n" +
    "    mov %rcx, %r8\n" +
    "    mov $" + tostring(HASH_DOMAIN) + ", %rax\n" +
    "    xor %rax, %r8\n" +
    mix8("%r8") +
    "    or $1, %r8\n" +
    "y_obf_hash_loop:\n" +
    "    mov %rsi, %rax\n" +
    "    sub %rdi, %rax\n" +
    "    cmp $8, %rax\n" +
    "    jb y_obf_hash_tail\n" +
    "    mov (%rdi), %rax\n" +
    "    xor %rax, %r8\n" +
    mix8("%r8") +
    "    add $8, %rdi\n" +
    "    jmp y_obf_hash_loop\n" +
    "y_obf_hash_tail:\n" +
    "    xor %rax, %rax\n" +
    "    mov %rdi, %r9\n" +
    "    mov %rsi, %r10\n" +
    "y_obf_hash_tail_loop:\n" +
    "    cmp %r9, %r10\n" +
    "    jbe y_obf_hash_tail_done\n" +
    "    sub $1, %r10\n" +
    "    shl $8, %rax\n" +
    "    movzbq (%r10), %rdx\n" +
    "    or %rdx, %rax\n" +
    "    jmp y_obf_hash_tail_loop\n" +
    "y_obf_hash_tail_done:\n" +
    "    mov %rsi, %rdx\n" +
    "    sub %rdi, %rdx\n" +
    "    shl $56, %rdx\n" +
    "    xor %rdx, %rax\n" +
    "    xor %rax, %r8\n" +
    mix8("%r8") +
    "    mov %r8, %rax\n" +
    "    ret\n"
};

def hash_check_text() -> str {
    "    lea y_obf_clear_end(%rip), %rdi\n" +
    "    lea y_obf_image_end(%rip), %rsi\n" +
    "    call y_obf_hash\n" +
    "    mov y_obf_hash_expect(%rip), %rdx\n" +
    "    cmp %rdx, %rax\n" +
    "    jne y_obf_fail\n"
};


def prefetch_text(key: long, key_file: str) -> str {
    "    lea y_obf_clear_end(%rip), %r12\n" +
    "    and $-4096, %r12\n" +
    "    lea y_obf_code_end(%rip), %r13\n" +
    "    and $-4096, %r13\n" +
    "    sub %r12, %r13\n" +
    "    shr $12, %r13\n" +
    "    test %r13, %r13\n" +
    "    jz y_obf_pf_done\n" +
    // start = key % n
    "    mov %rcx, %rax\n" +
    "    xor %rdx, %rdx\n" +
    "    div %r13\n" +
    "    mov %rdx, %r12\n" +
    // room = n - start
    "    mov %r13, %r15\n" +
    "    sub %r12, %r15\n" +
    // len = 1 + ((key>>8) % (n/4+1)), capped at room
    "    mov %r13, %r11\n" +
    "    shr $2, %r11\n" +
    "    add $1, %r11\n" +
    "    mov %rcx, %rax\n" +
    "    shr $8, %rax\n" +
    "    xor %rdx, %rdx\n" +
    "    div %r11\n" +
    "    add $1, %rdx\n" +
    "    cmp %r15, %rdx\n" +
    "    jbe y_obf_pf_len\n" +
    "    mov %r15, %rdx\n" +
    "y_obf_pf_len:\n" +
    "    mov %rdx, %r13\n" +
    "y_obf_pf:\n" +
    "    test %r13, %r13\n" +
    "    jz y_obf_pf_done\n" +
    "    lea y_obf_clear_end(%rip), %r14\n" +
    "    and $-4096, %r14\n" +
    "    mov %r12, %rax\n" +
    "    shl $12, %rax\n" +
    "    add %rax, %r14\n" +
    "    lea y_obf_pages(%rip), %r11\n" +
    "    mov (%r11,%r12,8), %rax\n" +
    "    cmp $2, %rax\n" +
    "    je y_obf_pf_next\n" +
    "    mov $10, %rax\n" +
    "    mov %r14, %rdi\n" +
    "    mov $4096, %rsi\n" +
    "    mov $3, %rdx\n" +
    "    syscall\n" +
    "    test %rax, %rax\n" +
    "    js y_obf_fail\n" +
    "    mov %r14, %rdi\n" +
    "    lea 4096(%r14), %rsi\n" +
    "    mov %r14, %r8\n" +
    "    lea y_obf_clear_end(%rip), %rax\n" +
    "    sub %rax, %r8\n" +
    key_text(key, key_file) +
    "    call y_obf_dec\n" +
    "    lea y_obf_pages(%rip), %r11\n" +
    "    mov $2, %rax\n" +
    "    mov %rax, (%r11,%r12,8)\n" +
    "    mov $10, %rax\n" +
    "    mov %r14, %rdi\n" +
    "    mov $4096, %rsi\n" +
    "    mov $5, %rdx\n" +
    "    syscall\n" +
    "    test %rax, %rax\n" +
    "    js y_obf_fail\n" +
    "y_obf_pf_next:\n" +
    "    add $1, %r12\n" +
    "    sub $1, %r13\n" +
    "    jmp y_obf_pf\n" +
    "y_obf_pf_done:\n"
};

def bulk_text(key: long, key_file: str, key_fd: long, anti_debug: bool, path_key: long) -> str {
    let r = recipe(key);
    ".text\n" +
    ".align 4096\n" +
    "y_obf_start:\n" +
    loader_guard(key) +
    guard_text(anti_debug, false) +
    read_call_text(key_file, key_fd) +
    key_text(key, key_file) +
    hash_check_text() +
    "    lea y_obf_clear_end(%rip), %r12\n" +
    "    mov %r12, %rdi\n" +
    "    and $-4096, %rdi\n" +
    "    lea y_obf_image_end(%rip), %rsi\n" +
    "    add $4095, %rsi\n" +
    "    and $-4096, %rsi\n" +
    "    sub %rdi, %rsi\n" +
    "    mov $10, %rax\n" +
    "    mov $3, %rdx\n" +
    "    syscall\n" +
    "    test %rax, %rax\n" +
    "    js y_obf_fail\n" +
    "    lea y_obf_clear_end(%rip), %rdi\n" +
    "    lea y_obf_image_end(%rip), %rsi\n" +
    "    xor %r8, %r8\n" +
    key_text(key, key_file) +
    "    call y_obf_dec\n" +
    "    lea y_obf_clear_end(%rip), %r12\n" +
    "    mov %r12, %rdi\n" +
    "    and $-4096, %rdi\n" +
    "    lea y_obf_image_end(%rip), %rsi\n" +
    "    add $4095, %rsi\n" +
    "    and $-4096, %rsi\n" +
    "    sub %rdi, %rsi\n" +
    "    mov $10, %rax\n" +
    "    mov $5, %rdx\n" +
    "    syscall\n" +
    magic_check_text(key) +
    "    jmp _start\n" +
    "y_obf_fail:\n" +
    "    mov $60, %rax\n" +
    "    mov $127, %rdi\n" +
    "    syscall\n" +
    readkey_text(key_file, key_fd, path_key) +
    dec_text(r) +
    loader_bytes(key) +
    ".align 8\ny_obf_hash_expect:\n.quad 0\n" +
    hash_text() +
    ".align 4096\n" +
    "y_obf_clear_end:\n"
};

def lazy_text(key: long, key_file: str, key_fd: long, anti_debug: bool, path_key: long) -> str {
    let r = recipe(key);
    ".text\n" +
    ".align 4096\n" +
    "y_obf_start:\n" +
    loader_guard(key) +
    guard_text(anti_debug, true) +
    read_call_text(key_file, key_fd) +
    key_text(key, key_file) +
    hash_check_text() +
    "    lea y_obf_fault(%rip), %rax\n" +
    "    mov %rax, y_obf_act(%rip)\n" +
    "    mov $67108868, %rax\n" +
    "    mov %rax, y_obf_act+8(%rip)\n" +
    "    lea y_obf_restorer(%rip), %rax\n" +
    "    mov %rax, y_obf_act+16(%rip)\n" +
    "    mov $-1, %rax\n" +
    "    mov %rax, y_obf_act+24(%rip)\n" +
    "    mov $13, %rax\n" +
    "    mov $11, %rdi\n" +
    "    lea y_obf_act(%rip), %rsi\n" +
    "    xor %rdx, %rdx\n" +
    "    mov $8, %r10\n" +
    "    syscall\n" +
    "    test %rax, %rax\n" +
    "    js y_obf_fail\n" +
    // The runtime messages (and the magic) between code_end and data_start
    // stay eager: a syscall reading a PROT_NONE user page gets EFAULT, not a
    // signal. Literals from y_obf_data_start on are decrypted a page at a
    // time, and every literal use touches its pages first.
    "    lea y_obf_code_end(%rip), %r12\n" +
    "    and $-4096, %r12\n" +
    "    lea y_obf_data_start(%rip), %rsi\n" +
    "    mov %rsi, %r13\n" +
    "    add $4095, %r13\n" +
    "    and $-4096, %r13\n" +
    "    sub %r12, %r13\n" +
    "    mov $10, %rax\n" +
    "    mov %r12, %rdi\n" +
    "    mov %r13, %rsi\n" +
    "    mov $3, %rdx\n" +
    "    syscall\n" +
    "    test %rax, %rax\n" +
    "    js y_obf_fail\n" +
    "    mov %r12, %rdi\n" +
    "    lea y_obf_data_start(%rip), %rsi\n" +
    "    mov %r12, %r8\n" +
    "    lea y_obf_clear_end(%rip), %rax\n" +
    "    sub %rax, %r8\n" +
    key_text(key, key_file) +
    "    call y_obf_dec\n" +
    "    mov $10, %rax\n" +
    "    mov %r12, %rdi\n" +
    "    mov %r13, %rsi\n" +
    "    mov $5, %rdx\n" +
    "    syscall\n" +
    "    test %rax, %rax\n" +
    "    js y_obf_fail\n" +
    magic_check_text(key) +
    // Only the code pages before that boundary stay lazy.
    "    lea y_obf_clear_end(%rip), %rdi\n" +
    "    and $-4096, %rdi\n" +
    "    lea y_obf_code_end(%rip), %rsi\n" +
    "    and $-4096, %rsi\n" +
    "    sub %rdi, %rsi\n" +
    "    jbe y_obf_nocode\n" +
    "    mov $10, %rax\n" +
    "    xor %rdx, %rdx\n" +
    "    syscall\n" +
    "    test %rax, %rax\n" +
    "    js y_obf_fail\n" +
    "y_obf_nocode:\n" +
    "    lea y_obf_data_start(%rip), %rdi\n" +
    "    lea y_obf_image_end(%rip), %rsi\n" +
    "    add $4095, %rsi\n" +
    "    and $-4096, %rsi\n" +
    "    sub %rdi, %rsi\n" +
    "    jbe y_obf_nodata\n" +
    "    mov $10, %rax\n" +
    "    xor %rdx, %rdx\n" +
    "    syscall\n" +
    "    test %rax, %rax\n" +
    "    js y_obf_fail\n" +
    "y_obf_nodata:\n" +
    prefetch_text(key, key_file) +
    "    jmp _start\n" +
    "y_obf_fail:\n" +
    "    mov $60, %rax\n" +
    "    mov $127, %rdi\n" +
    "    syscall\n" +
    "y_obf_restorer:\n" +
    "    mov $15, %rax\n" +
    "    syscall\n" +
    "y_obf_fault:\n" +
    "    mov 16(%rsi), %r12\n" +
    "    lea y_obf_clear_end(%rip), %rax\n" +
    "    cmp %rax, %r12\n" +
    "    jb y_obf_bad\n" +
    "    lea y_obf_code_end(%rip), %rax\n" +
    "    and $-4096, %rax\n" +
    "    cmp %rax, %r12\n" +
    "    jb y_obf_fault_page\n" +
    "    lea y_obf_data_start(%rip), %rax\n" +
    "    cmp %rax, %r12\n" +
    "    jb y_obf_bad\n" +
    "    lea y_obf_image_end(%rip), %rax\n" +
    "    cmp %rax, %r12\n" +
    "    jae y_obf_bad\n" +
"y_obf_fault_page:\n" +
    "y_obf_lock_try:\n" +
    "    mov $1, %rax\n" +
    "    xchg %rax, y_obf_lock(%rip)\n" +
    "    test %rax, %rax\n" +
    "    jz y_obf_locked\n" +
    "    jmp y_obf_lock_try\n" +
    "y_obf_locked:\n" +
    "    mov %r12, %r13\n" +
    "    and $-4096, %r13\n" +
    "    lea y_obf_clear_end(%rip), %rax\n" +
    "    and $-4096, %rax\n" +
    "    mov %r13, %r14\n" +
    "    sub %rax, %r14\n" +
    "    shr $12, %r14\n" +
    "    lea y_obf_pages(%rip), %r11\n" +
    "    mov (%r11,%r14,8), %rax\n" +
    "    cmp $2, %rax\n" +
    "    je y_obf_unlock\n" +
    "    mov $10, %rax\n" +
    "    mov %r13, %rdi\n" +
    "    mov $4096, %rsi\n" +
    "    mov $3, %rdx\n" +
    "    syscall\n" +
    "    mov %r13, %rdi\n" +
    "    lea y_obf_clear_end(%rip), %rax\n" +
    "    cmp %rax, %rdi\n" +
    "    jae y_obf_hs\n" +
    "    mov %rax, %rdi\n" +
    "y_obf_hs:\n" +
    "    lea 4096(%r13), %rsi\n" +
    "    lea y_obf_image_end(%rip), %rax\n" +
    "    cmp %rax, %rsi\n" +
    "    jbe y_obf_he\n" +
    "    mov %rax, %rsi\n" +
    "y_obf_he:\n" +
    "    mov %rdi, %r8\n" +
    "    lea y_obf_clear_end(%rip), %rax\n" +
    "    sub %rax, %r8\n" +
    key_text(key, key_file) +
    "    call y_obf_dec\n" +
    // The page is plaintext now; check it against the build's per-page MAC.
    "    lea y_obf_mac_count(%rip), %rax\n" +
    "    mov (%rax), %rax\n" +
    "    test %rax, %rax\n" +
    "    jz y_obf_mac_ok\n" +
    "    lea y_obf_macs(%rip), %r11\n" +
    "    mov (%r11,%r14,8), %r12\n" +
    "    mov %r13, %rdi\n" +
    "    lea y_obf_clear_end(%rip), %rax\n" +
    "    cmp %rax, %rdi\n" +
    "    jae y_obf_mac_h\n" +
    "    mov %rax, %rdi\n" +
"y_obf_mac_h:\n" +
    "    lea 4096(%r13), %rsi\n" +
    "    lea y_obf_image_end(%rip), %rax\n" +
    "    cmp %rax, %rsi\n" +
    "    jbe y_obf_mac_e\n" +
    "    mov %rax, %rsi\n" +
"y_obf_mac_e:\n" +
    key_text(key, key_file) +
    "    mov %rcx, %rax\n" +
    "    mov $" + tostring(MAC_DOMAIN) + ", %rdx\n" +
    "    xor %rdx, %rax\n" +
    "    mov %rax, %rcx\n" +
    "    call y_obf_hash\n" +
    "    cmp %r12, %rax\n" +
    "    jne y_obf_bad\n" +
"y_obf_mac_ok:\n" +
    "    lea y_obf_pages(%rip), %r11\n" +
    "    mov $2, %rax\n" +
    "    mov %rax, (%r11,%r14,8)\n" +
"y_obf_unlock:\n" +
    "    xor %rax, %rax\n" +
    "    mov %rax, y_obf_lock(%rip)\n" +
    "    mov $10, %rax\n" +
    "    mov %r13, %rdi\n" +
    "    mov $4096, %rsi\n" +
    "    mov $5, %rdx\n" +
    "    syscall\n" +
    "    ret\n" +
    "y_obf_bad:\n" +
    "    mov $231, %rax\n" +
    "    mov $139, %rdi\n" +
    "    syscall\n" +
    readkey_text(key_file, key_fd, path_key) +
    dec_text(r) +
    loader_bytes(key) +
    ".align 8\ny_obf_hash_expect:\n.quad 0\n" +
    hash_text() +
    (if (anti_debug) { status_text() } else { "" }) +
    // One keyed MAC per cipher page, patched by asm_link. The table lives in
    // the plaintext loader area (the image hash does not cover it); a changed
    // entry makes the page it names fail at decrypt time.
    ".align 8\ny_obf_macs:\n.zero 65536\n" +
    "y_obf_mac_count:\n.quad 0\n" +
    ".align 4096\n" +
    "y_obf_clear_end:\n"
};

def stub_text(key: long, lazy: bool, key_file: str = "",
        anti_debug: bool = false, key_fd: long = -1,
        path_key: long = 0) -> str {
    let text = if (lazy) { lazy_text(key, key_file, key_fd, anti_debug, path_key) }
        else { bulk_text(key, key_file, key_fd, anti_debug, path_key) };
    if (wintgt.target_is_aarch64()) {
        // The cipher still uses 4 KiB logical pages. Protection and fault
        // tracking use 64 KiB so the same executable runs on either kernel.
        text = text.replace(".align 4096", ".align 65536");
        let dec = text.index_of("y_obf_dec:\n");
        let loader = text[:dec];
        loader = loader.replace("$-4096,", "$-65536,");
        loader = loader.replace("$4095,", "$65535,");
        loader = loader.replace("$4096,", "$65536,");
        loader = loader.replace("shr $12,", "shr $16,");
        loader = loader.replace("shl $12,", "shl $16,");
        text = loader + text[dec:];
        text = text.replace("4096(%r14)", "65536(%r14)").replace("4096(%r13)", "65536(%r13)");
        text = text.replace("y_obf_start:\n", "y_obf_start:\n    a64_entry\n");
        text = text.replace("y_obf_fault:\n", "y_obf_fault:\n    a64_signal_entry\n");
        text = text.replace("y_obf_restorer:\n    mov $15, %rax\n    syscall", "y_obf_restorer:\n    a64_sigreturn");
        text = text.replace("y_obf_dec:\n", ".align 4\ny_obf_dec:\n    a64_cache_begin\n");
        text = text.replace("y_obf_dec_done:\n", "y_obf_dec_done:\n    a64_cache_end\n");
        text = text.replace("\ny_obf_lj_end:", "\n.align 4\ny_obf_lj_end:");
    };
    text
};

// The PE bootstrap: the Windows loader maps .text RWX for a sealed image, so
// the stub needs no VirtualProtect and no import. It hashes the ciphertext,
// decrypts the region after itself, and jumps to the real _start. It runs
// before any Windows runtime call and uses only registers and RIP-relative
// loads, so the SysV argument setup inside is ours to choose.
def pe_stub_text(key: long, anti_debug: bool = false) -> str {
    let r = recipe(key);
    let guard = if (anti_debug) {
        // IsDebuggerPresent through the import table; the loader has already
        // resolved it. Windows x64 needs 32 bytes of shadow space and a
        // 16-byte aligned call site.
        "    mov y_iat_IsDebuggerPresent(%rip), %rax\n" +
        "    sub $40, %rsp\n" +
        "    call *%rax\n" +
        "    add $40, %rsp\n" +
        "    test %eax, %eax\n" +
        "    jnz y_obf_fail\n"
    } else { "" };
    ".text\n" +
    "y_obf_start:\n" +
    guard +
    key_text(key, "") +
    "    lea y_pe_region(%rip), %rdi\n" +
    "    mov y_pe_len(%rip), %rsi\n" +
    "    add %rdi, %rsi\n" +
    "    call y_obf_hash\n" +
    "    mov y_obf_hash_expect(%rip), %rdx\n" +
    "    cmp %rdx, %rax\n" +
    "    jne y_obf_fail\n" +
    "    lea y_pe_region(%rip), %rdi\n" +
    "    mov y_pe_len(%rip), %rsi\n" +
    "    add %rdi, %rsi\n" +
    "    xor %r8, %r8\n" +
    key_text(key, "") +
    "    call y_obf_dec\n" +
    "    jmp _start\n" +
    "y_obf_fail:\n" +
    "    .byte 15,11\n" +
    dec_text(r) +
    hash_text() +
    ".align 8\ny_obf_hash_expect:\n.quad 0\n" +
    "y_pe_len:\n.quad 0\n" +
    "y_pe_region:\n"
};

def bss_text() -> str {
    "y_obf_pages:\n.zero 524288\n" +
    "y_obf_lock:\n.zero 8\n" +
    "y_obf_act:\n.zero 32\n" +
    "y_obf_key:\n.zero 8\n" +
    "y_obf_keybuf:\n.zero 32\n" +
    "y_obf_pathbuf:\n.zero 256\n" +
    "y_obf_procbuf:\n.zero 1024\n"
};

def key_bss_text() -> str {
    "y_obf_key:\n.zero 8\n" +
    "y_obf_keybuf:\n.zero 32\n" +
    "y_obf_pathbuf:\n.zero 256\n" +
    "y_obf_procbuf:\n.zero 1024\n"
};

export { stub_text, pe_stub_text, bss_text, key_bss_text, magic_text, key_from_bytes,
    crypt_range, hash_image, mix_final, MAGIC, MAC_DOMAIN, recipe, Recipe };
