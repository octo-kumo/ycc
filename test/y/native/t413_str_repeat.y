// `s.repeat(n)` is one zeroed buffer (prelude.s y_bytes_zero), one copy of s,
// and one forward copy that repeats it (y_copy_fwd): byte by byte for a short
// s, a word at a time for one of eight bytes or more.
print("ab".repeat(5));
print("x".repeat(0).length);
print("abcdefghij".repeat(3));
print("-".repeat(20));
print("7".pad_left(5, "0"));
print("q".repeat(-3).length);
let big = "xyz".repeat(100000);
print(big.length);
print(big[299997:]);
print("".repeat(4).length);
