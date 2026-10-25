// std/struct: pack/unpack round trips across widths and signedness,
// building and parsing binary layouts.
import struct from "../../../src/y/std/struct.y";

// every width round trips
print(struct.unpack("u8", struct.pack("u8", [255])));
print(struct.unpack("i8", struct.pack("i8", [-128])));
print(struct.unpack("u16le", struct.pack("u16le", [65535])));
print(struct.unpack("u16be", struct.pack("u16be", [65535])));
print(struct.unpack("i16le", struct.pack("i16le", [-32768])));
print(struct.unpack("i32be", struct.pack("i32be", [-2147483648])));
print(struct.unpack("u32le", struct.pack("u32le", [4294967295])));
print(struct.unpack("i64le", struct.pack("i64le", [-1])));
print(struct.unpack("u64be", struct.pack("u64be", [72057594037927936])));

// a file-header layout
let hdr = struct.pack("u32be,u16le,u16le,u64be", [0x7f454c46, 2, 62, 4096]);
print(len(hdr));
print(struct.unpack("u32be,u16le,u16le,u64be", hdr));

// pad and fill
print(len(struct.pad(4)));
print(struct.fill(3, 65));

// a large structure: a length-prefixed payload
let body = struct.fill(100, 7);
let frame = struct.u32be(len(body)) + body;
print(len(frame));
print(struct.get_u32be(frame, 0));
print(frame[4:7]);
print(struct.get_u8(frame, 99));
