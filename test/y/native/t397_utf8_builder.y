// utf8.Builder: pushes append in place and allocate nothing per glyph; build
// makes the one str. Checked against chr/utf8.chr/tostring.
import utf8;
let sb = utf8.builder();
utf8.push_str(sb, "x=");
utf8.push_long(sb, 0);
utf8.push_byte(sb, ' ');
utf8.push_long(sb, -9223372036854775807 - 1);
utf8.push_byte(sb, 32);
utf8.push_long(sb, 9223372036854775807);
utf8.push_byte(sb, 32);
utf8.push_long(sb, -105);
utf8.push_byte(sb, 256 + 33);
utf8.push_cp(sb, 65);
utf8.push_cp(sb, 0xe9);
utf8.push_cp(sb, 0x2588);
utf8.push_cp(sb, 0x1F600);
utf8.push_cp(sb, -1);
utf8.push_cp(sb, 0x110000);
let s = utf8.build(sb);
print(s);
print(s == "x=0 " + tostring(-9223372036854775807 - 1) + " 9223372036854775807 -105!A" + utf8.chr(0xe9) + utf8.chr(0x2588) + utf8.chr(0x1F600));
print(len(s));
utf8.push_str(sb, "!");
print(len(utf8.build(sb)));
utf8.reset(sb);
print(len(utf8.build(sb)));
// 100k glyphs: the buffer grows by doubling, so the heap grows by about the
// final size, not by a string per push
let big = utf8.builder();
let h0 = heap_used();
for i in 0..100000 { utf8.push_cp(big, 0x2588); utf8.push_long(big, i % 10); };
let grown = heap_used() - h0;
print(len(utf8.build(big)));
print(grown < 3000000);
