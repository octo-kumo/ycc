// std/struct.y — pack and unpack numbers into binary strings ([byte]).
//
// The building blocks of file headers and binary layouts. A "binary
// string" is a plain [byte] array (b"..." literals are the same type):
// concatenate with `+` (which makes a NEW array), cut with slices, and
// print with the Python-style b'...' repr.
//
//     import struct;
//
//     let hdr = struct.u32be(0x7f454c46) + struct.u16le(2) + struct.pad(10);
//     if (struct.get_u32be(hdr, 0) == 0x7f454c46) { print("ELF magic") };
//
// Every fixed-width writer takes a long and produces exactly its width;
// the readers take (bytes, offset) and do NO bounds checking of their own
// -- an offset past the end trips the runtime's index trap (y_oob) and
// exits 1, so slice first for untrusted input.

// ── byte plumbing ─────────────────────────────────────────────────────
// The low 8 bits of v's two's-complement pattern, and the value shifted
// right by one byte (arithmetic shift: negative values keep their sign
// bits, so iN and uN writers share one implementation).

def low_byte(v: long) -> long {
    if (v >= 0) { v % 256 } else { 255 - ((0 - v - 1) % 256) }
};

def shr8(v: long) -> long {
    (v - low_byte(v)) / 256
};

// ── writers: one value -> its bytes ───────────────────────────────────

def u8(v: long) -> [byte] {
    let o: [byte] = [0; 1];
    o[0] = low_byte(v);
    o
};

def u16le(v: long) -> [byte] {
    let o: [byte] = [0; 2];
    o[0] = low_byte(v);
    o[1] = low_byte(shr8(v));
    o
};

def u16be(v: long) -> [byte] {
    let o: [byte] = [0; 2];
    o[0] = low_byte(shr8(v));
    o[1] = low_byte(v);
    o
};

def u32le(v: long) -> [byte] {
    let o: [byte] = [0; 4];
    o[0] = low_byte(v);
    o[1] = low_byte(shr8(v));
    o[2] = low_byte(shr8(shr8(v)));
    o[3] = low_byte(shr8(shr8(shr8(v))));
    o
};

def u32be(v: long) -> [byte] {
    let o: [byte] = [0; 4];
    o[0] = low_byte(shr8(shr8(shr8(v))));
    o[1] = low_byte(shr8(shr8(v)));
    o[2] = low_byte(shr8(v));
    o[3] = low_byte(v);
    o
};

def u64le(v: long) -> [byte] {
    let o: [byte] = [0; 8];
    let x = v;
    let i = 0;
    while (i < 8) {
        o[i] = low_byte(x);
        x = shr8(x);
        i = i + 1;
    };
    o
};

def u64be(v: long) -> [byte] {
    let o: [byte] = [0; 8];
    let x = v;
    let i = 8;
    while (i > 0) {
        i = i - 1;
        o[i] = low_byte(x);
        x = shr8(x);
    };
    o
};

// The signed writers spell the same bits: two's complement is the pattern.
def i8(v: long) -> [byte] { u8(v) };
def i16le(v: long) -> [byte] { u16le(v) };
def i16be(v: long) -> [byte] { u16be(v) };
def i32le(v: long) -> [byte] { u32le(v) };
def i32be(v: long) -> [byte] { u32be(v) };
def i64le(v: long) -> [byte] { u64le(v) };
def i64be(v: long) -> [byte] { u64be(v) };

// n zero bytes; n bytes of one value. Sizes are runtime, so these grow
// a heap [byte] (`+=` pushes one non-array value).
def pad(n: long) -> [byte] {
    let o: [byte] = [];
    let i = 0;
    while (i < n) {
        o += 0;
        i = i + 1;
    };
    o
};

def fill(n: long, v: long) -> [byte] {
    let o: [byte] = [];
    let i = 0;
    while (i < n) {
        o += low_byte(v);
        i = i + 1;
    };
    o
};

// ── readers: the value at an offset ───────────────────────────────────

def get_u8(b: [byte], off: long) -> long {
    b[off]
};

def get_i8(b: [byte], off: long) -> long {
    let cv: long = b[off];
    if (cv < 128) { cv } else { cv - 256 }
};

def get_u16le(b: [byte], off: long) -> long {
    b[off] + 256 * b[off + 1]
};

def get_u16be(b: [byte], off: long) -> long {
    256 * b[off] + b[off + 1]
};

def get_i16le(b: [byte], off: long) -> long {
    let u = get_u16le(b, off);
    if (u < 32768) { u } else { u - 65536 }
};

def get_i16be(b: [byte], off: long) -> long {
    let u = get_u16be(b, off);
    if (u < 32768) { u } else { u - 65536 }
};

def get_u32le(b: [byte], off: long) -> long {
    b[off] + 256 * b[off + 1] + 65536 * b[off + 2] + 16777216 * b[off + 3]
};

def get_u32be(b: [byte], off: long) -> long {
    16777216 * b[off] + 65536 * b[off + 1] + 256 * b[off + 2] + b[off + 3]
};

def get_i32le(b: [byte], off: long) -> long {
    let u = get_u32le(b, off);
    if (u < 2147483648) { u } else { u - 4294967296 }
};

def get_i32be(b: [byte], off: long) -> long {
    let u = get_u32be(b, off);
    if (u < 2147483648) { u } else { u - 4294967296 }
};

def get_u64le(b: [byte], off: long) -> long {
    let x = 0;
    let i = 8;
    while (i > 0) {
        i = i - 1;
        x = x * 256 + b[off + i];
    };
    x
};

def get_u64be(b: [byte], off: long) -> long {
    let x = 0;
    let i = 0;
    while (i < 8) {
        x = x * 256 + b[off + i];
        i = i + 1;
    };
    x
};

// The i64 readers are the same words: a long IS the signed pattern — and
// so are the u64 readers (a `long` is 64 bits with no unsigned reading of
// it, so a u64 value with the top bit set comes back as its negative
// two's complement; the i64 spelling just says so out loud).
def get_i64le(b: [byte], off: long) -> long { get_u64le(b, off) };
def get_i64be(b: [byte], off: long) -> long { get_u64be(b, off) };

// ── bulk pack/unpack over a format ────────────────────────────────────
// A format is a comma-separated list of the writer/reader names:
//     pack("u32be,i16le,pad", [1, -2, 4])   -- pad takes its width
//     unpack("u32be,i16le", hdr)            -- reads two values
// pack reads vals[i] for name i, so the two lists must line up: a format
// longer than the value list runs off the end (index trap), and names are
// trimmed, so "u32be, u16le" and "u32be,u16le" are the same format. An
// unknown name prints to stdout and exits 1.

def pack_one(name: str, v: long) -> [byte] {
    if (name == "u8") { u8(v) }
    else if (name == "i8") { i8(v) }
    else if (name == "u16le") { u16le(v) }
    else if (name == "u16be") { u16be(v) }
    else if (name == "i16le") { i16le(v) }
    else if (name == "i16be") { i16be(v) }
    else if (name == "u32le") { u32le(v) }
    else if (name == "u32be") { u32be(v) }
    else if (name == "i32le") { i32le(v) }
    else if (name == "i32be") { i32be(v) }
    else if (name == "u64le") { u64le(v) }
    else if (name == "u64be") { u64be(v) }
    else if (name == "i64le") { i64le(v) }
    else if (name == "i64be") { i64be(v) }
    else if (name == "pad") { pad(v) }
    else if (name == "fill") { fill(v, 0) }
    else {
        puts("struct.pack: unknown format '" + name + "'\n");
        exit(1);
        // Unreachable (exit never returns), but the arm still has to
        // produce a [byte]: arms that disagree make the whole `if` void,
        // and pack's `out += pack_one(...)` cannot take a void value.
        let none: [byte] = [];
        none
    }
};

def pack(fmt: str, vals: [long]) -> [byte] {
    let names = split(fmt, ",");
    let out: [byte] = [];
    let i = 0;
    while (i < len(names)) {
        out += pack_one(trim(names[i]), vals[i]);
        i = i + 1;
    };
    out
};

def unpack_one(name: str, b: [byte], off: long) -> long {
    if (name == "u8") { get_u8(b, off) }
    else if (name == "i8") { get_i8(b, off) }
    else if (name == "u16le") { get_u16le(b, off) }
    else if (name == "u16be") { get_u16be(b, off) }
    else if (name == "i16le") { get_i16le(b, off) }
    else if (name == "i16be") { get_i16be(b, off) }
    else if (name == "u32le") { get_u32le(b, off) }
    else if (name == "u32be") { get_u32be(b, off) }
    else if (name == "i32le") { get_i32le(b, off) }
    else if (name == "i32be") { get_i32be(b, off) }
    else if (name == "u64le") { get_u64le(b, off) }
    else if (name == "u64be") { get_u64be(b, off) }
    else if (name == "i64le") { get_i64le(b, off) }
    else if (name == "i64be") { get_i64be(b, off) }
    else {
        puts("struct.unpack: unknown format '" + name + "'\n");
        exit(1);
        0
    }
};

// widths for the format names (pad/fill are pack-only)
def width_of(name: str) -> long {
    if (name == "u8") { 1 }
    else if (name == "i8") { 1 }
    else if (name == "u16le") { 2 }
    else if (name == "u16be") { 2 }
    else if (name == "i16le") { 2 }
    else if (name == "i16be") { 2 }
    else if (name == "u32le") { 4 }
    else if (name == "u32be") { 4 }
    else if (name == "i32le") { 4 }
    else if (name == "i32be") { 4 }
    else { 8 }
};

def unpack(fmt: str, b: [byte]) -> [long] {
    let names = split(fmt, ",");
    let out: [long] = [];
    let off = 0;
    let i = 0;
    while (i < len(names)) {
        let nm = trim(names[i]);
        out += [unpack_one(nm, b, off)];
        off += width_of(nm);
        i = i + 1;
    };
    out
};

export { u8, u16le, u16be, u32le, u32be, u64le, u64be,
         i8, i16le, i16be, i32le, i32be, i64le, i64be,
         pad, fill,
         get_u8, get_i8, get_u16le, get_u16be, get_i16le, get_i16be,
         get_u32le, get_u32be, get_i32le, get_i32be,
         get_u64le, get_u64be, get_i64le, get_i64be,
         pack, unpack };
