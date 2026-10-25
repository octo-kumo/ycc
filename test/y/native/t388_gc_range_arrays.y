// range() returns [long], so the emitter marks the whole array pointer-free
// once (gen_range) and a cycle skips its payload. Measured on this shape at
// 400 ranges of 4000 longs: 127.1M -> 105.4M callgrind instructions, same
// output and peak RSS.
let keep: [[long]] = [];
let i = 0;
while (i < 200) {
    keep += range(3000);
    i = i + 1;
};
print(keep.length);
print(keep[199].length);
print(keep[199][2999]);
