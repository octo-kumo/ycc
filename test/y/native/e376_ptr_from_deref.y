// expect-error: ptr_from has no pointee type to read or write through; bind it first: let p: *T = ptr_from(n)
let v = *ptr_from(4096);
puts("no\n");
