// Sized integers (i8 i16 u16 i32 u32, the 16/32/64-bit ones also with a `be`
// suffix) are pointer targets: `*p` widens to a long (sign- or zero-extended),
// `*p = v` stores the low bytes, pointer arithmetic steps by the width, and a
// big-endian target swaps on the way in and out. Memory is a [byte; 16].
let buf: [byte; 16] = [0; 16];
def at(off: long) -> long { ptr_addr(buf.ptr) + off };
let w32: *u32 = ptr_from(at(0));
let s32: *i32 = ptr_from(at(0));
let w16: *u16 = ptr_from(at(4));
let s16: *i16 = ptr_from(at(4));
let s8: *i8 = ptr_from(at(6));
let b32: *u32be = ptr_from(at(8));
let b16: *i16be = ptr_from(at(12));
let b64: *u64be = ptr_from(at(0));
*w32 = 0xFFFFFFFE;
puts(tostring(*w32) + "\n");
puts(tostring(*s32) + "\n");
*w16 = 65535;
puts(tostring(*w16) + "\n");
puts(tostring(*s16) + "\n");
*s8 = 200;
puts(tostring(*s8) + "\n");
puts(tostring(buf[6]) + "\n");
*b32 = 0x01020304;
puts(tostring(buf[8]) + " " + tostring(buf[9]) + " " + tostring(buf[10]) + " " + tostring(buf[11]) + "\n");
puts(tostring(*b32) + "\n");
*b16 = -2;
puts(tostring(buf[12]) + " " + tostring(buf[13]) + "\n");
puts(tostring(*b16) + "\n");
*s32 = -5;
puts(tostring(*s32) + "\n");
puts(tostring(*w32) + "\n");
let q = w16 + 1;
puts(tostring(ptr_addr(q) - ptr_addr(w16)) + "\n");
puts(tostring(q - w16) + "\n");
puts(tostring((w32 + 3) - w32) + "\n");
*b64 = 0x0102030405060708;
puts(tostring(buf[0]) + " " + tostring(buf[7]) + "\n");
puts(tostring(*b64) + "\n");
