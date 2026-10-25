// A character literal is `'a'` -- one byte, typed byte -- and a byte STRING
// is `b'a'`. The old `c'a'` prefix is gone, with a diagnostic that says so
// (e193 covers the new literal errors; this is the spellings that work).
let q: long = 'q';
let nl: long = '\n';
let bs: long = '\\';
print(q, " ", nl, " ", bs);

// a character literal is a byte, so it compares against a long directly and
// needs an annotation to become one
def is_quit(k: long) -> bool { if (k == 'q') { true } else { false } };
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

// the removed spelling, as an ERROR (its own fixture keeps the message)
// c'q' is no longer a character literal: an identifier c, then a literal