// Python-style byte reprs: printable ASCII verbatim; quote and backslash
// escaped; \n \r \t as escapes; every other byte \xHH (lowercase).
print(b"hello world");
print(b"~");
print(b"");
print(b"\x01\x02\x1f\x7f\x80\xff");
print(b"'\"\\");
print(b"\n\r\t");
print(b"a\nb");

// slicing keeps bytes intact
let m = b"\x00ABC\xff";
print(m);
print(len(m));
print(m[1:4]);
print(m[1:4] + b"!");
