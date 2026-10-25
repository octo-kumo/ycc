// A word that points one byte into a block (here `a.ptr + 1`, held in a
// global the collector scans) is not a pointer to the block's start. The
// start map has a bit per 8 bytes, so an unaligned candidate `word - 8` used
// to alias the block's real bit, pass, and get a mark bit OR'd into the middle
// of its header ("collector: bad block header" at the next sweep, or a crash).
// The block has to look like a plausible header at an odd offset (a size
// between 256 and 511 bytes, a non-zero first payload byte), hence 200 bytes.
let a: [byte] = [];
for k in 0..200 { a += 10; };
let p: *byte = a.ptr + 1;
let keep: [str] = [];
let i = 0;
while (i < 400000) {
    keep += "abcdefghij" + tostring(i);
    if (len(keep) > 8) { keep = keep[len(keep) - 3:len(keep)]; };
    i++;
};
print(keep.length);
print(*p);
print(a[7]);
