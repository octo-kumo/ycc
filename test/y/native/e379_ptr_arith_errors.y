// Pointer arithmetic and ordering need compatible operands.
// expect-error: 7:9: error: cannot subtract *long from long (pointer arithmetic needs a pointer and a long/byte offset)
// expect-error: 8:13: error: '<' compares *long with *byte (pointer ordering needs identical pointer types)
// expect-error: 10:3: error: '+=' offset: expected long, got float
let a: [long] = [1, 2];
let b: [byte] = [1, 2];
print(5 - a.ptr);
print(a.ptr < b.ptr);
let p = a.ptr;
p += 1.5;
