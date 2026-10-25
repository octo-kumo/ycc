// Byte strings: b"..." / b'...' literals are ordinary [byte] arrays.
// Printing one shows the Python-style repr: printable ASCII verbatim,
// quote and backslash escaped, \n \r \t as escapes, everything else \xHH.
import struct from "../../../src/y/std/struct.y";

print(b"AB");
print(b'q"');
print(b"'");
print(b"\\");
print(b"\n\r\t");
print(b"\x00\x7f\xff");

// slicing binary strings: parse a file header
let hdr = struct.u32be(0x7f454c46) + struct.u16le(2) + struct.pad(2) + struct.u64le(4096);
print(len(hdr));
print(struct.get_u32be(hdr, 0));
print(struct.get_u16le(hdr, 4));
print(struct.get_u64le(hdr, 8));
let kind = hdr[0:4];
print(kind);
let rest = hdr[4:];
print(len(rest));

// signed round trips spell the same two's-complement bits
print(struct.get_i16le(struct.i16le(-2), 0));
print(struct.get_i32be(struct.i32be(-2), 0));
print(struct.get_i64le(struct.i64le(-1), 0));
print(struct.get_u8(struct.u8(255), 0));

// bulk pack/unpack over a format
let blob = struct.pack("u8,u16be,u32le", [1, 258, 16909060]);
print(len(blob));
print(struct.unpack("u8,u16be,u32le", blob));
print(blob);

// constructing a large binary structure out of pieces
let big: [byte] = [];
let i = 0;
while (i < 1000) {
    big += struct.u16le(i);
    i += 1;
};
print(len(big));
print(struct.get_u16le(big, 0));
print(struct.get_u16le(big, 1998));
print(big[1998:2000]);
