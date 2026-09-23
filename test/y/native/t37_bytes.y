// byte: an 8-bit unsigned integer. [byte] arrays are PACKED — one byte per
// element, not one machine word.
let s = "Hello";
let b = bytes(s);
print(len(b));
print(b[0]);
print(b[4]);
print(from_bytes(b));
print(tostring(b));

// byte widens to long in arithmetic, and long narrows at annotated sites
let first: byte = b[0];
let sum = first + 1;
print(sum);
print(first);

// an array literal adopts the annotated element type
let lit: [byte] = [104, 105, 33];
print(from_bytes(lit));
print(tostring(lit));
print(len(lit));

// every array operation is width-aware: index, assign, slice, foreach,
// push, equality, join
lit[0] = 72;
print(from_bytes(lit));
print(from_bytes(lit[0:2]));
print(from_bytes(lit[1:]));
foreach (x in lit) { puts(tostring(x) + " "); };
puts("\n");
print(join(lit, "-"));

let same: [byte] = [72, 105, 33];
print(lit == same);
let diff: [byte] = [72, 105];
print(lit == diff);

// push grows a packed array correctly across a reallocation
let acc: [byte] = [];
let i = 0;
while (i < 40) {
    acc = push(acc, 97 + i % 26);
    i = i + 1;
};
print(len(acc));
print(from_bytes(acc));

// [v; n] with a byte element type (fixed arrays are native-only syntax,
// so this file is checked against its .expected, not against the VM)
let zeros: [byte; 4] = [0; 4];
print(tostring(zeros));
zeros[2] = 255;
print(tostring(zeros));

// round trip through a function boundary
def upper(src: [byte]) -> [byte] {
    let out: [byte] = [];
    let j = 0;
    while (j < len(src)) {
        let c = src[j];
        if (c >= 97) { if (c <= 122) { c = c - 32; }; };
        out = push(out, c);
        j = j + 1;
    };
    out
};
print(from_bytes(upper(bytes("mixed Case 123"))));

// values above 127 stay unsigned
let high: [byte] = [200, 255, 128];
print(tostring(high));
print(high[1]);

// grow across many reallocations and verify every element survives
let big: [byte] = [];
let k = 0;
while (k < 5000) { big = push(big, (k % 255) + 1); k = k + 1; };
print(len(big));
let ok = true;
k = 0;
while (k < 5000) {
    if (big[k] != (k % 255) + 1) { ok = false; };
    k = k + 1;
};
print(ok);
print(tostring(big[1000:1006]));

// round trip through str is lossless for NUL-free data (an embedded 0
// would truncate in the VM, whose str is a C string — see NATIVE.md)
print(len(bytes(from_bytes(big))));
print(bytes(from_bytes(big)) == big);

// empty and single-element edges
let e: [byte] = [];
print(len(e));
print(tostring(e));
print(join(e, ","));
print(tostring(e[0:0]));
let one: [byte] = [7];
print(tostring(one[0:1]));
print(tostring(one[1:1]));

// reference semantics: a write through an alias is visible
let al = one;
al[0] = 9;
print(one[0]);
