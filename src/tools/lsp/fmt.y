// fmt.y -- the formatter.
//
// Walks the span stream from scan.y and re-lays it out. It never builds an AST
// and never asks the parser anything, which buys three things that matter more
// than canonical output:
//
//   - it runs on code that does not parse. An editor formats half-written
//     files constantly; a formatter that needs a valid AST is useless exactly
//     when it is wanted.
//   - comments survive, because scan.y finds them and tokenize throws them away.
//   - the f-string spelling survives, because the literal is never desugared.
//
// STYLE is derived from src/y/, not invented: four-space indent, `{ a: 1 }`
// with inner spaces, no space inside `( )` or `[ ]`, spaces around binary
// operators, none around `.` or a unary sign, `} else {` on one line, and the
// author's line breaks KEPT. src/y/ has lines up to 533 columns, so there is no
// wrap column to honour -- re-wrapping would be inventing structure.
//
// The acceptance test is that reformatting src/y/ is a no-op. See test-fmt.sh.
//
// REFUSES anything scan.y flagged K_error: a buffer with an unterminated
// literal is left exactly as it is rather than half-reformatted.

import scan from "./scan.y";

const INDENT = 4;

// ── small helpers over a span ───────────────────────────────────────────

def txt(src: str, s: Span) -> str { src[s.off:s.end] }

// Can this token end an expression? Decides whether the NEXT operator is
// binary or unary, which is the only thing `*` and `-` need to be told apart.
def ends_expr(src: str, s: Span, was_unary: bool) -> bool {
    let r = true;
    let k = s.kind;
    // An operator never ends a value, unary or not: in `a && !b` the `!` must
    // read as a sign, so the token before it cannot look like an operand.
    if (k == scan.K_operator) { r = false; }
    // A keyword ends a value only when it IS one: `return -1` is a sign, not
    // a subtraction, while `true` and `false` are operands.
    if (k == scan.K_keyword) {
        let t0 = txt(src, s);
        if (t0 == "true" || t0 == "false") { r = true; } else { r = false; }
    }
    if (k == scan.K_punct) {
        let t = txt(src, s);
        if (t == ")" || t == "]" || t == "}") { r = true; } else { r = false; }
    }
    r
}

// An operator in a position that cannot follow a value.
def is_unary_op(t: str) -> bool {
    t == "-" || t == "+" || t == "*" || t == "&" || t == "|" || t == "^" ||
    t == "~" || t == "!"
}

// Operators that bind to their operand instead of standing off from it. `++`
// and `--` are not arithmetic -- `depth++` is one expression, not a sum -- so
// they take no space like a sign does, whatever precedes them.
def is_tight_op(t: str) -> bool {
    is_unary_op(t) || t == "++" || t == "--"
}

// Space before `cur`? `prev` is the previous span; `was_unary` says whether it
// was a sign rather than an infix operator.
// `tight` is true when the author put NO space between `prev` and `cur`. It is
// what tells `= &x` (a tight sign) from `dl < -5` (a spaced one): no parser
// distinguishes them, the difference is visible in the source, and the
// formatter keeps what the author wrote rather than guessing.
def space_before_full(src: str, prev: Span, was_unary: bool, cur: Span, in_bracket: bool, tight: bool, prev_dot: bool, tern: bool) -> bool {
    let cc = txt(src, cur);
    let ck = cur.kind;
    if (ck == scan.K_comment) {
        return true;               // a comment always stands off
    }
    // An f-string falls through to the ordinary rules below: scan.y gives it
    // one span, and it is an atom for spacing purposes exactly like a name.
    // (It must NOT re-enter here -- doing so recursed until the stack gave
    // out, and every f-string crashed the formatter.)
    // nothing ever precedes these closely
    if (cc == ";" || cc == "," || cc == ")" || cc == "]" || cc == ".") {
        return false;
    }
    if (cc == ":") {
        // `a ? b : c` spaces it; a record key or a slice bound does not
        return tern;
    }
    if (cc == "}") {
        // `{ }` empty, `{ a: 1 }` padded: src/y/ puts a space before the brace
        // unless the block is empty, where the space comes from after the `{`.
        //
        // src/y/ also closes nested BLOCKS tight (`{ ... }};`), which this
        // cannot reproduce: `{ k: v }}` is a record inside a record and takes
        // the space. Telling the two apart needs to know what each brace
        // opened, which is parser knowledge this deliberately does not have
        // (R3.3). The spaced form is the safer error -- it never runs two
        // constructs together.
        // `{ }` and `{}` are both written in src/y; keep the author's choice
        return txt(src, prev) != "{" || !tight;
    }
    if (ck == scan.K_operator) {
        // `..` and `::` read as one word with their operands: `1..5`, `m::x`
        if (cc == ".." || cc == "::") { return false; }
        // a TIGHT `?` is the option postfix (`Leaf?`); a spaced one is the
        // ternary (`a ? b : c`), and the `:` that follows it is spaced too
        if (cc == "?" && tight) { return false; }
        // `!` after a value is always the unwrap POSTFIX: `nopt!`, never
        // `nopt !` (before a value it is the sign, handled below)
        if (cc == "!" && ends_expr(src, prev, was_unary)) { return false; }
        // after something that cannot end a value, an operator is a sign --
        // unless the author spaced it, which makes it an infix one
        if (tight && is_tight_op(cc)) {
            if (!ends_expr(src, prev, was_unary)) { return false; }
            // after a value the tight sign is POSTFIX: `x++`, and `x!` the
            // unwrap (`nopt!`, never `nopt !`)
            if (cc == "++" || cc == "--" || cc == "!") { return false; }
        }
        return true;
    }
    if (cc == "(" || cc == "[") {
        // A space unless the previous token could end a value: `len(x)` and
        // `a[0]` are one expression, while `if (`, `= [` and `+ (c - 1)` are
        // not.
        // `foreach` is a keyword, but `x.foreach(` is a method call: after a
        // dot it binds like a name, so no space.
        if (prev.kind == scan.K_keyword) { return !prev_dot; }
        if (prev.kind == scan.K_operator && was_unary) { return false; }
        let pt = txt(src, prev);
        if (pt == "(" || pt == "[" || pt == "{") { return false; }
        if (ends_expr(src, prev, was_unary)) { return false; }
        return true;
    }
    if (cc == "{") {
        // `= { ... }` and `{ { k: v } }` take a space -- src/y/ keeps a block
        // brace and the record literal inside it apart. `f({ k: v })` does not.
        let pt = txt(src, prev);
        if (pt == "(" || pt == "[") { return false; }
        return true;
    }
    // after an opener, a dot, or a range/scope operator, nothing
    let pc = txt(src, prev);
    if (pc == "(" || pc == "[" || pc == "." || pc == ".." || pc == "::") { return false; }
    // a slice bound binds tight: `a[:n]`, `a[i:j]`. In a record, a parameter
    // list or an annotation the colon takes a space after it: `{ k: v }`.
    if (in_bracket && pc == ":") { return false; }
    if (prev.kind == scan.K_operator && was_unary) { return false; }
    true
}

export { fmt, INDENT };
// Did the author put a space between two spans? Comments are spans, so every
// gap is pure whitespace, and a gap with no newline is spacing we can keep.
def gap_space(src: str, from: long, to: long) -> bool {
    let found = false;
    let i = from;
    while (i < to && i < len(src)) {
        let c = byte_at(src, i);
        if (c == 32 || c == 9) { found = true; }
        if (c == '\n') { found = false; }
        i = i + 1;
    }
    found
}

// Newlines in the gap between two spans.
def gap_lines(src: str, from: long, to: long) -> long {
    let n = 0;
    let i = from;
    while (i < to && i < len(src)) {
        if (byte_at(src, i) == '\n') { n = n + 1; }
        i = i + 1;
    }
    n
}

// ── the pass ────────────────────────────────────────────────────────────

// The formatted text, or none when the buffer contains anything scan.y could
// not classify (R3.4 -- never rewrite a buffer that does not lex).
def fmt(src: str) -> str? {
    let out: [str] = [];
    let r = scan.scan_full(src);
    if (len(r.bad) > 0) { return none; }
    let sps = r.spans;

    let depth = 0;              // brace depth: the indent unit
    let bracket = 0;            // innermost `[` depth: slice colons bind tight
    let cont = 0;               // paren/bracket depth: continuation indent
    let prev = scan.sp(0, 0, scan.K_none, 1, 1);
    let have_prev = false;
    let was_unary = false;
    let pending_blanks = 0;
    // Was the previous span preceded by a `.`? Then a keyword after it
    // (`x.foreach`) is a method name, not a statement keyword.
    let prev_dot = false;
    // For each open brace (indexed by depth - 1): was it opened inside a
    // paren? A closure body `f((s) => { ... })` is, and its own indent must
    // not ALSO take the paren continuation.
    let bparen: [bool] = [];
    // The nesting level of each pending ternary `?`. A `:` at the same level
    // is the ternary's, and takes a space before it.
    let terns: [long] = [];

    let i = 0;
    while (i < len(sps)) {
        let s = sps[i];
        let t = txt(src, s);
        let nl = 0;
        if (have_prev) { nl = gap_lines(src, prev.end, s.off); }
        let spaced = false;

        // ── line breaks ──────────────────────────────────────────────
        // The author's breaks are kept. Two or more newlines become one blank
        // line, and never inside parentheses or brackets, where a blank line
        // is a continuation break the author did not mean.
        let blanks = 0;
        if (nl >= 2 && cont == 0) { blanks = 1; }
        if (nl >= 1 || i == 0) {
            // A `}` closes a block, so it belongs to the OUTER indent: take
            // the depth off before writing it, not after. Same for a `)` or
            // `]` that opens a line, which dedents its continuation.
            let d = depth;
            let k2 = cont;
            if (s.kind == scan.K_punct) {
                if (t == "}") { if (d > 0) { d = d - 1; } }
                if (t == ")" || t == "]") { if (k2 > 0) { k2 = k2 - 1; } }
            }
            let blk = false;
            if (t == "}" && depth > 0 && depth <= len(bparen)) {
                blk = bparen[depth - 1];       // the brace this line closes
            } else if (d > 0 && d <= len(bparen)) {
                blk = bparen[d - 1];
            };
            let ind = (d + ((k2 > 0 && !blk) ? 1 : 0)) * INDENT;
            if (i == 0) {
                // no leading blank lines at the top of the file
                pending_blanks = 0;
            } else {
                pending_blanks = blanks;
            }
            if (i == 0) {
                // the first token of the file: no leading break
                let k0 = 0;
                while (k0 < ind) { out += " "; k0 = k0 + 1; }
            } else {
                let b = 0;
                while (b < pending_blanks) { out += "\n"; b = b + 1; }
                out += "\n";
                let k = 0;
                while (k < ind) { out += " "; k = k + 1; }
            }
        } else if (cont > 0 && nl == 0 && s.off > prev.end) {
            // Inside a bracket that spans lines, the gap is the author's
            // alignment and is copied through untouched. src/y/ lays record
            // literals out in columns:
            //     times: [{ name:"a:split", us:t1 - t0, heap:h1 - h0 },
            //             { name:"a:encode", us:tr0 - t1, heap:hr0 - h1 }]
            // Normalising that would destroy the table, and a formatter that
            // undoes a deliberate alignment gets turned off. So: normalise the
            // spacing of a single line, and leave a layout the author built
            // across lines exactly as written.
            let g = s.off - prev.end;
            let k3 = 0;
            while (k3 < g) { out += " "; k3 = k3 + 1; }
        } else if (s.kind == scan.K_comment) {
            // A trailing comment keeps the column the author aligned it to:
            // src/y/ lines comments up in a block, and squashing them to one
            // space would rewrite every such line.
            let g = s.off - prev.end;
            let k2 = 0;
            while (k2 < g) { out += " "; k2 = k2 + 1; }
        } else if (space_before_full(src, prev, was_unary, s, bracket > 0, !gap_space(src, prev.end, s.off), prev_dot, len(terns) > 0 && terns[len(terns) - 1] == depth + cont)) {
            out += " ";
            spaced = true;
        }

        // ── the token itself ─────────────────────────────────────────
        out += t;

        // ── depth bookkeeping, on what was just emitted ──────────────
        if (s.kind == scan.K_punct) {
            if (t == "{") {
                // Index by the depth this brace opens at, so a later brace at
                // the same level overwrites the stale flag.
                if (depth < len(bparen)) { bparen[depth] = (cont > 0); }
                else { bparen += (cont > 0); };
                depth = depth + 1;
            }
            if (t == "(") { cont = cont + 1; }
            if (t == "[") { cont = cont + 1; bracket = bracket + 1; }
            if (t == ":" && len(terns) > 0 && terns[len(terns) - 1] == depth + cont) {
                terns = terns[:len(terns) - 1];
            };
            if (t == "}") { if (depth > 0) { depth = depth - 1; } }
            if (t == ")") { if (cont > 0) { cont = cont - 1; } }
            if (t == "]") { if (cont > 0) { cont = cont - 1; } if (bracket > 0) { bracket = bracket - 1; } }
            was_unary = false;
        } else if (s.kind == scan.K_operator) {
            // Unary only when the operator CAN be a sign AND the previous token
            // cannot end a value. Testing the sign alone made every `+` unary
            // and turned `i + 1` into `i +1`.
            was_unary = is_unary_op(t) && !ends_expr(src, prev, was_unary);
            // a spaced `?` is the ternary, not the postfix of `str?`
            if (t == "?" && spaced) { terns += depth + cont; };
        } else {
            was_unary = false;
        }
        prev_dot = txt(src, prev) == ".";
        prev = s;
        have_prev = true;
        i = i + 1;
    }
    some(joined(out))
}

// Join, then tidy: no trailing spaces on a line, and exactly one final newline.
def joined(parts: [str]) -> str {
    let line = "";
    let out = "";
    let i = 0;
    while (i < len(parts)) {
        let p = parts[i];
        if (p == "\n") {
            // strip the spaces we just put at the end of this line
            let t = trim_end(line);
            out += t;
            out += "\n";
            line = "";
        } else {
            line += p;
        }
        i = i + 1;
    }
    let t = trim_end(line);
    if (t != "") { out += t; out += "\n"; }
    out
}

def trim_end(s: str) -> str {
    let end = len(s);
    let go = true;
    while (go) {
        if (end > 0) {
            let c = byte_at(s, end - 1);
            if (c == 32 || c == 9) { end = end - 1; } else { go = false; }
        } else { go = false; }
    }
    s[0:end]
}
