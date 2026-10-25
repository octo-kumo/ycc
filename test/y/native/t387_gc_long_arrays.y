// [long] array data cannot hold a reference, so the operations that build it
// (a literal, arr[lo:hi], array + element, array + array and arr += other)
// mark the data block pointer-free and a cycle skips its payload instead of
// resolving every word. Measured on this shape at 200 arrays of 12288 longs:
// 146.0M -> 100.7M callgrind instructions, same output and peak RSS.
let keep: [[long]] = [];
let i = 0;
while (i < 60) {
    let b: [long] = [i, i + 1, i + 2];
    let j = 0;
    while (j < 10) { b = b + b; j = j + 1; };
    keep += b;
    i = i + 1;
};
print(keep.length);
print(keep[59].length);
print(keep[0][0]);
print(keep[59][3071]);
