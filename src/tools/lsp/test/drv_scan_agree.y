// scan.y against the compiler's own lexer, over every .y file in the tree.
//
// scan.y is now an ADAPTER over lexer.tokenize_lsp -- one scanner, not two --
// so this no longer checks that two implementations agree. It checks the part
// that is still a decision: the adapter's KIND (a keyword, a contextual word,
// a char, a byte literal, a comment) and the span it reports for each token.
// Comments are the one region where the compiler's own stream has nothing --
// tokenize discards them -- so they are filtered out before comparing.
//
// The file list is passed in argv by the lsp suite (src/tools/ytest/su_lsp.y).

import lexer from "../../../y/lexer.y";
import scan from "../scan.y";
import fs;

// Byte offset of a token from its 1-based line and byte column. Not the
// token's own `off`: an f-string's desugared tokens carry none (0), while their
// line and column point into the literal, which is the region they belong to.
def tok_off(starts: [long], line: long, col: long) -> long {
    let r = 0 - 1;
    if (line >= 1 && line <= len(starts)) { r = starts[line - 1] + (col - 1); };
    r
}

// Does a token's kind (a K tag) correspond to a span kind? An `id` covers a
// plain name, a contextual word and a keyword (and a char token a `7b` byte
// literal, which the scanner calls a number), since the lexer tells those
// apart by table lookup while the scanner classifies the word itself; a tag
// that is none of the literal or symbol kinds is a keyword's own.
def kind_matches(t: long, k: long) -> bool {
    if (t == K.id) { k == scan.K_ident || k == scan.K_contextual || k == scan.K_keyword }
    else if (t == K.num || t == K.bigint) { k == scan.K_number }
    else if (t == K.str) { k == scan.K_string }
    else if (t == K.bstr) { k == scan.K_bstring }
    else if (t == K.char) { k == scan.K_char || k == scan.K_number }
    else if (t == K.op) { k == scan.K_operator }
    else if (t == K.punct) { k == scan.K_punct }
    else if (t == K.ferr || t == K.stray) { k == scan.K_error }
    else { k == scan.K_keyword || k == scan.K_contextual }
}

// Lexer survives this text? It calls exit(1) on an unterminated string or block
// comment, which in a server is fatal (LSP.md R1.10), so the caller must not ask
// it about text scan has already flagged. The forked-child trick is not
// available here, so the check is skipped instead.
def lexes(src: str) -> bool {
    let r = scan.scan_full(src);
    len(r.bad) == 0
}
def check(src: str) -> { spans: long, toks: long, mismatch: long, first: str } {
    let starts = scan.line_starts(src);
    let sps = scan.scan(src);
    let toks = lexer.tokenize(src);

    // Comments and f-strings are the two regions where the two classifiers
    // deliberately differ, and both are documented reasons scan.y exists:
    // tokenize discards comments, and it desugars an f-string into
    // `(" " + #fmt(x, "") + "b")` whose tokens share one position and have no
    // extent. Both regions are dropped from BOTH sides before comparing.
    let regions: [long] = [];
    let want: [long] = [];
    let kinds: [long] = [];
    foreach (s in sps) {
        if (s.kind == scan.K_comment || s.kind == scan.K_fstring) {
            regions += s.off;
            regions += s.end;
        } else {
            want += s.off;
            kinds += s.kind;
        };
    }

    let mismatch = 0;
    let first = "";
    let ti = 0;
    while (ti < len(toks)) {
        let t = toks[ti];
        let ty = t.t;
        if (ty != K.eof && ty != K.comment) {
            let off = tok_off(starts, t.line, t.col);

            // A token in a comment or an f-string is accounted for by that
            // region's span and is not compared: tokenize discards comments
            // and desugars f-strings, so its tokens there describe something
            // else. A token exactly AT a region's start is its own (the
            // lexer's first f-string token is a `(` sitting on the literal).
            let in_region = false;
            let xi = 0;
            while (xi + 1 < len(regions)) {
                let lo = regions[xi];
                let hi = regions[xi + 1];
                if (off == lo || (off > lo && off < hi)) { in_region = true; }
                xi = xi + 2;
            }

            let found = in_region;
            if (!in_region) {
                let si = 0;
                while (si < len(want)) {
                    if (want[si] == off) {
                        if (!kind_matches(ty, kinds[si])) {
                            mismatch = mismatch + 1;
                            if (first == "") {
                                first = "kind " + ktag(ty) + " vs " + scan.kind_name(kinds[si]) +
                                        " at " + tostring(off);
                            }
                        }
                        found = true;
                    }
                    si = si + 1;
                }
            }
            if (!found) {
                mismatch = mismatch + 1;
                if (first == "") { first = "no span for " + ktag(ty) + " at " + tostring(off); }
            }
        }
        ti = ti + 1;
    }
    { spans: len(want), toks: len(toks), mismatch: mismatch, first: first }
}

let files = argv();
let bad = 0;
let total_files = 0;
let total_spans = 0;
let total_toks = 0;
let skipped = 0;
let repaired = 0;
let repair_bad = 0;

let ai = 1;                       // argv[0] is this program
while (ai < len(files)) {
    let path = files[ai];
    let got = fs.read_file(path);
    let src = "";
    if (got != none) { src = got!; };
    if (src != "") {
        if (lexes(src)) {
            let r = check(src);
            total_files = total_files + 1;
            total_spans = total_spans + r.spans;
            total_toks = total_toks + r.toks;
            if (r.mismatch > 0) {
                bad = bad + 1;
                print("MISMATCH " + path + ": " + tostring(r.mismatch) + " -- " + r.first);
            }
        } else {
            // scan flagged a literal the lexer cannot survive. The property
            // that matters here is that repair() closes it, so the server can
            // hand the document on and still get diagnostics from the rest.
            skipped = skipped + 1;
            let rp = scan.repair(src);
            let after = rp.text;
            let left = scan.scan_full(after);
            if (len(left.bad) > len(rp.bad)) {
                repair_bad = repair_bad + 1;
                print("REPAIR-FAILED " + path + ": bad " +
                      tostring(len(rp.bad)) + " -> " + tostring(len(left.bad)));
            } else {
                repaired = repaired + 1;
            }
        }
    } else {
        print("SKIP (unreadable) " + path);
    };
    ai = ai + 1;
}

print("compared " + tostring(total_files) +
      " spans " + tostring(total_spans) +
      " tokens " + tostring(total_toks) +
      " mismatched " + tostring(bad));
print("unlexable " + tostring(skipped) +
      " repaired-ok " + tostring(repaired) +
      " repair-failed " + tostring(repair_bad));