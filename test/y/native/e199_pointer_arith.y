// expect-error: cannot add *long and *long (pointer arithmetic needs a pointer and a long/byte offset)
// expect-error: pointer subtraction needs identical pointer types, got *long and *byte
// expect-error: pointers support only '+=' and '-=' offsets, not '*='
// expect-error: cannot add *long and *byte (pointer arithmetic needs a pointer and a long/byte offset)
// expect-error: cannot subtract *long from long (pointer arithmetic needs a pointer and a long/byte offset)
// expect-error: '<' compares *long with *byte (pointer ordering needs identical pointer types)
// expect-error: '+=' offset: expected long, got *byte
let a = [1, 2];
let b = [3, 4];
let bytes: [byte; 2] = [5, 6];
let p = a.ptr;
let q = b.ptr;
let r: *byte = &bytes[0];
print(p + q);
print(p - r);
p *= 2;
print(p + r);
print(1 - p);
print(p < r);
p += r;
