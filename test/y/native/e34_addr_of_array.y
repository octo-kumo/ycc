// expect-error: cannot take the address of a whole array
// &a is the address of the slot holding the array's {len,cap,data}
// header, not of its elements: handing it to read(2) let the kernel
// write over the frame. Use &a[0]. (A heap array was already rejected;
// a fixed one slipped through and `syscall(0, fd, &buf, n)` compiled.)
let fixed: [long; 4] = [0; 4];
let p = &fixed;
print(p);
let heap = [0; 4];
let q = &heap;
print(q);
