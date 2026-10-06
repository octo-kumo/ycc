// The spellings that work, next to the one that does not: Y writes a
// character literal `c'a'` and a byte string `b'a'`, and a bare `'a'` is
// neither (e169 says so, at the apostrophe, naming these).
let q: long = c'q';
let nl: long = c'\n';
let bs: long = c'\\';
print(q, " ", nl, " ", bs);

// a character literal is a byte, so it compares against a long directly and
// needs an annotation to become one
def is_quit(k: long) -> bool { if (k == c'q') { true } else { false } };
print(is_quit(113));

// a byte string is [byte]
let bs2: [byte] = b'ab';
print(len(bs2), " ", tostring(bs2[0]));

// an apostrophe where one is allowed: a comment, and a double-quoted string
// the caller's palette, and Y's heap is an arena
let s = "it's fine";
print(s);

// and an apostrophe inside a double-quoted f-string field
let name = "ann";
print(f"it's {name}");