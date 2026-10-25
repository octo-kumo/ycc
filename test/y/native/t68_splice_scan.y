/* t68: the splice-trigger scan (native.y words_seen) reads the text the
   way the lexer does. Before it, a block comment like this one hid every
   call after it, and the readline() below failed to compile with
   "undefined function 'readline'". */
let first = readline();
print(first!);
// A `//` inside a string literal is not a comment: the method call later
// on the same line still splices std/str.y.
print("http://example.com/a/b".count("/"));
// Blanks and comments may sit between the dot, the name and the paren.
let s = "abc";
print(s . /* dot */ upper /* paren */ ());
print(s.
    pad_left // the width comes next
    (5, "."));
// A trigger name inside a literal or as a plain variable is just text.
let count = 2;
print("s.repeat(", count, ")");
print("ab".repeat(count));
