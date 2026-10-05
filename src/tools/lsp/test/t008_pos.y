// pos.y -- the conversion, checked against the cases that break a naive one.

import pos from "../pos.y";
import json from "../../../y/std/json.y";

def show(label: str, v: Pos) -> str {
    label + " -> " + tostring(v.line) + ":" + tostring(v.character)
}

// ASCII: the identity
let a = "let x = 1;\nprint(x);\n";
print(show("ascii 1:1", pos.to_lsp(a, 1, 1)));
print(show("ascii 1:5", pos.to_lsp(a, 1, 5)));
print(show("ascii 2:1", pos.to_lsp(a, 2, 1)));

// A 2-byte character: e-acute, U+00E9. The byte column is 1 past it; the
// character column is also 1 past it, because it is ONE utf16 unit.
let b = "let s = \"café\";\nprint(s);\n";
print(show("2-byte at 1:1", pos.to_lsp(b, 1, 1)));
print(show("2-byte at 1:12 (before e)", pos.to_lsp(b, 1, 12)));
print(show("2-byte at 1:13 (on e)", pos.to_lsp(b, 1, 13)));
print(show("2-byte at 1:14 (2nd byte of e)", pos.to_lsp(b, 1, 14)));
print(show("2-byte at 1:16 (the semicolon)", pos.to_lsp(b, 1, 16)));

// A 3-byte character: euro, U+20AC
let c = "let s = \"€9\";\nprint(s);\n";
print(show("3-byte at 1:11 (before)", pos.to_lsp(c, 1, 11)));
print(show("3-byte at 1:14 (after)", pos.to_lsp(c, 1, 14)));

// A 4-byte character: U+1F600, which is a SURROGATE PAIR in utf16 -- two code
// units for one codepoint, and the case that makes a byte offset and a
// character offset diverge hardest.
let emoji = from_bytes(json.utf8_put([], 128512));   // U+1F600, 4 bytes
let d = "let s = \"" + emoji + "\";\nprint(s);\n";
print(show("4-byte at 1:11 (before)", pos.to_lsp(d, 1, 11)));
print(show("4-byte at 1:15 (on it)", pos.to_lsp(d, 1, 15)));
print(show("4-byte at 1:18 (after)", pos.to_lsp(d, 1, 18)));

// mixed, and a tab that is one byte and one unit
let e = "let é = 1; let " + emoji + " = 2;\n";
print(show("mixed 1:1", pos.to_lsp(e, 1, 1)));
print(show("mixed 1:5 (on e-acute)", pos.to_lsp(e, 1, 5)));
print(show("mixed 1:15", pos.to_lsp(e, 1, 15)));

// the other direction: from_lsp gives the byte column, src_line the line
print("src_line(0) = " + tostring(pos.src_line(0)) + "  src_line(9) = " + tostring(pos.src_line(9)) + "  src_line(-1) = " + tostring(pos.src_line(-1)));
print("back ascii 0:4 -> col " + tostring(pos.from_lsp(a, 0, 4)));
print("back 2byte 0:12 -> col " + tostring(pos.from_lsp(b, 0, 12)));
print("back 4byte 0:14 -> col " + tostring(pos.from_lsp(d, 0, 14)));

// round trip on every byte offset of a line with both a 2- and a 4-byte char
let f = "aé" + emoji + "z";
print("bytes " + tostring(len(f)) + "  chars " + tostring(pos.u16_len(f, len(f))));
// The invariant that matters: to_lsp and from_lsp are inverses at every
// position that NAMES something. Two kinds of offset name nothing and are
// correctly not invertible, and both are worth pinning:
//   - a byte offset inside a multi-byte character (between the two bytes of e)
//   - a low surrogate, which is half of one codepoint and has no bytes at all
let text = "x" + f;
let starts_ok = 1;
let i = 0;
while (i < len(text)) {
    let c = byte_at(text, i);
    let cont = (c & 192) == 128;              // a UTF-8 continuation byte
    if (!cont) {
        let lsp = pos.to_lsp(text, 1, i + 1);
        let back = pos.from_lsp(text, 0, lsp.character);
        if (back != i + 1) { starts_ok = 0; }
    }
    i = i + 1;
}
print("round trip at every character start: " + tostring(starts_ok));

// every character index is reachable, and lands on itself or -- for the low
// surrogate of a pair -- on the codepoint after it, never before
let idx_ok = 1;
let u = 0;
while (u <= pos.u16_len(f, len(f))) {
    let back = pos.from_lsp(text, 0, u);
    let again = pos.to_lsp(text, 1, back);
    if (again.character < u) { idx_ok = 0; }
    if (again.character > u + 1) { idx_ok = 0; }
    u = u + 1;
}
print("every character index reachable: " + tostring(idx_ok));


// a line that does not exist, and a column past the end
print(show("line 99", pos.to_lsp(a, 99, 1)));
print(show("col 999", pos.to_lsp(a, 1, 999)));
print("line_bytes(2) = [" + pos.line_bytes(a, 2) + "]");
print("line_bytes(9) = [" + pos.line_bytes(a, 9) + "]");

// CRLF: the \r is a byte and one character, and it belongs to the line
let g = "let x = 1;\r\nprint(x);\r\n";
print(show("crlf 1:1", pos.to_lsp(g, 1, 1)));
print(show("crlf 1:11 (the CR)", pos.to_lsp(g, 1, 11)));
print(show("crlf 2:1", pos.to_lsp(g, 2, 1)));