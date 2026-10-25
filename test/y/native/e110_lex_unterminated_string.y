// expect-error: 9:7: error: unterminated string literal
// expect-error: 9:23: error: unexpected end of input (expected ',' or ')')
// An unterminated `str` literal, at the column it starts. `lex_quoted` used
// to print and exit from the lexer's own top level, so this carried no line
// and no column at all; it now comes back as a `ferr` token, which the
// parser turns into an error in place -- the shape a broken f-string and
// `0x` already had, so the rest of the file is still read and still
// reported.
print("unterminated);