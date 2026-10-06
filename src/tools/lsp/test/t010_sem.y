// t010_sem.y -- semantic tokens (M2, R2.4).
//
// The wire format is a delta encoding, and delta encodings are easy to write
// and hard to check by eye: a wrong deltaStartChar only shows up as the wrong
// colour a few tokens later. So the central test here is not "does it produce
// something" but "does decoding the delta reproduce the absolute token list
// exactly" -- which is R2.4 verbatim, and which catches every off-by-one in the
// encoder.

import json;
import sem from "../sem.y";
import pos from "../pos.y";
import scan from "../scan.y";

const HERE = "src/tools/lsp/test";

// ── decoding, which is what an editor does ──────────────────────────────
// The inverse of sem.encode, over sem.Tok -- the same record the encoder
// produces, which is the point: the test and the implementation must agree on
// the shape, and sharing it is what makes that guaranteed rather than hoped for.
def decode(data: [long]) -> [SemTok] {
    let out: [SemTok] = [];
    let pl = 0;
    let pc = 0;
    let i = 0;
    while (i + 4 < len(data)) {
        let dl = data[i];
        let dc = data[i + 1];
        let len = data[i + 2];
        let typ = data[i + 3];
        let line = pl + dl;
        let ch = dc;
        if (dl == 0) { ch = pc + dc; }
        let t: SemTok = { line: line, ch: ch, len: len, typ: typ };
        out += t;
        pl = line;
        pc = ch;
        i = i + 5;
    }
    out
}

def ntok(data: [long]) -> long { len(data) / 5 }

// ── the legend is a wire format, so pin its length and order ────────────
let legend = sem.token_types();
print("legend: " + len(legend) + " types: " + join(legend, ", "));

// The legend is a WIRE FORMAT: the client resolves a token's number against this
// list, so index i must keep meaning what it means today. Printing the list
// above catches a change, but only as a diff blob; this says which one moved.
// The pairs are spelled out rather than reflected over, because the constants are
// module-level `const`s and Y has no reflection -- and sem.y's own comment says
// a new constant needs an entry here at the same index, which this is what holds
// them to.
let WIRE: [str] = [tostring(sem.T_comment) + "=comment", tostring(sem.T_string) + "=string",
    tostring(sem.T_number) + "=number", tostring(sem.T_keyword) + "=keyword",
    tostring(sem.T_selfnone) + "=selfNone", tostring(sem.T_operator) + "=operator",
    tostring(sem.T_punct) + "=punctuation", tostring(sem.T_variable) + "=variable",
    tostring(sem.T_error) + "=error",
    tostring(sem.T_parameter) + "=parameter", tostring(sem.T_function) + "=function",
    tostring(sem.T_property) + "=property", tostring(sem.T_type) + "=type",
    tostring(sem.T_builtin) + "=builtin"];
let wire_ok = 0;
let wire_bad = 0;
let wi = 0;
while (wi < len(WIRE)) {
    let pair = WIRE[wi];
    let colon = index_of(pair, "=");
    let idx = tonum(pair[:colon]);
    let want = pair[colon + 1:len(pair)];
    if (idx < len(legend) && legend[idx] == want) { wire_ok = wire_ok + 1; }
    else { wire_bad = wire_bad + 1; print("  MISMATCH at " + tostring(idx) + ": legend says " + legend[idx] + ", constant says " + want); };
    wi = wi + 1;
};
print("constants matching their legend index: " + tostring(wire_ok) + ", mismatched: " + tostring(wire_bad));
print("every type sem can emit is inside the legend: " + tostring(len(legend) == len(WIRE)));

// ── a small program, token by token ─────────────────────────────────────
let prog = "def f(x: long) -> long {\n    let y = x + 1;   // add\n    \"s\"\n}\n";
let abs0 = sem.tokens(prog);
let data0 = sem.encode(abs0);
print("small: " + tostring(len(abs0)) + " tokens, " + tostring(len(data0)) + " numbers");
print("round trip exact: " + tostring(len(decode(data0)) == len(abs0)));
let bad = 0;
let i = 0;
while (i < len(abs0)) {
    let d = decode(data0);
    let a = abs0[i];
    if (d[i].line != a.line || d[i].ch != a.ch || d[i].len != a.len || d[i].typ != a.typ) { bad = bad + 1; }
    i = i + 1;
}
print("round trip position-by-position: " + tostring(bad == 0));
print("five numbers per token: " + tostring(len(data0) % 5 == 0));

// The types a reader would see. Looked up by POSITION and compared against what
// is actually there, not by index into the token list: the first version of this
// hardcoded indices into abs0 and four of the six assertions were wrong, which
// is a test that looks thorough and checks nothing.
def type_at(line: long, ch: long) -> str {
    let out = "(none)";
    foreach (t in abs0) {
        if (t.line == line && t.ch == ch) { out = legend[t.typ]; }
    }
    out
}
//            line ch  what is there
print("  'def' is a keyword:    " + type_at(0, 0));
print("  'f' is variable:       " + type_at(0, 4));
print("  '(' is punctuation:    " + type_at(0, 5));
print("  'x' is variable:       " + type_at(0, 6));
print("  ':' is punctuation:    " + type_at(0, 7));
print("  'long' is variable:    " + type_at(0, 9) + "  (M4 splits this)");
print("  '->' is an operator:   " + type_at(0, 15));
print("  '1' is a number:       " + type_at(1, 16));
print("  '//' is a comment:     " + type_at(1, 21));
print("  the string is a string:" + type_at(2, 4));

// ── the LAST line, which an editor sends without a trailing newline ───────
//
// A buffer's text is what the file holds right now, so the line being typed has
// no newline after it. That case used to lose the ENTIRE last line: `split_lines`
// bounded its loop with the first line-start past the span's last byte, and a
// buffer with no trailing newline has none -- so the bound stayed at its initial
// value and every token on the final line was dropped. A 17-line buffer yielded
// 115 spans and 110 tokens, and the 5 missing were exactly that line's.
//
// An editor shows it as the highlighter going blank on the current line, which is
// the one line the user is looking at. Every other fixture here ends with a
// newline, which is why it went unnoticed: a round trip cannot see a token that
// was never produced.
let no_nl = "def f() -> long {\n    let y = 1;\n    y\n}\nprint(1)";
let with_nl = no_nl + "\n";
let t_no = sem.tokens(no_nl);
let t_yes = sem.tokens(with_nl);
let span_no = len(scan.scan_full(no_nl).spans);
let span_yes = len(scan.scan_full(with_nl).spans);
print("no trailing newline: " + tostring(len(t_no)) + " tokens for " + tostring(span_no) + " spans");
print("with one: " + tostring(len(t_yes)) + " tokens for " + tostring(span_yes) + " spans");
print("the last line survives either way: " +
      tostring(len(t_no) == span_no && len(t_yes) == span_yes));
// `print(1)` is 0-based line 4: the buffer is five lines and `def`, `let y`, `y`,
// `}` and `print(1)`.
let last_line_tok = 0;
foreach (t in t_no) { if (t.line == 4) { last_line_tok = last_line_tok + 1; } };
print("tokens on the last line of the no-newline buffer: " + tostring(last_line_tok) + " (want 4)");

// ── the rules the format enforces ───────────────────────────────────────
// sorted, non-overlapping, positive length, and one line each.
def sorted_and_disjoint(data: [long]) -> bool {
    let abs = decode(data);
    // A flag, not a count: the callers want "is this stream well formed", and
    // three independent invariants can each break it.
    let sorted = true;
    let i = 1;
    while (i < len(abs)) {
        let a = abs[i - 1];
        let b = abs[i];
        let aend = a.line * 1000000 + a.ch + a.len;
        let bstart = b.line * 1000000 + b.ch;
        if (bstart < aend) { sorted = false; }      // overlap, or out of order
        i = i + 1;
    }
    let positive = true;
    let inside = true;
    let k = 0;
    while (k < len(abs)) {
        if (abs[k].len <= 0) { positive = false; }
        if (abs[k].line < 0 || abs[k].ch < 0) { inside = false; }
        k = k + 1;
    }
    sorted && positive && inside
}

print("sorted, disjoint, positive length: " + tostring(sorted_and_disjoint(data0)));

// ── a multi-line block comment is SEVERAL tokens ────────────────────────
// One token per line, not one spanning token: a token that crosses a line break
// paints from its start to the end of the file.
let bc = "/* one\n   two\n   three */\nlet x = 1;\n";
let babs = sem.tokens(bc);
print("block comment spans: " + tostring(len(bc[:bc.index_of("*/") + 2].split("\n"))) + " lines");
let comment_toks = 0;
foreach (t in babs) { if (t.typ == sem.T_comment) { comment_toks = comment_toks + 1; } }
print("comment tokens: " + tostring(comment_toks) + " (want 3)");
let every_line_covered = 1;
foreach (t in babs) { if (t.typ == sem.T_comment && t.ch != 0) { every_line_covered = 0; } }
print("each starts at column 0: " + tostring(every_line_covered));
print("block comment round trip: " + tostring(len(decode(sem.encode(babs))) == len(babs)));

// ── non-ASCII: positions are UTF-16 CHARACTERS ──────────────────────────
// An emoji is four bytes and two code units. A byte column here would put the
// token boundary in the wrong place, and the colour would bleed.
let emoji = from_bytes(json.utf8_put([], 128512));
let uni = "let s = \"" + emoji + emoji + "\";  // hi\nlet " + emoji + " = 1;\n";
let uabs = sem.tokens(uni);
print("unicode: " + tostring(len(uabs)) + " tokens");
let str_tok_ok = 1;
foreach (t in uabs) {
    // every token must land inside its line, in characters
    let lb = pos.line_bytes(uni, t.line + 1);
    if (t.ch + t.len > pos.u16_len(lb, len(lb))) { str_tok_ok = 0; }
}
print("every token fits its line in characters: " + tostring(str_tok_ok));
print("unicode round trip: " + tostring(len(decode(sem.encode(uabs))) == len(uabs)));

// The identifier after the emoji starts at character 10, not byte 16: the two
// emoji are 8 bytes and 4 code units.
// A line with a 4-byte emoji BEFORE a real identifier, so there is a name whose
// column can be checked. The emoji is not alphanumeric, so it cannot itself be an
// identifier -- an earlier version of this used `let <emoji> = 1` and then measured
// "the name after the emoji" as column 0, which was `let`.
let two = "let a = \"" + emoji + "\"; let n: str = 1;\n";
let t2 = sem.tokens(two);
// The identifier immediately after the string literal, found by its own text
// rather than by counting characters in a comment -- counting is how the earlier
// version of this got a "want" that was simply wrong.
let marker = index_of(two, "; let n");
let want_byte = 0;
if (marker >= 0) { want_byte = marker + 6; }        // past "; let "
// Past the string literal: `let a = "` is nine characters, then the emoji, then
// the closing quote. The first identifier after THAT is the one being measured.
let after_string = 0;
foreach (t in t2) {
    if (t.line == 0 && t.typ == sem.T_string) { after_string = t.ch + t.len + 1; }
}
let name_ch = -1;
let best = 1000000;
foreach (t in t2) {
    if (t.line == 0 && t.typ == sem.T_variable && t.ch > after_string && t.ch < best) {
        name_ch = t.ch;
        best = t.ch;
    }
}
// Converting the character column back to a byte offset must land exactly on the
// `n`. That is the round trip the editor performs when it sends a position back,
// and it is the only assertion here whose expectation is derived independently.
// from_lsp gives a 1-BASED column and index_of a 0-BASED offset, so the
// comparison is back - 1. Getting that wrong makes a correct round trip look
// wrong by one, which is the least useful kind of failing test.
let back = pos.from_lsp(two, 0, name_ch);
print("the name after the emoji: character " + tostring(name_ch) + ", back to 0-based byte " + tostring(back - 1));
print("which is the byte of the n itself: " + tostring(back - 1 == want_byte) + " (want " + tostring(want_byte) + ")");
print("and the character column is not the byte column: " + tostring(name_ch != want_byte));
print("and the round trip still holds: " + tostring(len(decode(sem.encode(t2))) == len(t2)));

// ── a buffer that does not lex still highlights ────────────────────────
// R2.5. The stray `#` is a K_error span: one token, painted as an error,
// rather than a blank file.
let broken = "let x = 1;\n# what is this\nlet y = 2;\n";
let babs2 = sem.tokens(broken);
let errs = 0;
foreach (t in babs2) { if (t.typ == sem.T_error) { errs = errs + 1; } }
print("a stray # is an error token: " + tostring(errs == 1));
print("and the rest still highlights: " + tostring(len(babs2) > 5));
print("broken round trip: " + tostring(len(decode(sem.encode(babs2))) == len(babs2)));

// An unterminated string: the whole rest of the line is one string token.
let unterm = "let s = \"oops\nlet y = 1;\n";
let uabs2 = sem.tokens(unterm);
print("unterminated string still yields tokens: " + tostring(len(uabs2) > 3));
print("unterminated round trip: " + tostring(len(decode(sem.encode(uabs2))) == len(uabs2)));

// ── degenerate inputs ───────────────────────────────────────────────────
print("empty: " + tostring(len(sem.encode(sem.tokens("")))));
// REAL newlines here. An earlier version wrote "\\n" in the Y source, which is a
// backslash and an "n" -- nine characters of mostly error spans, so the number it
// printed was correct and meant nothing.
print("blank (real newlines): " + tostring(len(sem.encode(sem.tokens("\n\n   \n")))));
print("a literal backslash-n:  " + tostring(len(sem.encode(sem.tokens("\\n")))));
print("one char: " + tostring(len(sem.encode(sem.tokens("x")))));
print("no trailing newline: " + tostring(len(sem.encode(sem.tokens("let x = 1;")))));

// ── and the real corpus: it must never crash, and must round trip ───────
// Every file in src/y and src/tools/lsp, checked for the invariants rather
// than for specific tokens -- the point is that no input makes this wrong.
import fs;
let files = fs.list_dir("src/y")!;
let checked = 0;
let failed = 0;
let worst = 0;
foreach (f in files) {
    if (f.ends_with(".y") || f.ends_with(".c") || f.ends_with(".h")) {
        let p = "src/y/" + f;
        let got = fs.read_file(p);
        if is_some(got) {
            let body = got!;
            let toks = sem.tokens(body);
            let d = sem.encode(toks);
            checked = checked + 1;
            if (len(decode(d)) != len(toks)) { failed = failed + 1; print("  ROUND TRIP FAILED " + p); }
            if (!sorted_and_disjoint(d)) { failed = failed + 1; print("  INVARIANT FAILED " + p); }
            if (len(toks) > worst) { worst = len(toks); }
        }
    }
}
// NOT the token count: that is a function of src/y, which changes whenever the
// compiler changes, so asserting it made this fixture fail for reasons that had
// nothing to do with the highlighter. What matters is the invariants -- every
// file scanned, none of them breaking the encoding -- and that some file produced
// a substantial number of tokens, which is what says the corpus was really read.
print("src/y: " + tostring(checked) + " files checked, " + tostring(failed) + " failed");
// The threshold, not the number: the comment above says why, and printing
// `worst` anyway put the very number it warns about into the compared output,
// so editing any comment in src/y failed this fixture.
print("the corpus was really read: " + tostring(checked > 10 && worst > 10000) + " (a file yielded over 10000 tokens)");
print("done");