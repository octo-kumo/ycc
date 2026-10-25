// W4/S8: --web-checked guards every memory access (addr >>u 32 != 0 traps
// with SIGSEGV) and must not change what a correct program does.  This one
// touches the stack, arrays, strings, maps and records, and prints the same
// answer as the unchecked build (w014_web_checked.cflags holds the flag).
import fs;

let total = 0;
let i = 0;
while (i < 2000) {
    let s = "n" + tostring(i);
    total = total + s.length;
    let a: [long] = [];
    let j = 0;
    while (j < 4) { a += i + j; j = j + 1; };
    total = total + a[3];
    i = i + 1;
};
print(total, "\n");
let m = { "k": 1, "j": 2 };
m["k"] = m["k"]! + 40;
print(m["k"]!, " ", m["j"]!, "\n");
let r = { name: "rec", n: 7, vals: [1, 2, 3] };
print(r.name, " ", r.n, " ", r.vals[2], "\n");
let f = 1.5;
let g = f * 2.0 + 0.25;
print(g, "\n");
print(fs.path_join("a", "b"), "\n");
let bytes = "abc".bytes();
print(bytes.length, " ", bytes[1], "\n");
