// mmap, munmap, mprotect, brk, madvise, getrandom.
def check(name: str, ok: bool) -> void {
    if (ok) { print(name + ": ok"); } else { print(name + ": FAIL"); };
};
const ANON = 34;   // MAP_PRIVATE | MAP_ANONYMOUS
const FIXED = 16;

// anonymous memory is zero and writable, in a region the kernel picks
let a = syscall(9, 0, 3 * 4096, 3, ANON, 0 - 1, 0);
check("mmap", a > 0 && a % 4096 == 0);
let p: *long = ptr_from(a);
check("zeroed", *p == 0 && *(p + 1536) == 0);
*p = 111;
*(p + 1024) = 222;
*(p + 1534) = 333;
check("written", *p == 111 && *(p + 1024) == 222 && *(p + 1534) == 333);

// a second mapping does not overlap the first
let b = syscall(9, 0, 4096, 3, ANON, 0 - 1, 0);
check("second mmap apart", b > 0 && (b >= a + 3 * 4096 || b + 4096 <= a));

// munmap really unmaps: the same address comes back zeroed with MAP_FIXED
check("munmap", syscall(11, a, 3 * 4096) == 0);
let c = syscall(9, a, 3 * 4096, 3, ANON | FIXED, 0 - 1, 0);
check("mmap fixed", c == a);
check("fresh after munmap", *p == 0 && *(p + 1024) == 0 && *(p + 1534) == 0);

// a hole in the middle: unmap one page of three, the neighbours keep their data
*p = 7;
*(p + 1024) = 8;
*(p + 512) = 9;
check("punch hole", syscall(11, a + 4096, 4096) == 0);
check("neighbours kept", *p == 7 && *(p + 1024) == 8);
let d = syscall(9, 0, 4096, 3, ANON, 0 - 1, 0);
check("hole reusable", d > 0);

// mprotect: accepted, and PROT_NONE then RW again
check("mprotect none", syscall(10, a, 4096, 0) == 0);
check("mprotect rw", syscall(10, a, 4096, 3) == 0);
check("mprotect unaligned", syscall(10, a + 1, 4096, 3) == 0 - 22);
check("mprotect hole", syscall(10, 8589934592, 4096, 3) == 0 - 12);

// errors
check("mmap zero length", syscall(9, 0, 0, 3, ANON, 0 - 1, 0) == 0 - 22);
check("munmap unaligned", syscall(11, a + 5, 4096) == 0 - 22);

// a big sparse reservation costs nothing until touched
let big = syscall(9, 0, 1073741824, 3, ANON, 0 - 1, 0);
check("1 GB reserve", big > 0);
let bp: *long = ptr_from(big);
*(bp + 100000000) = 5;
check("1 GB touch", *(bp + 100000000) == 5 && *(bp + 5) == 0);
check("1 GB munmap", syscall(11, big, 1073741824) == 0);

// reuse: mapping and unmapping many times does not run the machine out of memory
let ok = true;
for i in 0..200 {
    let m = syscall(9, 0, 2097152, 3, ANON, 0 - 1, 0);
    if (m <= 0) { ok = false; } else {
        let q: *long = ptr_from(m);
        let k = 0;
        while (k < 512) { *(q + k * 64) = k; k += 1; };
        syscall(11, m, 2097152);
    };
};
check("200 map/touch/unmap cycles", ok);

// madvise(DONTNEED) zeroes
let e = syscall(9, 0, 8192, 3, ANON, 0 - 1, 0);
let ep: *long = ptr_from(e);
*ep = 99;
check("madvise", syscall(28, e, 8192, 4) == 0);
check("madvise zeroed", *ep == 0);

// brk: grows, keeps data, shrinks
let b0 = syscall(12, 0);
check("brk query", b0 > 0);
let b1 = syscall(12, b0 + 20000);
check("brk grow", b1 == b0 + 20000);
let hp: *long = ptr_from(b0);
*hp = 4242;
*(hp + 2000) = 2424;
check("brk memory", *hp == 4242 && *(hp + 2000) == 2424);
let b2 = syscall(12, b0);
check("brk shrink", b2 == b0);
let b3 = syscall(12, b0 + 4096);
check("brk regrow zero", b3 == b0 + 4096 && *hp == 0);
check("brk absurd", syscall(12, 4398046511104) == b3);

// getrandom: fills, differs between calls
let r1: [long; 4] = [0, 0, 0, 0];
let r2: [long; 4] = [0, 0, 0, 0];
check("getrandom len", syscall(318, &r1[0], 32, 0) == 32);
syscall(318, &r2[0], 32, 0);
check("getrandom nonzero", r1[0] != 0 || r1[1] != 0 || r1[2] != 0 || r1[3] != 0);
check("getrandom differs", r1[0] != r2[0] || r1[1] != r2[1]);
check("getrandom odd length", syscall(318, &r1[0], 13, 0) == 13);
