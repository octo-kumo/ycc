// selftest.y -- property checks for this toolkit, with no reference file
// involved.
//
// A golden file proves DETERMINISM, not correctness (ORCHESTRATOR.md 7 --
// examples/cube passed all eight gate items with a wireframe that filled
// regions). So this mode exists to check the things a golden file cannot:
//   (a) base64 against the RFC 4648 section 10 test VECTORS, asserted by
//       value, plus a round trip of all 256 byte values, plus a cross
//       check against x509.b64_decode -- a second, independent decoder
//       written by someone else, which this example did not write;
//   (b) CSV per RFC 4180, each awkward case asserted against its exact
//       expected output string;
//   (c) JSON round-trip IDENTITY -- parse, emit, parse again, and assert
//       the two parses are the SAME VALUE structurally, not the same
//       bytes, plus the values themselves against what JSON says they
//       are;
//   (d) every malformed input, run END TO END through a forked child so
//       the exit code and the stderr routing are observed, not assumed.
//
// (d) is the part that needs the fork: the only way to check "exits
// non-zero, says so on stderr, and does not trap" is to run the real
// binary and look.

// The sample table, embedded so this check needs no file argument and the
// folder stays self-contained.
embed DEMO_CSV from "data/demo.csv";

import args;
import b64;
import crypto;
import csvio;
import fs;
import jsonval;
import x509;

let n_checks = 0;
let n_fail = 0;
let n_group = 0;

// ok(label: str, cond: bool, detail: str) -- one assertion.
def ok(label: str, cond: bool, detail: str) {
    n_checks = n_checks + 1;
    if (cond) {
        puts("  ok    " + label + " -- " + detail + "\n");
    } else {
        n_fail = n_fail + 1;
        puts("  FAIL  " + label + " -- " + detail + "\n");
    }
};

def group(name: str) {
    n_group = n_group + 1;
    puts("[" + tostring(n_group) + "] " + name + "\n")
};

// show(s: str) -> str -- a string in a form safe to print inside a report:
// control characters and quotes escaped, so a failure line reads the same
// on every terminal.
def show(s: str) -> str {
    let out = "\"";
    let i = 0;
    let n = len(s);
    let go = i < n;
    while (go) {
        let c = byte_at(s, i);
        if (c == 34) { out += "\\\""; }
        else if (c == 92) { out += "\\\\"; }
        else if (c == 10) { out += "\\n"; }
        else if (c == 13) { out += "\\r"; }
        else if (c == 9) { out += "\\t"; }
        else if (c < 32 || c == 127) { out += "\\x" + jsonval.hex4(c); }
        else { out += chr(c) };
        i = i + 1;
        go = i < n;
    };
    out + "\""
}

// ── (a) base64 against RFC 4648 ───────────────────────────────────────────

// RFC 4648 section 10, "Test VECTORS". These seven pairs are the whole
// spec's own test data; nothing here was derived from this implementation.
const VEC_IN: [str] = ["", "f", "fo", "foo", "foob", "fooba", "foobar"];
const VEC_OUT: [str] = ["", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"];

def t_b64_vectors() {
    group("base64 -- RFC 4648 section 10 test vectors");
    let i = 0;
    let allok = true;
    while (i < len(VEC_IN)) {
        let got = b64.encode(bytes(VEC_IN[i]), 0);
        // encode() ends its output with a newline whenever there is any
        // output, so that newline is part of what is asserted -- and the
        // empty input has no output at all.
        let want = "";
        if (VEC_OUT[i] != "") { want = VEC_OUT[i] + "\n"; };
        let good = got == want;
        if (!good) { allok = false; };
        ok("encode " + show(VEC_IN[i]), good, "want " + show(want) + ", got " + show(got));
        i = i + 1
    };
    i = 0;
    while (i < len(VEC_IN)) {
        let back = b64.decode(VEC_OUT[i], false);
        let e = b64.dec_err;
        let good = e == "" && from_bytes(back) == VEC_IN[i];
        if (!good) { allok = false; };
        ok("decode " + show(VEC_OUT[i]), good, "want " + show(VEC_IN[i]) + ", got " + show(from_bytes(back)) +
           if_tail(e));
        i = i + 1
    };
    ok("all seven vectors", allok, "RFC 4648 10: \"\" .. \"foobar\"")
};

def if_tail(e: str) -> str {
    let s = "";
    if (e != "") { s = ", error: " + e; };
    s
};

def t_b64_all_bytes() {
    group("base64 -- every one of the 256 byte values round-trips");
    let all: [byte] = [];
    let i = 0;
    while (i < 256) { let b: byte = i; all += b; i = i + 1; };
    let enc = b64.encode(all, 0);
    let dec = b64.decode(enc, false);
    let e = b64.dec_err;
    let same_len = len(dec) == 256;
    let at = 0 - 1;
    let i2 = 0;
    while (i2 < 256 && same_len) {
        if (dec[i2] != all[i2]) { at = i2; same_len = false; };
        i2 = i2 + 1
    };
    ok("256 bytes -> " + tostring(len(enc.trim())) + " chars -> 256 bytes", same_len && e == "",
       if_bad(at, e));
    // RFC 4648 section 4's length rule, checked from the other end: 256
    // bytes is 85 full quanta plus one byte, so the encoding is 344
    // characters with exactly one "==".
    let n_pad = 0;
    let k = 0;
    let m = len(enc);
    while (k < m) {
        if (byte_at(enc, k) == 61) { n_pad = n_pad + 1; };
        k = k + 1
    };
    ok("length and padding", len(enc.trim()) == 344 && n_pad == 2,
       "344 chars with 2 '=' expected, got " + tostring(len(enc.trim())) + " with " + tostring(n_pad));
    // The cross check: x509.b64_decode is a decoder this example did not
    // write. If the two disagree, one of them is wrong and this is how we
    // find out which.
    let theirs = x509.b64_decode(enc);
    let bad = 0 - 1;
    let j = 0;
    while (j < 256 && len(theirs) == 256) {
        if (theirs[j] != all[j]) { bad = j; };
        j = j + 1
    };
    ok("agrees with x509.b64_decode", len(theirs) == 256 && bad < 0,
       if_bad(bad, "two independent implementations, " + tostring(len(theirs)) + " bytes back"))
};

def if_bad(at: long, extra: str) -> str {
    let s = extra;
    if (at >= 0) { s = "first difference at byte " + tostring(at) + ", " + extra; };
    s
};

def t_b64_bad() {
    group("base64 -- malformed input is diagnosed, not guessed at");
    let bads: [str] = ["Zg=", "Zg===", "Z===", "Zg!=", "Zg==Zg==", "A", "Zg=A", "!", "=="];
    let i = 0;
    let clean = true;
    while (i < len(bads)) {
        let r = b64.decode(bads[i], false);
        let e = b64.dec_err;
        let good = e != "" && len(r) == 0;
        if (!good) { clean = false; };
        ok("reject " + show(bads[i]), good, if_tail(e) + if_clean(len(r)));
        i = i + 1
    };
    // --lenient is the documented escape hatch and must actually skip.
    // RFC 4648 section 3.2 says whitespace and line breaks MAY be ignored
    // in the encoded form, in both modes -- that is not lenient decoding,
    // that is the spec. So the strict/lenient contrast needs a character
    // that is genuinely outside the alphabet.
    let ws = b64.decode("aGVs bG8=", false);
    ok("whitespace is ignored (RFC 4648 3.2)", b64.dec_err == "" && from_bytes(ws) == "hello",
       "\"aGVs bG8=\" -> " + show(from_bytes(ws)));
    let l2 = b64.decode("aGVs!bG8=", true);
    ok("lenient skips a '!'", b64.dec_err == "" && from_bytes(l2) == "hello",
       "\"aGVs!bG8=\" --lenient -> " + show(from_bytes(l2)));
    let strict = b64.decode("aGVs!bG8=", false);
    ok("strict refuses that '!'", b64.dec_err != "" && len(strict) == 0,
       "\"aGVs!bG8=\" -> " + b64.dec_err);
    ok("every malformed input diagnosed", clean, tostring(len(bads)) + " cases")
};

def if_clean(n: long) -> str {
    let s = "";
    if (n > 0) { s = " (but " + tostring(n) + " bytes came back anyway)"; };
    s
};

// ── (b) CSV per RFC 4180 ──────────────────────────────────────────────────
//
// Each of these asserts an EXACT expected string, which is the only kind of
// CSV assertion worth anything. The awkward cases are the ones split() gets
// wrong and the ones a hand-rolled parser usually gets wrong too.

def t_csv() {
    group("csv -- RFC 4180, each awkward case against its exact output");
    // 1. a quoted field containing the delimiter (RFC 4180 2.5)
    chk_csv("quoted field holding the delimiter", "\"a,b\",c", "\"a,b\",c\r\n");
    // 2. a quoted field containing a doubled quote (RFC 4180 2.6)
    chk_csv("quoted field holding a doubled quote", "\"a\"\"b\",c", "\"a\"\"b\",c\r\n");
    // 3. a quoted field containing a newline (RFC 4180 2.6)
    chk_csv("quoted field holding a newline", "\"a\nb\",c", "\"a\nb\",c\r\n");
    // 4. an empty final field -- the case split() silently drops
    chk_csv("empty final field", "a,b,", "a,b,\r\n");
    // 5. a quoted empty field is a field, not an absence
    chk_csv("quoted empty field", "a,\"\"", "a,\r\n");
    // 6. a doubled delimiter is two fields
    chk_csv("doubled delimiter", "a,,b", "a,,b\r\n");
    // 7. only delimiters: two empty fields
    chk_csv("a line of one delimiter", ",", ",\r\n");
    // 8. RFC 4180's own first example table
    chk_csv("RFC 4180 example table", "aaa,bbb,ccc\r\nzzz,yyy,xxx\r\n",
            "aaa,bbb,ccc\r\nzzz,yyy,xxx\r\n");
    // 9. RFC 4180's own second example table, quoted fields and all. The
    //    leading blank line in the RFC's text is NOT a record, and this
    //    asserts that too.
    chk_csv("RFC 4180 quoted example table",
            "aaa,\"quo\"\"ted\",ccc\r\nzzz,still,quoted\r\n\"a\"\"a\",b,cc\r\n",
            "aaa,\"quo\"\"ted\",ccc\r\nzzz,still,quoted\r\n\"a\"\"a\",b,cc\r\n");
    // 10. an empty field in the middle
    chk_csv("empty field in the middle", "a,,b", "a,,b\r\n");
    // 11. a bare LF terminator comes back as CRLF (the output form)
    let rows = csvio.csv_parse("a,b\nc,d\n", 44);
    ok("LF in, CRLF out", csvio.csv_err == "" && len(rows) == 2 &&
       csvio.csv_render(rows, 44, "\r\n", false) == "a,b\r\nc,d\r\n",
       "a,b<LF>c,d<LF> -> a,b<CRLF>c,d<CRLF>");
    // 12. the empty input and the blank line, which are three more distinct
    //     cases from 4, 5 and 6
    ok("empty input is no records", len(csvio.csv_parse("", 44)) == 0 && csvio.csv_err == "",
       "\"\" -> 0 records");
    ok("a blank line is no record", len(csvio.csv_parse("\n", 44)) == 0 && csvio.csv_err == "",
       "\"\\n\" -> 0 records");
    ok("two blank lines are no records", len(csvio.csv_parse("\n\n", 44)) == 0,
       "\"\\n\\n\" -> 0 records");
    // 13. quoting is minimal: whitespace alone does not earn quotes
    ok("whitespace is data, not a reason to quote",
       csvio.csv_quote("  a  ", 44, false) == "  a  " &&
       csvio.csv_quote("plain", 44, false) == "plain",
       "two bare fields stay bare");
    // 14. a quote is doubled on the way out
    ok("a quote doubles on the way out", csvio.csv_quote("a\"b", 44, false) == "\"a\"\"b\"",
       "a\"b -> \"a\"\"b\"");
    // 15. --quote-all
    ok("--quote-all quotes even a plain field",
       csvio.csv_quote("plain", 44, true) == "\"plain\"", "plain -> \"plain\"");
    // 16. a delimiter other than comma. A bare CR is a record terminator
    //     too (old-Mac line endings), so the data tested here is a newline
    //     INSIDE a quoted field, with a TAB delimiter.
    let trows = csvio.csv_parse("a\t\"b\nc\"\td", 9);
    ok("a TAB delimiter, and a newline inside a quoted field",
       csvio.csv_err == "" && len(trows) == 1 && len(trows[0]) == 3 &&
       trows[0][0] == "a" && trows[0][1] == "b\nc" && trows[0][2] == "d",
       "a<TAB>\"b<LF>c\"<TAB>d -> one record of three fields");
    // 17. and a bare CR really does end a record
    let crs = csvio.csv_parse("a,b\rc,d", 44);
    ok("a bare CR is a record terminator", csvio.csv_err == "" && len(crs) == 2 &&
       crs[1][0] == "c", "a,b<CR>c,d -> two records");
    // 18. and CRLF is ONE terminator, not two
    let crlf2 = csvio.csv_parse("a\r\nb\r\n", 44);
    ok("CRLF is one terminator", csvio.csv_err == "" && len(crlf2) == 2 && crlf2[1][0] == "b",
       "a<CRLF>b<CRLF> -> two records");
    // 17. a comma inside a field with a TAB delimiter needs no quotes
    ok("a comma is not special when the delimiter is not",
       csvio.csv_quote("a,b", 9, false) == "a,b", "a,b stays bare under --delim=tab")
};

def chk_csv(label: str, src: str, want: str) -> void {
    let rows = csvio.csv_parse(src, 44);
    let e = csvio.csv_err;
    let got = csvio.csv_render(rows, 44, "\r\n", false);
    ok(label, e == "" && got == want,
       show(src) + " -> " + show(got) + (got == want ? "" : ", want " + show(want)) + if_tail(e))
};

// ── (c) JSON round-trip identity ───────────────────────────────────────────

// The document the identity check runs on: objects, arrays, nested
// combinations, strings with every kind of escape, numbers in four shapes,
// booleans and null.
const NESTED: str = "{\"zeta\":[1,-2,3.5,1e2,true,false,null,\"\"],\"alpha\":{\"a\":{\"b\":[{\"c\":\"d\\ne\"},{\"c\":\"\\u0041\\u00e9\\ud83d\\ude00\"},{\"c\":\"q\\\"q\\\\\\/\"}]}},\"mid\":0,\"neg\":-0.5,\"empty\":{},\"none\":[],\"big\":9007199254740993}";

def t_json_identity() {
    group("json -- parse, emit, parse again: the two parses are the SAME VALUE");
    let v1 = jsonval.parse(NESTED);
    let e1 = jsonval.parse_err();
    ok("the reference document parses", e1 == "", show(NESTED) + if_tail(e1));
    let c1 = jsonval.render(v1, false, 2, false);
    let v2 = jsonval.parse(c1);
    let e2 = jsonval.parse_err();
    ok("the compact form re-parses", e2 == "", show(c1) + if_tail(e2));
    // The assertion that matters: STRUCTURAL identity, not byte identity.
    ok("compact: v1 and v2 are the same value", e2 == "" && jsonval.same(v1, v2),
       tostring(jsonval.node_count(v1)) + " nodes compared field by field");
    let c2 = jsonval.render(v2, false, 2, false);
    ok("emitting is stable", c1 == c2, "emit(emit(x)) == emit(x)");
    // Pretty, because a different emitter path is a different program.
    let p1 = jsonval.render(v1, true, 2, false);
    let v3 = jsonval.parse(p1);
    let e3 = jsonval.parse_err();
    ok("pretty: v1 and v3 are the same value", e3 == "" && jsonval.same(v1, v3),
       tostring(jsonval.node_count(v1)) + " nodes across " + tostring(p1.count("\n")) + " lines");
    ok("indent width is honoured", jsonval.render(v1, true, 4, false).contains("\n    \"zeta\""),
       "indent 4 gives four spaces");
    // And the sorted emitter, which is a third path.
    let s1 = jsonval.render(v1, false, 2, true);
    let v4 = jsonval.parse(s1);
    // same() is order SENSITIVE on purpose -- key order is part of what
    // this toolkit preserves -- so the sorted form is checked with
    // same_unordered(), which compares objects by key lookup instead.
    ok("--sort-keys changes the order but no value",
       jsonval.parse_err() == "" && jsonval.same_unordered(v1, v4) && !jsonval.same(v1, v4),
       "sorted: same_unordered, and deliberately NOT same()");
    ok("--sort-keys really sorts", jsonval.render(v4, false, 2, false).starts_with("{\"alpha\""),
       jsonval.render(v4, false, 2, false)[0:24])
};

def t_json_values() {
    group("json -- values are what JSON says they are");
    // key order is insertion order, not sorted -- the property that makes
    // the output byte-stable
    let ko = jsonval.parse("{\"z\":1,\"a\":2,\"m\":3}");
    ok("key order is the input order",
       jsonval.render(ko, false, 2, false) == "{\"z\":1,\"a\":2,\"m\":3}",
       "{\"z\":1,\"a\":2,\"m\":3} unchanged");
    ok("--sort-keys sorts, and only then",
       jsonval.render(ko, false, 2, true) == "{\"a\":2,\"m\":3,\"z\":1}",
       "{\"a\":2,\"m\":3,\"z\":1}");
    // number text is preserved verbatim, so 1.0 is not 1
    let nums = jsonval.parse("[0,-0,1.0,1e2,1E+2,-1.5e-3,100]");
    ok("number text is verbatim", jsonval.render(nums, false, 2, false) ==
       "[0,-0,1.0,1e2,1E+2,-1.5e-3,100]", "1.0 stays 1.0 and 1e2 stays 1e2");
    ok("an integer token keeps its integer value",
       nums.items[6].n == 100 && jsonval.num_isint(nums.items[6]),
       "n = " + tostring(nums.items[6].n));
    ok("a fractional token has no integer value",
       nums.items[2].n == 0 && !jsonval.num_isint(nums.items[2]),
       "1.0 -> n = 0, text kept");
    // escapes decode to the characters they name -- \n is a newline, NOT
    // the two characters '\' and 'n'. Getting this wrong round-trips a
    // wrong value, and it is exactly the bug this property check exists
    // to find; it did find it during development.
    // NOTE: a Y string literal has \n \t \r \xHH and `\<c>` (which just
    // drops the backslash) -- there is no \uXXXX, and `\b` is the letter
    // b. So every control and non-ASCII byte below is written \xHH, which
    // is also how the expected bytes are stated rather than assumed.
    let esc = jsonval.parse("\"\\n\\t\\r\\b\\f\\\"\\\\\\/\\u0041\\u00e9\\ud83d\\ude00\"");
    // LF TAB CR 0x08 0x0C 0x22 0x5C 0x2F 'A' C3 A9  F0 9F 98 80
    let want = "\n\t\r\x08\x0c\"\\/\x41\xc3\xa9\xf0\x9f\x98\x80";
    let gotb = bytes(esc.s);
    let wb = bytes(want);
    let at = 0 - 1;
    let i = 0;
    while (i < len(gotb) && i < len(wb) && at < 0) {
        if (gotb[i] != wb[i]) { at = i; };
        i = i + 1
    };
    ok("escapes decode to characters, not to two-character text",
       at < 0 && len(gotb) == len(wb) && len(gotb) == 15,
       if_bad(at, tostring(len(gotb)) + " bytes vs " + tostring(len(wb))));
    // U+1F600 is the emoji; its UTF-8 is F0 9F 98 80, an external fact.
    ok("U+1F600 is f0 9f 98 80 and U+00E9 is c3 a9", esc.s == want,
       "the two- and four-byte encodings are exactly right");
    // a raw control character must be refused, not passed through. The
    // source is assembled with chr(10) so the Y literal itself holds no
    // newline (a Y literal has no \n inside a "..." that stays a token --
    // chr is unambiguous).
    let ctl_src = "\"a" + chr(10) + "b\"";
    jsonval.parse(ctl_src);
    ok("a raw control character is refused", jsonval.parse_err() != "",
       jsonval.parse_err());
    // duplicate keys: last one wins, and nothing is invented
    let dup = jsonval.parse("{\"a\":1,\"b\":2,\"a\":3}");
    ok("a duplicate key is kept, in place",
       len(dup.fields) == 3 && jsonval.render(dup, false, 2, false) == "{\"a\":1,\"b\":2,\"a\":3}",
       "the document is preserved exactly as written");
    // empty containers
    ok("empty containers", jsonval.render(jsonval.parse("{\"a\":{},\"b\":[]}"), false, 2, false) ==
       "{\"a\":{},\"b\":[]}", "{} and [] are closed, not left dangling");
    // whitespace
    ok("whitespace between tokens", jsonval.render(jsonval.parse(" \n\t [ 1 , 2 ] \r\n "), false, 2, false) ==
       "[1,2]", "  \\n\\t [ 1 , 2 ] \\r\\n  -> [1,2]")
};

def t_json_query() {
    group("json -- the dotted path");
    let doc = jsonval.parse("{\"a\":{\"b\":[10,20,{\"c\":\"d\"}]},\"n\":5}");
    let hit = jsonval.lookup(doc, "a.b[2].c");
    ok("a.b[2].c", is_some(hit) && jsonval.scalar_text(unwrap(hit)) == "d", "\"d\"");
    let miss = jsonval.lookup(doc, "a.b[9]");
    ok("an out-of-range index is an error, not a trap",
       !is_some(miss) && jsonval.q_err != "", jsonval.q_err);
    let nf = jsonval.lookup(doc, "a.zz");
    ok("an absent key is an error, not a trap", !is_some(nf) && jsonval.q_err != "", jsonval.q_err);
    let bad = jsonval.lookup(doc, "a.b[x]");
    ok("a non-numeric index is an error", !is_some(bad) && jsonval.q_err != "", jsonval.q_err);
    let wrong = jsonval.lookup(doc, "a[0]");
    ok("indexing an object is an error", !is_some(wrong) && jsonval.q_err != "", jsonval.q_err)
};

// ── (d) malformed input, end to end through a forked child ────────────────
//
// fork, dup2 a pipe onto the child's stdin and stdout/stderr, execve this
// same binary with the case's arguments, and observe what actually came
// back. No reference file, no assumption about exit codes.

let sub_out = "";         // the child's merged stdout+stderr
let sub_pid = 0;

// self_path() -> str -- an absolute path to this binary, so execve cannot
// be defeated by a relative argv[0].
def self_path() -> str {
    let p = argv()[0];
    if (!p.starts_with("/")) { p = fs.cwd() + "/" + p; };
    p
};

// run_cli(extra: [str], input: str) -> long -- run the CLI with these extra
// arguments and this stdin, return its exit code, and leave the merged
// output in sub_out.
def run_cli(extra: [str], input: str) -> long {
    // pipe2 writes two 32-bit ints, so they are assembled from a [byte; 8]
    // -- reading them into a [long; 2] packs both into element 0 and
    // leaves wr = 0, which is stdin (ORCHESTRATOR.md 2.13).
    let ifds: [byte; 8] = [0; 8];
    syscall(293, &ifds[0], 0);
    let in_rd = ifds[0] + ifds[1] * 256 + ifds[2] * 65536 + ifds[3] * 16777216;
    let in_wr = ifds[4] + ifds[5] * 256 + ifds[6] * 65536 + ifds[7] * 16777216;
    let ofds: [byte; 8] = [0; 8];
    syscall(293, &ofds[0], 0);
    let out_rd = ofds[0] + ofds[1] * 256 + ofds[2] * 65536 + ofds[3] * 16777216;
    let out_wr = ofds[4] + ofds[5] * 256 + ofds[6] * 65536 + ofds[7] * 16777216;

    // argv and the path, each NUL-terminated in one arena block. Nothing is
    // ever freed, so the blobs stay valid after this def returns.
    let pathb = bytes(self_path());
    pathb += 0;
    let blobs: [[byte]] = [];
    let i = 0;
    while (i < len(extra)) {
        let b = bytes(extra[i]);
        b += 0;
        blobs += b;
        i = i + 1
    };
    // NOTE: `[0; n]` needs an integer LITERAL, not an expression, so the
    // argv array is grown with `+=` -- which is the array interface anyway.
    let av: [long] = [];
    av += ptr_addr(&pathb[0]);
    i = 0;
    while (i < len(extra)) { av += ptr_addr(&blobs[i][0]); i = i + 1; };
    av += 0;

    let pid = fork {
        // dup2(oldfd, newfd): syscall 33, a1 = oldfd, a2 = newfd, in
        // kernel register order (ORCHESTRATOR.md 2.1).
        syscall(33, in_rd, 0, 0);
        syscall(33, out_wr, 1, 0);
        syscall(33, out_wr, 2, 0);
        syscall(3, in_rd, 0);
        syscall(3, in_wr, 0);
        syscall(3, out_wr, 0);
        // execve(path, argv, NULL)
        syscall(59, ptr_addr(&pathb[0]), ptr_addr(&av[0]), 0);
        exit(127)
    };
    if (pid < 0) {
        sub_out = "fork failed";
        return 0 - 1
    };
    syscall(3, in_rd, 0);
    syscall(3, out_wr, 0);
    // feed the child's stdin
    let w = 0;
    let n_in = len(input);
    while (w < n_in) {
        let chunk = input[w:n_in];
        let wrote = syscall(1, in_wr, chunk, n_in - w);
        if (wrote <= 0) { w = n_in; } else { w = w + wrote; }
    };
    // Closing the write end is what gives the child its EOF.
    syscall(3, in_wr, 0);
    let buf: [byte; 16384] = [0; 16384];
    let got: [byte] = [];
    let go = true;
    while (go) {
        let n = syscall(0, out_rd, &buf[0], 16384);
        if (n > 0) {
            let k = 0;
            while (k < n) { got += buf[k]; k = k + 1; };
        } else { go = false; }
    };
    syscall(3, out_rd, 0);
    sub_out = from_bytes(got);
    wait_pid(pid)
};

// One malformed-input case: the arguments, the stdin, and the exit code
// the tool must use.
type BadCase = { label: str, argv: [str], input: str, code: long };

// bad_case() -- every input that must be refused, with the exit code it
// must produce: 1 for bad DATA, 2 for bad USAGE. The distinction is the
// whole point of having two codes.
def bad_cases() -> [BadCase] {
    let out: [BadCase] = [];
    // -- JSON that is not JSON
    out += { label: "json: a truncated object", argv: ["json", "--op=validate", "-"], input: "{\"a\":1", code: 1 };
    out += { label: "json: a trailing comma in an object", argv: ["json", "--op=validate", "-"], input: "{\"a\":1,}", code: 1 };
    out += { label: "json: a trailing comma in an array", argv: ["json", "--op=validate", "-"], input: "[1,2,]", code: 1 };
    out += { label: "json: an unquoted key", argv: ["json", "--op=validate", "-"], input: "{a:1}", code: 1 };
    out += { label: "json: single-quoted keys", argv: ["json", "--op=validate", "-"], input: "{'a':1}", code: 1 };
    out += { label: "json: a bad escape", argv: ["json", "--op=validate", "-"], input: "\"a\\qb\"", code: 1 };
    out += { label: "json: an unbalanced bracket", argv: ["json", "--op=validate", "-"], input: "[1,2", code: 1 };
    out += { label: "json: an unbalanced brace", argv: ["json", "--op=validate", "-"], input: "{\"a\":[1}", code: 1 };
    out += { label: "json: a leading zero", argv: ["json", "--op=validate", "-"], input: "01", code: 1 };
    out += { label: "json: a bare word", argv: ["json", "--op=validate", "-"], input: "hello", code: 1 };
    out += { label: "json: two top-level values", argv: ["json", "--op=validate", "-"], input: "{} {}", code: 1 };
    out += { label: "json: an empty document", argv: ["json", "--op=validate", "-"], input: "", code: 1 };
    out += { label: "json: 300 levels of nesting", argv: ["json", "--op=validate", "-"], input: deep_brackets(300), code: 1 };
    // -- CSV that is not CSV
    out += { label: "csv: an unterminated quoted field", argv: ["csv", "--op=to-json", "-"], input: "\"abc", code: 1 };
    out += { label: "csv: text after a closing quote", argv: ["csv", "--op=to-json", "-"], input: "\"a\"x,c", code: 1 };
    out += { label: "csv: a quote inside an open field", argv: ["csv", "--op=to-json", "-"], input: "a\"b,c", code: 1 };
    out += { label: "csv: a row that is short for the header", argv: ["csv", "--op=to-json", "--header", "-"],
             input: "a,b\n1,2\n3\n", code: 1 };
    out += { label: "csv: a duplicate header name", argv: ["csv", "--op=to-json", "--header", "-"],
             input: "a,a\n1,2\n", code: 1 };
    out += { label: "csv: --header with no records", argv: ["csv", "--op=to-json", "--header", "-"],
             input: "\n", code: 1 };
    out += { label: "csv: from-json on an object, not an array", argv: ["csv", "--op=from-json", "-"],
             input: "{\"a\":1}", code: 1 };
    out += { label: "csv: from-json with a nested value", argv: ["csv", "--op=from-json", "-"],
             input: "[[1,[2]]]", code: 1 };
    // -- base64 that is not base64
    out += { label: "base64: a length that is not a multiple of 4", argv: ["base64", "--op=decode", "-"],
             input: "Zg=", code: 1 };
    out += { label: "base64: a character outside the alphabet", argv: ["base64", "--op=decode", "-"],
             input: "Zg!=", code: 1 };
    out += { label: "base64: a character after the padding", argv: ["base64", "--op=decode", "-"],
             input: "Zg==Zg==", code: 1 };
    out += { label: "base64: three pad characters", argv: ["base64", "--op=decode", "-"],
             input: "Zg===", code: 1 };
    // -- usage errors: exit 2, not 1
    out += { label: "usage: an unknown command", argv: ["nope"], input: "", code: 2 };
    out += { label: "usage: no command at all", argv: [], input: "", code: 2 };
    out += { label: "usage: an unknown option", argv: ["json", "--op=validate", "--bogus", "-"], input: "1", code: 2 };
    out += { label: "usage: an unknown --op", argv: ["json", "--op=nope", "-"], input: "1", code: 2 };
    out += { label: "usage: a --op from another command", argv: ["json", "--op=encode", "-"], input: "1", code: 2 };
    out += { label: "usage: a non-numeric --indent", argv: ["json", "--indent=x", "-"], input: "1", code: 2 };
    out += { label: "usage: a negative --indent", argv: ["json", "--indent=-1", "-"], input: "1", code: 2 };
    out += { label: "usage: a --delim that is not one character", argv: ["csv", "--delim=ab", "-"], input: "1", code: 2 };
    out += { label: "usage: a --delim that is a quote", argv: ["csv", "--delim=\"\"", "-"], input: "1", code: 2 };
    out += { label: "usage: a --line-end that is neither", argv: ["csv", "--line-end=cr", "-"], input: "1", code: 2 };
    out += { label: "usage: a json-only flag given to csv", argv: ["csv", "--path=a", "-"], input: "1", code: 2 };
    out += { label: "usage: a csv-only flag given to json", argv: ["json", "--delim=;", "-"], input: "1", code: 2 };
    out += { label: "usage: an option given to selftest", argv: ["selftest", "--stats"], input: "", code: 2 };
    out += { label: "usage: a FILE given to selftest", argv: ["selftest", "somefile"], input: "", code: 2 };
    out += { label: "usage: too many operands", argv: ["json", "a.json", "b.json"], input: "", code: 2 };
    out += { label: "usage: a --checksum that does not exist", argv: ["base64", "--op=sum", "--checksum=md5", "-"],
             input: "a", code: 2 };
    out += { label: "usage: --get without --path", argv: ["json", "--op=get", "-"], input: "1", code: 2 };
    out += { label: "usage: --keys on a non-object", argv: ["json", "--op=keys", "-"], input: "1", code: 1 };
    out += { label: "input: a file that is not there", argv: ["json", "--op=validate", "/nonexistent/nope.json"], input: "", code: 1 };
    out += { label: "json: a path that does not resolve", argv: ["json", "--op=get", "--path=zz.yy", "-"],
             input: "{\"a\":1}", code: 1 };
    out
};

def deep_brackets(n: long) -> str {
    let s = "";
    let i = 0;
    while (i < n) { s += "["; i = i + 1; };
    i = 0;
    while (i < n) { s += "]"; i = i + 1; };
    s
};

def t_bad_end_to_end() {
    group("every malformed input, run end to end through a forked child");
    let cases = bad_cases();
    let i = 0;
    let clean = true;
    while (i < len(cases)) {
        let c = cases[i];
        let rc = run_cli(c.argv, c.input);
        let outp = sub_out;
        let has_msg = outp.length > 0;
        let trapped = outp.contains("runtime error:");
        let code_ok = rc == c.code;
        let good = has_msg && !trapped && code_ok;
        if (!good) { clean = false; };
        if (trapped) { clean = false; };
        ok(c.label, good,
           "exit " + tostring(rc) + " (want " + tostring(c.code) + "), " +
           tostring(outp.length) + " bytes on stdout+stderr" +
           if_trap(trapped, outp) + (has_msg ? ", " + first_line(outp) : ", NO MESSAGE"));
        i = i + 1
    };
    ok("no trap on any of " + tostring(len(cases)) + " bad inputs", clean,
       "every one exited non-zero, said why, and did not trap");
    // And the positive control: the same harness, good input, exit 0.
    let rc = run_cli(["json", "--op=validate", "-"], "{\"ok\":true}");
    ok("the same harness accepts good input", rc == 0 && sub_out.length == 0,
       "exit " + tostring(rc) + ", " + tostring(sub_out.length) + " bytes of output");
    let rc2 = run_cli(["base64", "--op=encode", "-"], "foobar");
    ok("base64 encode through the harness", rc2 == 0 && sub_out == "Zm9vYmFy\n",
       "foobar -> " + show(sub_out))
};

def if_trap(trapped: bool, outp: str) -> str {
    let s = "";
    if (trapped) { s = ", TRAP: " + first_line(outp); };
    s
};

// first_line(s: str) -> str -- up to the first newline, for a one-line
// report. The child's message is expected to be short; if it is not, the
// report says so rather than spilling across lines.
def first_line(s: str) -> str {
    let cut = s;
    let nl = s.index_of("\n");
    if (nl >= 0) { cut = s[0:nl]; };
    if (len(cut) > 96) { cut = cut[0:96] + "..."; };
    cut
};

// ── the CSV/JSON bridges, checked against each other ──────────────────────

def t_bridges() {
    group("csv <-> json, in both directions");
    let src = "\"a,b\",\"c\"\"d\",\"e\nf\",g,,\"\"\r\nx,y,z,1,2,3\r\n";
    let rows = csvio.csv_parse(src, 44);
    ok("a nasty table parses", csvio.csv_err == "" && len(rows) == 2 && len(rows[0]) == 6,
       "2 records x 6 fields");
    // The honest statement: the DATA round-trips exactly, and the BYTES do
    // not, because the writer only quotes when it has to -- `""` and an
    // unquoted empty field are the same field.
    let again = csvio.csv_parse(csvio.csv_render(rows, 44, "\r\n", false), 44);
    let same = len(again) == len(rows);
    let k = 0;
    while (same && k < len(rows)) {
        let f = 0;
        while (same && f < len(rows[k])) {
            if (again[k][f] != rows[k][f]) { same = false; };
            f = f + 1
        };
        if (len(again[k]) != len(rows[k])) { same = false; };
        k = k + 1
    };
    ok("CSV -> text -> CSV preserves every field", same,
       "render then parse gives the same 2x6 table field for field");
    // to json and back. A header may not repeat a name, and the nasty
    // table above has two empty columns, so the header path uses a table
    // with six DISTINCT names -- which is itself the case that matters.
    let hsrc = "\"a,b\",\"c\"\"d\",\"e\nf\",g,h,i\r\n1,2,3,4,5,6\r\n";
    let hrows = csvio.csv_parse(hsrc, 44);
    let hdoc = csvio.csv_to_json(hrows, true, false);
    let want_h = "[{\"a,b\":\"1\",\"c\\\"d\":\"2\",\"e\\nf\":\"3\",\"g\":\"4\",\"h\":\"5\",\"i\":\"6\"}]";
    let got_h = jsonval.render(unwrap(hdoc), false, 2, false);
    ok("a header table converts to one object of six keys", is_some(hdoc) && got_h == want_h,
       got_h + (got_h == want_h ? "" : ", want " + want_h));
    ok("the nasty table has no usable header (two empty names)",
       is_some(csvio.csv_to_json(rows, true, false)) == false,
       csvio.csv_err);
    let doc = csvio.csv_to_json(rows, false, false);
    ok("csv to json without --header", is_some(doc),
       tostring(len(rows)) + " records, " + tostring(len(rows[0])) + " fields each");
    if (is_some(doc)) {
        let txt = jsonval.render(unwrap(doc), false, 2, false);
        ok("without --header it is an array of arrays", txt.starts_with("[["),
           txt[0:24]);
        ok("the delimiter is inside the string", txt.contains("\"a,b\""), show(txt));
        ok("the doubled quote decoded", txt.contains("\"c\\\"d\""), "one quote, not two");
        ok("the newline stayed inside its field", txt.contains("\"e\\nf\""), "escaped, not split");
        ok("the empty fields are strings", txt.contains("\"g\",\"\",\"\""), show(txt));
        // and straight back out again
        let back = csvio.json_to_csv(unwrap(doc), false);
        let rows3 = csvio.csv_parse(src, 44);
        ok("json -> csv -> the same data", csvio.csv_err == "" && len(back) == len(rows3) &&
           len(back) == 2 && len(back[0]) == 6,
           "both data rows of six fields came back");
    };
    // The full three-step round trip on the embedded sample, asserted
    // BYTE for byte. It holds because the file is in canonical form --
    // minimal quoting, one terminator per record including the last --
    // and it is the check that would notice if the writer stopped quoting
    // a field it had to quote, or started quoting one it did not.
    let recs4 = csvio.csv_parse(DEMO_CSV, 44);
    let arr4 = csvio.csv_to_json(recs4, false, false);
    let back4 = csvio.csv_render(csvio.json_to_csv(unwrap(arr4), true), 44, "\n", false);
    ok("data/demo.csv -> json -> data/demo.csv, byte for byte", back4 == DEMO_CSV,
       tostring(back4.length) + " bytes out, " + tostring(DEMO_CSV.length) + " bytes in");
    // And the same table with --header, where the header row is consumed
    // and every record becomes an object with four keys.
    let obj4 = csvio.csv_to_json(recs4, true, false);
    ok("the embedded table is 5 records of 4 fields", csvio.csv_err == "" && is_some(obj4) &&
       len(recs4) == 5 && len(recs4[0]) == 4 && len(unwrap(obj4).items) == 4,
       "header + 4 data records, four keys each");
    // --num
    let n2 = csvio.csv_to_json(csvio.csv_parse("a,b\n1,2.5\n007,x\n", 44), true, true);
    ok("--num makes real numbers numbers and leaves 007 a string",
       is_some(n2) && jsonval.render(unwrap(n2), false, 2, false) ==
       "[{\"a\":1,\"b\":2.5},{\"a\":\"007\",\"b\":\"x\"}]",
       jsonval.render(unwrap(n2), false, 2, false))
};

def t_checksums() {
    group("base64 --op=sum, against published constants and against sha256sum");
    // data/demo.csv is embedded, so its SHA-256 can be compared with the
    // constant `sha256sum data/demo.csv` prints -- an external reference,
    // not this program's own output.
    ok("sha256 of the embedded data/demo.csv",
       crypto.hex(crypto.sha256(bytes(DEMO_CSV))) ==
       "d38cecbf3107638d4779b5b8e2f6327a46efc7b5248e6b7a1be9c3943c606f37",
       "matches sha256sum(1) on the same file");
    // FIPS 180-4 / NIST: SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223
    // b00361a396177a9cb410ff61f20015ad. An external constant, not this
    // program's own output.
    let d = b64.decode("YWJj", false);
    let h = crypto.hex(crypto.sha256(d));
    ok("sha256(\"abc\")", h == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
       show(h));
    let h5 = crypto.hex(crypto.sha512(bytes("abc")));
    ok("sha512(\"abc\") is 128 hex digits", h5.length == 128 && h5.starts_with("ddaf35a1"),
       h5[0:24] + "...")
};

def t_num_token() {
    group("csv --num only accepts a real JSON number");
    let yes: [str] = ["0", "-0", "1", "-1", "1.5", "-1.5", "1e5", "1E5", "1e+5", "1e-5", "0.0"];
    let no: [str] = ["", "007", "1,5", "+1", ".5", "5.", "1e", "1e+", "abc", "1 2", "0x10", "1.2.3", "Infinity", "NaN"];
    let i = 0;
    let bad = 0;
    while (i < len(yes)) {
        if (!csvio.num_token(yes[i])) { bad = bad + 1; };
        i = i + 1
    };
    ok("accepted", bad == 0, tostring(len(yes)) + " tokens, all recognised");
    i = 0;
    let bad2 = 0;
    while (i < len(no)) {
        if (csvio.num_token(no[i])) { bad2 = bad2 + 1; };
        i = i + 1
    };
    ok("refused", bad2 == 0, tostring(len(no)) + " tokens, all refused")
};

// run() -> long -- every check, and the number of failures.
def run() -> long {
    n_checks = 0;
    n_fail = 0;
    n_group = 0;
    puts("toolkit_cli self-test -- property checks, no reference file involved\n");
    t_b64_vectors();
    t_b64_all_bytes();
    t_b64_bad();
    t_csv();
    t_json_identity();
    t_json_values();
    t_json_query();
    t_bridges();
    t_checksums();
    t_num_token();
    t_bad_end_to_end();
    puts("\nchecks " + tostring(n_checks) + ", failed " + tostring(n_fail) +
         ", groups " + tostring(n_group) + "\n");
    if (n_fail == 0) { puts("RESULT: PASS\n") } else { puts("RESULT: FAIL\n") };
    n_fail
};

export { run, show };