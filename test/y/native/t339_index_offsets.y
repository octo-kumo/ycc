// index_of/last_index_of with an OFFSET: "the next ) from here" without
// slicing the tail (a slice allocates a copy and returns an index into the
// copy). The one-argument forms are unchanged.
let s = "a(b)c(d)e";
print(s.index_of("("));
print(s.index_of("(", 2));
print(s.index_of("(", 4));
print(s.index_of("(", 5));
print(s.index_of("(", 99));
print(s.index_of("(", -3));
print(s.last_index_of("("));
print(s.last_index_of("(", 5));
print(s.last_index_of("(", 2));
print(s.last_index_of("(", 1));
print(s.last_index_of("(", 0));
print(s.last_index_of("(", -1));

// the builtin spellings take the same offset, and the two-argument form is
// the whole string for last_index_of (LONG_MAX is clamped) and 0 for
// index_of -- the C copy's ys() macro made these two defaults disagree once
print(index_of("abcabc", "b", 2));
print(last_index_of("abcabc", "b", 2));
print(index_of("abcabc", "bc"));
print(last_index_of("abcabc", "b"));
print(last_index_of("abcabc", "c"));

// an overlap, and the empty needle (never a match)
let t = "aaaa";
print(t.index_of("aa", 1));
print(t.last_index_of("aa", 2));
print(t.index_of(""));
print(t.last_index_of(""));

// the scanner use: each record's closing paren, from where the last ended
let line = "x(1)y(22)z(333)";
let i = 0;
while (true) {
    let close = line.index_of(")", i);
    if (close < 0) { i = len(line) + 1; } else {
        print("body=" + line[i + 1:close]);
        i = close + 1;
    };
    if (i > len(line)) { break; };
};
