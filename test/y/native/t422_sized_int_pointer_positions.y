// Sized-integer pointers wherever a pointer type goes: a record field, a
// parameter, an array element; stores narrow, loads widen by sign, comparison and
// subtraction work as for any pointer. (`*p += 1` is not an expression for any
// pointer type, so there is no compound assignment to test.) A pointer variable
// steps by its target's width under ++ -- += -=.
type Hdr = { p: *u16, q: *i32be };
let buf: [byte; 16] = [0; 16];
def at(off: long) -> long { ptr_addr(buf.ptr) + off };
def rd(p: *u32) -> long { *p };
def wr(p: *i16, v: long) -> long { *p = v; *p };
let p: *u16 = ptr_from(at(0));
*p = 250;
puts(tostring(*p) + "\n");
puts(tostring(*p) + "\n");
let h: Hdr = { p: p, q: ptr_from(at(8)) };
*h.q = -3;
puts(tostring(*h.q) + " " + tostring(buf[8]) + " " + tostring(buf[11]) + "\n");
puts(tostring(rd(ptr_from(at(0)))) + "\n");
puts(tostring(wr(ptr_from(at(4)), 40000)) + "\n");
let ps: [*u16] = [p, p + 1];
puts(tostring(ptr_addr(ps[1]) - ptr_addr(ps[0])) + "\n");
let x = *p + *h.q;
puts(tostring(x) + "\n");
puts(tostring(*(p + 2)) + "\n");
puts(tostring(p == p) + " " + tostring(p < p + 1) + "\n");

let base = ptr_addr(buf.ptr);
let sp: *u16 = ptr_from(base);
sp++;
puts(tostring(ptr_addr(sp) - base) + "\n");
sp += 3;
puts(tostring(ptr_addr(sp) - base) + "\n");
sp--;
puts(tostring(ptr_addr(sp) - base) + "\n");
sp -= 2;
puts(tostring(ptr_addr(sp) - base) + "\n");
let sq: *u32 = ptr_from(base);
sq++;
sq += 2;
puts(tostring(ptr_addr(sq) - base) + "\n");
let sr: *i8 = ptr_from(base);
sr += 5;
puts(tostring(ptr_addr(sr) - base) + "\n");
puts(tostring(len(tostring(h)) > 0) + " " + tostring(len(tostring(ps)) > 0) + "\n");
