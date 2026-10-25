// sizeof and offsetof are constants of the layout; a fixed-array field reads as a
// pointer to its first element (the array's elements are the record's bytes).
type Sub = packed { a: u8, b: i16 };
type Hdr = packed { magic: u32be, len: u16, tag: [byte; 4], sub: Sub, w: [u16; 3], big: i64 };
puts(tostring(sizeof(Hdr)) + " " + tostring(sizeof(Sub)) + "\n");
puts(tostring(offsetof(Hdr, len)) + " " + tostring(offsetof(Hdr, tag)) + " " + tostring(offsetof(Hdr, sub)) + " " + tostring(offsetof(Hdr, w)) + " " + tostring(offsetof(Hdr, big)) + "\n");
let h: Hdr = { len: 7, big: 99 };
let t = h.tag;
*t = 65;
*(t + 3) = 90;
let w = h.w;
*(w + 2) = 4000;
puts(tostring(*h.tag) + " " + tostring(*(h.tag + 3)) + " " + tostring(*(h.w + 2)) + " " + tostring(h.len) + " " + tostring(h.big) + "\n");
