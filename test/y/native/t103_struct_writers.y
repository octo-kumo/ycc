import struct;

let hi = 9223372036854775807;
let lo = 0 - hi - 1;

print("u8");
print(struct.u8(0));
print(struct.u8(255));
print(struct.u8(-1));
print(struct.u8(lo));
print(struct.u8(hi));

print("i8");
print(struct.i8(0));
print(struct.i8(127));
print(struct.i8(-128));
print(struct.i8(-1));
print(struct.i8(lo));
print(struct.i8(hi));

print("u16le");
print(struct.u16le(0));
print(struct.u16le(32768));
print(struct.u16le(65535));
print(struct.u16le(-1));
print(struct.u16le(lo));
print(struct.u16le(hi));

print("u16be");
print(struct.u16be(0));
print(struct.u16be(32768));
print(struct.u16be(65535));
print(struct.u16be(-1));
print(struct.u16be(lo));
print(struct.u16be(hi));

print("i16le");
print(struct.i16le(0));
print(struct.i16le(32767));
print(struct.i16le(-32768));
print(struct.i16le(-1));
print(struct.i16le(lo));
print(struct.i16le(hi));

print("i16be");
print(struct.i16be(0));
print(struct.i16be(32767));
print(struct.i16be(-32768));
print(struct.i16be(-1));
print(struct.i16be(lo));
print(struct.i16be(hi));

print("u32le");
print(struct.u32le(0));
print(struct.u32le(2147483648));
print(struct.u32le(4294967295));
print(struct.u32le(-1));
print(struct.u32le(lo));
print(struct.u32le(hi));

print("u32be");
print(struct.u32be(0));
print(struct.u32be(2147483648));
print(struct.u32be(4294967295));
print(struct.u32be(-1));
print(struct.u32be(lo));
print(struct.u32be(hi));

print("i32le");
print(struct.i32le(0));
print(struct.i32le(2147483647));
print(struct.i32le(-2147483648));
print(struct.i32le(-1));
print(struct.i32le(lo));
print(struct.i32le(hi));

print("i32be");
print(struct.i32be(0));
print(struct.i32be(2147483647));
print(struct.i32be(-2147483648));
print(struct.i32be(-1));
print(struct.i32be(lo));
print(struct.i32be(hi));

print("u64le");
print(struct.u64le(0));
print(struct.u64le(hi));
print(struct.u64le(-1));
print(struct.u64le(lo));
print(struct.u64le(hi));

print("u64be");
print(struct.u64be(0));
print(struct.u64be(hi));
print(struct.u64be(-1));
print(struct.u64be(lo));
print(struct.u64be(hi));

print("i64le");
print(struct.i64le(0));
print(struct.i64le(hi));
print(struct.i64le(-1));
print(struct.i64le(lo));
print(struct.i64le(hi));

print("i64be");
print(struct.i64be(0));
print(struct.i64be(hi));
print(struct.i64be(-1));
print(struct.i64be(lo));
print(struct.i64be(hi));

print("pad and fill");
print(struct.pad(0));
print(struct.pad(4));
print(struct.fill(0, 255));
print(struct.fill(4, 255));
print(struct.fill(4, -1));
print(struct.fill(4, lo));
print(struct.fill(4, hi));
