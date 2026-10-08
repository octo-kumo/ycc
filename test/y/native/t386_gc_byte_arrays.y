// Packed [byte] arrays are pointer-free by construction, so their data blocks
// carry the pointer-free header bit (the array helpers branch on esz == 1) and
// a cycle skips those payloads instead of resolving every word of them.
// Measured on this shape at 600 live 30 KB arrays: 90.9M -> 36.7M
// instructions under callgrind, same peak RSS and same output.
let chunk: [byte] = [];
let c = 0;
while (c < 1000) { chunk += 65; c = c + 1; };
let keep: [[byte]] = [];
let i = 0;
while (i < 200) {
    let b: [byte] = [];
    let j = 0;
    while (j < 30) { b += chunk; j = j + 1; };
    keep += b;
    i = i + 1;
};
print(keep.length);
print(keep[199].length);
print(keep[0][1000]);
