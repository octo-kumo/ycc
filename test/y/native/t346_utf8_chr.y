// `chr` (the builtin) is the inverse of `ord`, and `ord` reads a BYTE, so
// `chr(9608)` is 0x88 -- one byte -- and not the block U+2588 it looks like.
// std/utf8.y is the sibling that makes the glyph, in
// every width, and it builds a `str`, which is the thing a renderer could not
// do at all before: a frame of text had to go through a byte buffer.
import utf8;
print(len(utf8.chr(65)), byte_at(utf8.chr(65), 0));
print(len(utf8.chr(9608)), len(chr(9608)));
let block = utf8.chr(9608);
print(byte_at(block, 0), byte_at(block, 1), byte_at(block, 2));
print(utf8.len_of(65), utf8.len_of(9608), utf8.len_of(0x1F600), utf8.len_of(-1));
print(len(utf8.chr(0xA9)), len(utf8.chr(0x20AC)));
print(len(utf8.chr(0x1F600)), len(utf8.chr(0x10FFFF)));
print(len(utf8.chr(0)), byte_at(utf8.chr(0), 0));
print(len(utf8.chr(-1)), len(utf8.chr(0x110000)));
let row = "";
let i = 0;
while (i < 4) { row += utf8.chr(0x2588); i = i + 1; };
print(len(row), byte_at(row, 3));
puts(row + "\n");
print("q" + utf8.chr(9608) == "q" + block);
// Decoding is the other direction, and an invalid byte is U+FFFD, one per
// position: a caller never gets a trap and never loses sync.
let cs = utf8.codes("a\xc2\xa9\xe2\x96\x88");
print(len(cs), cs[1], cs[2]);
let bad = utf8.codes("a\xffb");
print(len(bad), bad[1], bad[2]);
