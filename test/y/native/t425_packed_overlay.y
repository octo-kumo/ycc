// A packed record over memory that is not its own: a [byte; N] buffer read and
// written through *T, wide bitmaps, signed big-endian fields, pointer fields and
// packed records passed to functions.
type Wide = bits u64 { lo: 32, mid: 16, flag, _: 14, top };
type Pkt = packed {
    kind: i8,
    seq: i16be,
    total: i32be,
    wide: Wide,
    ptr: *byte,
    ratio: float,
    small: bits u16 { a: 4, b: 4, c: 8 }
};
let buf: [byte; 40] = [0; 40];
let q: *Pkt = ptr_from(ptr_addr(buf.ptr));
q.kind = -3;
q.seq = -2;
q.total = -70000;
q.wide.lo = 0xDEADBEEF;
q.wide.mid = 0xABCD;
q.wide.flag = true;
q.wide.top = true;
q.small.a = 9;
q.small.c = 200;
q.small.b = 3;
q.ratio = 2.5;
q.ptr = ptr_from(ptr_addr(buf.ptr) + 1);
puts(tostring(sizeof(Pkt)) + "\n");
puts(tostring(q.kind) + " " + tostring(q.seq) + " " + tostring(q.total) + "\n");
puts(tostring(buf[1]) + " " + tostring(buf[2]) + " " + tostring(buf[3]) + " " + tostring(buf[6]) + "\n");
puts(tostring(q.wide.lo) + " " + tostring(q.wide.mid) + " " + tostring(q.wide.flag) + " " + tostring(q.wide.top) + "\n");
puts(tostring(q.small.a) + " " + tostring(q.small.b) + " " + tostring(q.small.c) + "\n");
puts(tostring(q.ratio * 2.0) + " " + tostring(*q.ptr) + "\n");
q.wide.mid = 1;
puts(tostring(q.wide.lo) + " " + tostring(q.wide.mid) + " " + tostring(q.wide.flag) + " " + tostring(q.wide.top) + "\n");
q.wide.flag = false;
puts(tostring(q.wide.mid) + " " + tostring(q.wide.flag) + " " + tostring(q.wide.top) + "\n");

def bump(p: *Pkt) -> long { p.seq = p.seq + 1; p.seq };
def peek(p: Pkt) -> long { p.total };
puts(tostring(bump(q)) + " " + tostring(peek(q)) + "\n");
let own: Pkt = { kind: 5, total: 7 };
puts(tostring(peek(own)) + " " + tostring(own.kind) + " " + tostring(bump(own)) + "\n");
let w: Wide = { lo: 1, top: true };
puts(tostring(w.lo) + " " + tostring(w.top) + " " + tostring(sizeof(Wide)) + "\n");
