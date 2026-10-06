// expect-error: 11:15: error: a character literal is spelled c'a' (a byte string b'a'); a bare ' is not one
// expect-error: 12:15: error: a character literal is spelled c'b' (a byte string b'b'); a bare ' is not one
// A bare apostrophe is not a character literal: Y spells one `c'a'` (a
// `byte`) and a byte string `b'a'`. Said at the apostrophe, naming the
// spelling, and as ONE token over the '...' the reader wrote -- 'a' is one
// mistake. Before, the apostrophe was an `op` token, so the parser reported
// a missing expression and then charged the closing quote a message of its
// own (`expected ')', got 'q'`), and a second pair in a file made the next
// `b` or `c` word take the byte-string arm and scan to end of file: a
// position-less fatal "unterminated string literal".
let x: long = 'a';
let y: long = 'b';