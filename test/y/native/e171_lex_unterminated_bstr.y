// expect-error: 9:7: error: unterminated byte string
// expect-error: 10:11: error: unexpected end of input (expected ',' or ')')
// An unterminated `b"..."`: the literal's own name, at the column it starts.
// `lex_quoted` used to print and exit from the lexer's own top level, so
// this carried no line and no column and named no literal; it now comes
// back as a `ferr` token, which the parser turns into an error in place --
// the shape a broken f-string and `0x` already had. The rest of the file is
// inside the unclosed literal, so this is one per file.
print(b"abc);
print(2);