import struct;

let hi = 9223372036854775807;
let lo = 0 - hi - 1;

print("get_u8");
print([
    struct.get_u8(struct.u8(0), 0),
    struct.get_u8(struct.u8(255), 0),
    struct.get_u8(struct.u8(-1), 0),
    struct.get_u8(struct.u8(lo), 0),
    struct.get_u8(struct.u8(hi), 0)
]);
print("get_i8");
print([
    struct.get_i8(struct.i8(0), 0),
    struct.get_i8(struct.i8(127), 0),
    struct.get_i8(struct.i8(128), 0),
    struct.get_i8(struct.i8(-1), 0),
    struct.get_i8(struct.i8(lo), 0),
    struct.get_i8(struct.i8(hi), 0)
]);

print("get_u16le");
print([
    struct.get_u16le(struct.u16le(0), 0),
    struct.get_u16le(struct.u16le(32767), 0),
    struct.get_u16le(struct.u16le(32768), 0),
    struct.get_u16le(struct.u16le(65535), 0),
    struct.get_u16le(struct.u16le(lo), 0),
    struct.get_u16le(struct.u16le(hi), 0)
]);
print("get_u16be");
print([
    struct.get_u16be(struct.u16be(0), 0),
    struct.get_u16be(struct.u16be(32767), 0),
    struct.get_u16be(struct.u16be(32768), 0),
    struct.get_u16be(struct.u16be(65535), 0),
    struct.get_u16be(struct.u16be(lo), 0),
    struct.get_u16be(struct.u16be(hi), 0)
]);
print("get_i16le");
print([
    struct.get_i16le(struct.i16le(0), 0),
    struct.get_i16le(struct.i16le(32767), 0),
    struct.get_i16le(struct.i16le(32768), 0),
    struct.get_i16le(struct.i16le(-1), 0),
    struct.get_i16le(struct.i16le(lo), 0),
    struct.get_i16le(struct.i16le(hi), 0)
]);
print("get_i16be");
print([
    struct.get_i16be(struct.i16be(0), 0),
    struct.get_i16be(struct.i16be(32767), 0),
    struct.get_i16be(struct.i16be(32768), 0),
    struct.get_i16be(struct.i16be(-1), 0),
    struct.get_i16be(struct.i16be(lo), 0),
    struct.get_i16be(struct.i16be(hi), 0)
]);

print("get_u32le");
print([
    struct.get_u32le(struct.u32le(0), 0),
    struct.get_u32le(struct.u32le(2147483647), 0),
    struct.get_u32le(struct.u32le(2147483648), 0),
    struct.get_u32le(struct.u32le(4294967295), 0),
    struct.get_u32le(struct.u32le(lo), 0),
    struct.get_u32le(struct.u32le(hi), 0)
]);
print("get_u32be");
print([
    struct.get_u32be(struct.u32be(0), 0),
    struct.get_u32be(struct.u32be(2147483647), 0),
    struct.get_u32be(struct.u32be(2147483648), 0),
    struct.get_u32be(struct.u32be(4294967295), 0),
    struct.get_u32be(struct.u32be(lo), 0),
    struct.get_u32be(struct.u32be(hi), 0)
]);
print("get_i32le");
print([
    struct.get_i32le(struct.i32le(0), 0),
    struct.get_i32le(struct.i32le(2147483647), 0),
    struct.get_i32le(struct.i32le(2147483648), 0),
    struct.get_i32le(struct.i32le(-1), 0),
    struct.get_i32le(struct.i32le(lo), 0),
    struct.get_i32le(struct.i32le(hi), 0)
]);
print("get_i32be");
print([
    struct.get_i32be(struct.i32be(0), 0),
    struct.get_i32be(struct.i32be(2147483647), 0),
    struct.get_i32be(struct.i32be(2147483648), 0),
    struct.get_i32be(struct.i32be(-1), 0),
    struct.get_i32be(struct.i32be(lo), 0),
    struct.get_i32be(struct.i32be(hi), 0)
]);

print("get_u64le");
print([
    struct.get_u64le(struct.u64le(0), 0),
    struct.get_u64le(struct.u64le(hi), 0),
    struct.get_u64le(struct.u64le(-1), 0),
    struct.get_u64le(struct.u64le(lo), 0)
]);
print("get_u64be");
print([
    struct.get_u64be(struct.u64be(0), 0),
    struct.get_u64be(struct.u64be(hi), 0),
    struct.get_u64be(struct.u64be(-1), 0),
    struct.get_u64be(struct.u64be(lo), 0)
]);
print("get_i64le");
print([
    struct.get_i64le(struct.i64le(0), 0),
    struct.get_i64le(struct.i64le(hi), 0),
    struct.get_i64le(struct.i64le(-1), 0),
    struct.get_i64le(struct.i64le(lo), 0)
]);
print("get_i64be");
print([
    struct.get_i64be(struct.i64be(0), 0),
    struct.get_i64be(struct.i64be(hi), 0),
    struct.get_i64be(struct.i64be(-1), 0),
    struct.get_i64be(struct.i64be(lo), 0)
]);

let fmt = "u8, i8, u16le, u16be, i16le, i16be, u32le, u32be, i32le, i32be, u64le, u64be, i64le, i64be, pad, fill";
let values: [long] = [
    255, -1, 65535, 4660, -32768, 32767,
    4294967295, 16909060, -2147483648, 2147483647,
    lo, hi, -1, lo, 3, 4
];
let packed = struct.pack(fmt, values);
print(len(packed));
print(packed);
print(struct.unpack("u8,i8,u16le,u16be,i16le,i16be,u32le,u32be,i32le,i32be,u64le,u64be,i64le,i64be", packed));
print([
    struct.width_of("u8"),
    struct.width_of("i8"),
    struct.width_of("u16le"),
    struct.width_of("u16be"),
    struct.width_of("i16le"),
    struct.width_of("i16be"),
    struct.width_of("u32le"),
    struct.width_of("u32be"),
    struct.width_of("i32le"),
    struct.width_of("i32be"),
    struct.width_of("u64le"),
    struct.width_of("u64be"),
    struct.width_of("i64le"),
    struct.width_of("i64be"),
    struct.width_of("pad"),
    struct.width_of("fill")
]);
print(struct.width_of("unknown"));
