// ptr_from(n) is the inverse of ptr_addr: the pointer whose address is n.
// The pointee type comes from the annotation or the parameter it meets.
let w: long = 0;
let a = ptr_addr(&w);

let p: *long = ptr_from(a);
*p = 42;
puts(tostring(w) + " " + tostring(*p) + "\n");
puts(tostring(ptr_addr(p) == a) + "\n");

// a byte view of the same word, and arithmetic on a pointer made from a long
let q: *byte = ptr_from(a);
puts(tostring(*q) + "\n");
let q1: *byte = ptr_from(a + 1);
*q1 = 1;
puts(tostring(w) + "\n");
puts(tostring(q1 - q) + "\n");

// as an argument, and as a byte-sized integer
def peek(p: *long) -> long { *p };
puts(tostring(peek(ptr_from(a))) + "\n");
let b: byte = 7;
let r: *long = ptr_from(ptr_addr(&w) + b - b);
puts(tostring(*r) + "\n");
