// expect-error: 9:10: error: a character literal is spelled c'a' (a byte string b'a'); a bare ' is not one
// expect-error: 11:10: error: a character literal is spelled c'b' (a byte string b'b'); a bare ' is not one
// A bare apostrophe inside an f-string field is the same mistake as one
// outside it, and is now said so, where it is. A field is tokenized on its
// own, so the apostrophe used to end the f-string instead: the reader was
// told `1:5: error: puts takes exactly 1 argument` about a call that passes
// one argument, and `1:11: error: expected ';', got 'a'` about a token
// three columns from the mistake.
puts(f"[{'a'}]");

print(f"{'b'}");