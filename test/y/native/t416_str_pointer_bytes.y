// A str used as a *T, and ptr_addr of a str, address the string's BYTES (not
// its length header), at every place a value meets a declared pointer type.
type Holder = { p: *byte };
let g: *byte = "global";

def first(p: *byte) -> byte { *p };
def give(s: str) -> *byte { s };
def at(p: *byte, i: long) -> byte { *(p + i) };

let s = "hello";
let t = "ab" + "cd";                     // an owned (heap) string

let p: *byte = s;                        // an annotated let
puts(tostring(*p) + " " + tostring(*g) + "\n");
puts(tostring(first(s)) + " " + tostring(first(t)) + "\n");   // a parameter
puts(tostring(*give(t)) + "\n");         // a return value
puts(tostring(at(s, 4)) + " " + tostring(at(t, 3)) + "\n");

let h: Holder = { p: s };                // a record field
puts(tostring(*h.p) + "\n");
h.p = t;                                 // a field store
puts(tostring(*h.p) + "\n");

let ps: [*byte] = [s, t];                // array elements
ps += "xyz";
puts(tostring(*ps[0]) + " " + tostring(*ps[1]) + " " + tostring(*ps[2]) + "\n");

let fv = first;                          // through a function value
puts(tostring(fv(s)) + "\n");
def pick(c: bool) -> *byte { if (c) { return s; }; t };
puts(tostring(*pick(true)) + " " + tostring(*pick(false)) + "\n");
let lam = (x: *byte) => *x;              // a lambda's parameter
puts(tostring(lam(t)) + "\n");

let q: *byte = t;
let pp: **byte = &q;
*pp = s;                                 // a pointee store
puts(tostring(*q) + "\n");
q = t;                                   // a plain assignment
puts(tostring(*q) + "\n");

// ptr_addr of a str is the address of its first byte, and agrees with the
// coercion and with what syscall writes
let ps0: *byte = s;
puts(tostring(ptr_addr(s) == ptr_addr(ps0)) + "\n");
os_call("y_os_write", 1, ptr_addr(s), 5);
os_call("y_os_write", 1, ptr_addr(t), 4);
os_call("y_os_write", 1, s, 1);
puts("\n");

// through a type alias of str
type Name = str;
let nm: Name = "zed";
let pn: *byte = nm;
puts(tostring(*pn) + " " + tostring(first(nm)) + "\n");
os_call("y_os_write", 1, ptr_addr(nm), 3);
puts("\n");
