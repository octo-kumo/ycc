// Pointer-free string buffers (y_alloc_pf: y_str_cat/y_str_app/... mark the
// payload so the collector skips it) must be recycled correctly: the contents
// of a reused block have to survive the next allocation.
let keep: [str] = [];
let i = 0;
while (i < 2000) {
    keep += "abcdefghij" + tostring(i);
    if (len(keep) > 3) { keep = keep[len(keep) - 3:len(keep)]; };
    i++;
};
print(keep.length);
print(keep[0]);
print(keep[2]);
