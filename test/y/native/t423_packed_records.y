// Packed records: `type T = packed { .. }` lays fields out in order with no padding,
// `bits u8 { a, b, mode: 3, _: 2 }` carves one integer into bits from the low end
// (a bare name is one bit and reads as a bool). A value is the address of its bytes;
// a literal makes a zeroed block, and `*Hdr` is the same address.
type Flags = bits u8 { ready, error, done, mode: 3, _: 2 };
type Sub = packed { a: u8, b: i16 };
type Hdr = packed {
    magic: u32be,
    len: u16,
    flags: Flags,
    sub: Sub,
    big: i64,
    ok: bool,
    next: *byte
};
let h: Hdr = { magic: 0xCAFEBABE, len: 513, flags: { ready: true, mode: 5 }, sub: { a: 7, b: -2 }, big: -1, ok: true };
puts(tostring(h.magic) + "\n");
puts(tostring(h.len) + "\n");
puts(tostring(h.flags.ready) + " " + tostring(h.flags.error) + " " + tostring(h.flags.mode) + "\n");
puts(tostring(h.sub.a) + " " + tostring(h.sub.b) + "\n");
puts(tostring(h.big) + " " + tostring(h.ok) + "\n");
h.flags.error = true;
h.flags.mode = 2;
h.flags.ready = false;
puts(tostring(h.flags.ready) + " " + tostring(h.flags.error) + " " + tostring(h.flags.mode) + "\n");
h.len = 0x1234;
h.sub.b = 300;
puts(tostring(h.len) + " " + tostring(h.sub.b) + "\n");
let raw: *byte = ptr_from(ptr_addr(h));
puts(tostring(*raw) + " " + tostring(*(raw + 1)) + " " + tostring(*(raw + 2)) + " " + tostring(*(raw + 3)) + " " + tostring(*(raw + 4)) + " " + tostring(*(raw + 5)) + "\n");
let p: *Hdr = h;
puts(tostring(p.len) + "\n");
p.len = 9;
puts(tostring(h.len) + "\n");
