// scan.y -- the span scanner: every kind, and the cases the lexer cannot serve.
//
// The point of the fixture is the last third: an f-string (which tokenize
// desugars, so its stream has no usable spans), comments (which tokenize
// discards), and unterminated literals (which make tokenize exit(1)).

import scan from "../scan.y";

// Print a span list as `kind[text]`, so a diff shows both the classification
// and the extent.
def show(src: str, sps: [Span]) -> str {
    let out: [str] = [];
    foreach (s in sps) {
        out += scan.kind_name(s.kind) + "[" + src[s.off:s.end] + "]";
    }
    ",".join(out)
}

def one(src: str) -> str { show(src, scan.scan(src)) }

// ── the easy kinds ──────────────────────────────────────────────────────
print(one("let x = 1;"));
print(one("const y: long = 2;"));
print(one("def f(a: long) -> long { a }"));
print(one("if x == 1 { y } else { z }"));
print(one("while i < 10 { i = i + 1; }"));
print(one("foreach (k in ks) { print(k); }"));
print(one("return true;"));
// break/continue are keywords (2025), so the highlighter must not paint them
// as names. This case exists because the corpus had no BARE occurrence of
// either word -- src/y only ever spells them inside string literals -- so
// drv_scan_agree passed with is_keyword missing both, and the disagreement
// would have surfaced only in a file a user wrote.
print(one("while i < 10 { if i == 5 { break; } continue; }"));
print(one("for (let k = 0; k < 3; k++) { if (k) { continue; } break; }"));

// numbers: decimal, float, exponent, radix, grouping
print(one("1"));
print(one("1.5"));
print(one("1e10"));
print(one("1E-10"));
print(one("0x1f"));
print(one("0b1010_1010"));
print(one("1_000_000"));
print(one("3.14159"));

// operators are longest-match-first
print(one("a >> b"));
print(one("a >>= b"));
print(one("a >>> b"));
print(one("a >>>= b"));
print(one("a <<= b"));
print(one("a == b != c <= d >= e"));
print(one("a && b || !c"));
print(one("a += b -= c *= d /= e %= f"));
print(one("a & b | c ^ d ~ e"));
print(one("a .. b"));
print(one("a ?. b"));
print(one("m::x"));
print(one("def f() -> long { 1 }"));      // -> is one operator

// punctuation
print(one("(a, b);"));
print(one("{ k: v }"));

// contextual words are words, not keywords
print(one("match x { A => 1 }"));
print(one("spawn { 1 }"));
print(one("let m = mutex(); lock m { }"));
print(one("self.x"));

// ── comments: tokenize throws these away ────────────────────────────────
print(one("// a line comment"));
print(one("let x = 1; // trailing"));
print(one("/* a block comment */"));
print(one("/* multi\n   line */"));
print(one("/* one */ let /* two */ x = 1;"));
// block comments do not nest
print(one("/* a /* b */ c"));
// `/` and `/=` are operators, not comment openers
print(one("a / b"));
print(one("a /= b"));
print(one("a / // c\n b"));

// ── strings: every literal form, including the prefixes ────────────────
print(one("\"plain\""));
print(one("\"with \\\"escape\\\"\""));
print(one("'single'"));
print(one("b\"bytes\""));
print(one("b'bytes'"));
print(one("c'a'"));          // the removed spelling: one error span
print(one("\"\"\"line\nline\"\"\""));
print(one("f\"\"\"x = {x}\nmore\"\"\""));
print(one("129b"));
print(one("0b10001b"));
print(one("\"tab\\there\""));
print(one("\"\\x41\\n\""));

// ── f-strings: the reason this scanner exists ───────────────────────────
// tokenize() desugars these during lexing, so its stream has no span for the
// literal at all. Here the whole f-string is one span.
print(one("f\"plain\""));
print(one("f\"x = {x}\""));
print(one("f\"{a}{b}{c}\""));
print(one("f\"{d[\"k\"]}\""));            // a nested quoted run inside a field
print(one("f\"{s[1:3]}\""));
print(one("f\"{n == 1 ? \"y\" : \"n\"}\""));  // a ternary with strings
print(one("f\"{a[0]} and {b[1]}\""));
print(one("f\"{{literal brace}}\""));
print(one("f\"\\n{x}\\n\""));

// ── tolerance: an unterminated literal is an error span, not a crash ───
let r1 = scan.scan_full("let x = \"unterminated");
print(show("let x = \"unterminated", r1.spans));
print(len(r1.bad));
print(scan.kind_name(r1.bad[0].kind));

let r2 = scan.scan_full("/* never closed");
print(show("/* never closed", r2.spans));
print(len(r2.bad));

let r3 = scan.scan_full("let x = 'abc");
print(len(r3.bad));

// a stray byte no token starts with
let r4 = scan.scan_full("a @ b");
print(show("a @ b", r4.spans));
print(len(r4.bad));

// repair closes the literal so the compiler can still read the document
let p1 = scan.repair("{\"a\": \"oops}");
print(p1.text);
print(len(p1.bad));
let p2 = scan.repair("/* oops");
print(p2.text);
let p3 = scan.repair("let a = \"x\"; let b = 1;");
print(p3.text);
print(len(p3.bad));

// ── line and column tracking, and the byte offsets ─────────────────────
let multi = "let a = 1;\nlet b = 2;\n\n/* x\n y */ let c = 3;";
let sps = scan.scan(multi);
foreach (s in sps) {
    // no `continue` in Y either, so the test is the condition
    if (s.off != s.end) {
        print(scan.kind_name(s.kind) + " @" + tostring(s.line) + ":" + tostring(s.col));
    };
}

// a span's line/col are the compiler's: 1-based, column in BYTES
let uni = "let s = \"café\"; let t = 1;";
let us = scan.scan(uni);
foreach (s in us) {
    print(scan.kind_name(s.kind) + " @" + tostring(s.line) + ":" + tostring(s.col));
}

// line_starts / off_at: the table that recovers byte offsets, which Tok does
// not carry at all
print(scan.line_starts("a\nbb\nccc"));
print(scan.off_at("a\nbb\nccc", 1, 1));
print(scan.off_at("a\nbb\nccc", 2, 1));
print(scan.off_at("a\nbb\nccc", 3, 3));
print(scan.off_at("a\nbb\nccc", 4, 1));
print(scan.off_at("a\nbb\nccc", 0, 1));

// and it agrees with the span positions it produced
let agree = 1;
foreach (s in sps) {
    if (s.off != scan.off_at(multi, s.line, s.col)) { agree = 0; }
}
print(agree);

// ── empty and degenerate input ──────────────────────────────────────────
print(one(""));
print(one("   \n\t "));
print(one("\n\n"));
print(len(scan.scan("")));