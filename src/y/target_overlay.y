// target_overlay.y — merge NAME.TARGET.y over NAME.y.
//
// The compiler's source splicer (native.y) and the std loader call this; the
// language server uses it too, so an open overlay shows the program the
// compiler would build.  Everything here is prefixed tov_ to stay clear of
// native.y's editor-buffer overlay (set_source_overlay), which is a different
// mechanism.
//
// A merge works on text that has already been through the meta pass: each
// file gets its own file id and line numbers, and a replaced declaration
// takes the overlay's origins with it.

import lexer from "./lexer.y";
import tags from "./tags.y";

// One line of merged source, with where it came from.  fid is the origin
// file index the caller assigned (0 is the base), line is 1-based within that
// file, and gen marks a line a meta block produced.
type TovLine = { text: str, fid: long, line: long, gen: bool };

// One top-level declaration of either file.  first/last are the line range
// including its leading comment lines; tok0/tok1 bound it in the token array.
type TovDecl = { kind: str, name: str, first: long, last: long, tok0: long, tok1: long, line: long };

// A record type's shape: its field names and their token-identical type text.
type TovType = { ok: bool, rec: bool, is_union: bool, fnames: [str], ftexts: [str] };

type TovOut = { ok: bool, err: str, lines: [TovLine] };

// The target names an overlay can be written for.  Kept here, not read from
// target.y, so the module has no part in the target graph (meta.y must not
// see target_shapes.y, and this module is linked into the resolver).
def tov_targets() -> [str] {
    ["linux", "win", "kernel", "web"]
};

// "DIR/NAME.y" + "web" -> "DIR/NAME.web.y"; "" when path is not a plain base
// file (no .y suffix, or a name that already carries a dot).
def tov_path(path: str, target: str) -> str {
    if (target == "" || !path.ends_with(".y")) {
        return "";
    };
    let stem = path[:len(path) - 2];
    let slash = last_index_of(stem, "/");
    let bn = if (slash < 0) { stem } else { stem[slash + 1:] };
    if (index_of(bn, ".") >= 0) {
        return "";
    };
    stem + "." + target + ".y"
};

// The target an overlay file is named for, or "" when the path is not
// NAME.TARGET.y for a known target.
def tov_overlay_target(path: str) -> str {
    if (!path.ends_with(".y")) {
        return "";
    };
    let stem = path[:len(path) - 2];
    let slash = last_index_of(stem, "/");
    let bn = if (slash < 0) { stem } else { stem[slash + 1:] };
    let dot = last_index_of(bn, ".");
    if (dot < 0) {
        return "";
    };
    let t = bn[dot + 1:];
    if (t in tov_targets()) { t } else { "" }
};

// "DIR/NAME.web.y" for web -> "DIR/NAME.y", else "".
def tov_base_of(path: str, target: str) -> str {
    if (tov_overlay_target(path) != target) {
        return "";
    };
    path[:len(path) - len(target) - 3] + ".y"
};

// ── declarations ────────────────────────────────────────────────────────

def tov_punct(t: Tok, v: str) -> bool {
    t.t == K.punct && t.v == v
};

def tov_kw(t: Tok, v: str) -> bool {
    t.t == K.kw && t.v == v
};

def tov_decl_kind(t: Tok) -> str {
    let v = t.v;
    if (t.t == K.kw && (v == "def" || v == "ndef" || v == "let" || v == "const")) {
        v
    } else if (t.t == K.id && (v == "type" || v == "embed")) {
        v
    } else {
        ""
    }
};

def tov_is_op(t: Tok, v: str) -> bool {
    t.t == K.op && t.v == v
};

// The index of the token that ends a declaration starting at start.  A
// def ends at its body's closing brace (and a ";" right after it), every
// other declaration at its ";"; an unterminated one ends with the last token.
def tov_end(toks: [Tok], start: long, kind: str) -> long {
    let n = len(toks);
    let i = start;
    let pd = 0;
    let bd = 0;
    let cd = 0;
    let stop = -1;
    while (i < n && stop < 0) {
        let t = toks[i];
        if (t.t == K.punct) {
            let v = t.v;
            if (v == "(") {
                pd++;
            } else if (v == ")") {
                pd--;
            } else if (v == "[") {
                bd++;
            } else if (v == "]") {
                bd--;
            } else if (v == "{") {
                if ((kind == "def" || kind == "export") && pd == 0 && bd == 0 && cd == 0) {
                    let d = 0;
                    let j = i;
                    let done = false;
                    while (j < n && !done) {
                        let u = toks[j];
                        if (tov_punct(u, "{")) {
                            d++;
                        } else if (tov_punct(u, "}")) {
                            d--;
                            if (d == 0) { done = true; };
                        };
                        if (!done) { j++; };
                    };
                    if (done) { stop = j; } else { stop = n - 1; };
                    i = j;
                } else {
                    cd++;
                };
            } else if (v == "}") {
                cd--;
            } else if (v == ";" && kind != "def" && kind != "export") {
                if (pd == 0 && bd == 0 && cd == 0) { stop = i; };
            };
        };
        i++;
    };
    if (stop < 0) { stop = n - 1; };
    if ((kind == "def" || kind == "export") && stop + 1 < n && tov_punct(toks[stop + 1], ";")) {
        stop = stop + 1;
    };
    stop
};

// The first line of a declaration, counted back over its leading comments.
// A run of "//" lines and one "/* ... */" block attach; a blank line does not.
def tov_comment_start(lines: [TovLine], first: long) -> long {
    let at = first;
    let i = first - 1;
    let open = false;
    while (i >= 1) {
        let t = trim(lines[i - 1].text);
        if (open) {
            at = i;
            if (t[:2] == "/*") { open = false; };
            i--;
        } else if (t == "") {
            i = 0;
        } else if (t[:2] == "//") {
            at = i;
            i--;
        } else if (len(t) >= 2 && t[len(t) - 2:] == "*/") {
            at = i;
            if (t[:2] != "/*") { open = true; };
            i--;
        } else {
            i = 0;
        };
    };
    at
};

// Is this line only a comment?  Used to find a declaration's start and to
// tell "an overlay holds only declarations" from blank space.
def tov_comment_line(text: str) -> bool {
    let t = trim(text);
    t[:2] == "//" || t[:2] == "/*" || (len(t) >= 2 && t[len(t) - 2:] == "*/")
};

def tov_decls(lines: [TovLine]) -> [TovDecl] {
    let texts: [str] = [];
    lines.foreach((l) => {
        texts += l.text;
    });
    let toks = lexer.tokenize(join(texts, "\n"));
    let n = len(toks);
    let out: [TovDecl] = [];
    let i = 0;
    let depth = 0;
    while (i < n) {
        let t = toks[i];
        if (t.t == K.punct) {
            if (t.v == "(" || t.v == "[" || t.v == "{") { depth++; }
            else if (t.v == ")" || t.v == "]" || t.v == "}") { depth--; };
            i++;
        } else if (depth == 0 && tov_decl_kind(t) != "" &&
            (tov_decl_kind(t) != "type" || (i + 2 < n && toks[i + 1].t == K.id && tov_is_op(toks[i + 2], "=")))) {
            let kind = tov_decl_kind(t);
            let last = tov_end(toks, i, kind);
            let name = "";
            if (i + 1 < n && toks[i + 1].t == K.id) { name = toks[i + 1].v; };
            let fl = t.line;
            let el = toks[last].line;
            out += { kind: kind, name: name, first: tov_comment_start(lines, fl), last: el,
                tok0: i, tok1: last, line: fl };
            i = last + 1;
        } else if (depth == 0 && t.t == K.id && t.v == "export" && i + 1 < n && tov_punct(toks[i + 1], "{")) {
            let last = tov_end(toks, i, "export");
            out += { kind: "export", name: "", first: tov_comment_start(lines, t.line),
                last: toks[last].line, tok0: i, tok1: last, line: t.line };
            i = last + 1;
        } else {
            i++;
        };
    };
    out
};

// ── signatures and types ────────────────────────────────────────────────

def tov_tok_text(t: Tok) -> str {
    tostring(t.t) + ":" + t.v
};

// A def's header as tokens from its def keyword to the body's opening brace
// (or an ndef's ";"), with parameter names replaced by nothing.  Comparing
// these sequences is the token-for-token signature test.
def tov_sig_keys(toks: [Tok], start: long, end: long) -> [str] {
    let out: [str] = [];
    let pd = 0;
    let bd = 0;
    let prev = "";
    let i = start;
    while (i <= end) {
        let t = toks[i];
        let skip = false;
        if (t.t == K.id && pd == 1 && bd == 0 && (prev == "(" || prev == ",")) {
            skip = true;
        };
        if (!skip) { out += tov_tok_text(t); };
        if (t.t == K.punct) {
            if (t.v == "(") { pd++; }
            else if (t.v == ")") { pd--; }
            else if (t.v == "[") { bd++; }
            else if (t.v == "]") { bd--; };
        };
        prev = t.v;
        i++;
    };
    out
};

def tov_same_toks(a: [str], b: [str]) -> bool {
    if (len(a) != len(b)) { return false; };
    let i = 0;
    let ok = true;
    while (i < len(a)) {
        if (a[i] != b[i]) { ok = false; };
        i++;
    };
    ok
};

// The last token of a def's header: the body's opening brace.  An ndef has
// no body, so its whole declaration (through the ";" and its label) is the
// header.
def tov_head_end(toks: [Tok], d: TovDecl) -> long {
    if (d.kind != "def") { return d.tok1; };
    let pd = 0;
    let bd = 0;
    let i = d.tok0;
    while (i <= d.tok1) {
        let t = toks[i];
        if (t.t == K.punct) {
            if (t.v == "(") { pd++; }
            else if (t.v == ")") { pd--; }
            else if (t.v == "[") { bd++; }
            else if (t.v == "]") { bd--; }
            else if (t.v == "{" && pd == 0 && bd == 0) { return i; };
        };
        i++;
    };
    d.tok1
};

def tov_tok_run(toks: [Tok], a: long, b: long) -> str {
    let parts: [str] = [];
    let i = a;
    while (i <= b) {
        parts += tostring(toks[i].t) + ":" + toks[i].v;
        i++;
    };
    join(parts, ".")
};

// A type declaration's shape.  is_union covers "type T = A | B;"; rec is a
// record literal; anything else (an alias) has neither.
def tov_type_info(toks: [Tok], d: TovDecl) -> TovType {
    let bad: TovType = { ok: false, rec: false, is_union: false, fnames: [], ftexts: [] };
    let n = d.tok1 + 1;
    let i = d.tok0 + 1;
    while (i < n && !tov_is_op(toks[i], "=")) { i++; };
    if (i >= n) { return bad; };
    let pd = 0;
    let bd = 0;
    let at = -1;
    let union_ = false;
    i++;
    while (i < n) {
        let t = toks[i];
        if (t.t == K.punct) {
            if (t.v == "(") { pd++; }
            else if (t.v == ")") { pd--; }
            else if (t.v == "[") { bd++; }
            else if (t.v == "]") { bd--; }
            else if (t.v == "{" && pd == 0 && bd == 0) { at = i; }
            else if (t.v == ";" && pd == 0 && bd == 0) { i = n; };
        } else if (t.t == K.op && t.v == "|" && pd == 0 && bd == 0) {
            union_ = true;
        };
        i++;
    };
    if (at < 0) {
        return { ok: true, rec: false, is_union: union_, fnames: [], ftexts: [] };
    };
    // the fields: name : type, split at commas at depth 0 inside the braces
    let fnames: [str] = [];
    let ftexts: [str] = [];
    let close = -1;
    let depth = 0;
    let j = at;
    while (j < n && close < 0) {
        if (tov_punct(toks[j], "{")) {
            depth++;
        } else if (tov_punct(toks[j], "}")) {
            depth--;
            if (depth == 0) { close = j; };
        };
        j++;
    };
    if (close < 0) { return bad; };
    let segs: [[long]] = [];
    let seg: [long] = [];
    depth = 0;
    j = at + 1;
    while (j < close) {
        let t = toks[j];
        if (t.t == K.punct && (t.v == "{" || t.v == "(" || t.v == "[")) {
            depth++;
            seg += j;
        } else if (t.t == K.punct && (t.v == "}" || t.v == ")" || t.v == "]")) {
            depth--;
            seg += j;
        } else if (tov_punct(t, ",") && depth == 0) {
            if (len(seg) > 0) { segs += seg; };
            seg = [];
        } else {
            seg += j;
        };
        j++;
    };
    if (len(seg) > 0) { segs += seg; };
    let ok = true;
    foreach (sg in segs) {
        let colon = -1;
        let k = 0;
        while (k < len(sg) && colon < 0) {
            if (tov_punct(toks[sg[k]], ":")) { colon = k; };
            k++;
        };
        if (colon < 1 || toks[sg[0]].t != K.id) {
            ok = false;
        } else {
            fnames += toks[sg[0]].v;
            let a = sg[colon + 1];
            let b = sg[len(sg) - 1];
            ftexts += if (a > b) { "" } else { tov_tok_run(toks, a, b) };
        };
    };
    { ok: ok, rec: true, is_union: false, fnames: fnames, ftexts: ftexts }
};

// The overlay record keeps every base field, with token-identical type text.
// It may add fields and reorder them.
def tov_superset(base: TovType, ov: TovType) -> bool {
    let i = 0;
    let ok = true;
    while (i < len(base.fnames)) {
        let at = -1;
        let j = 0;
        while (j < len(ov.fnames) && at < 0) {
            if (ov.fnames[j] == base.fnames[i]) { at = j; };
            j++;
        };
        if (at < 0 || ov.ftexts[at] != base.ftexts[i]) { ok = false; };
        i++;
    };
    ok
};

// The names an "export { ... };" statement lists.
def tov_export_names(toks: [Tok], d: TovDecl) -> [str] {
    let out: [str] = [];
    let i = d.tok0;
    let inside = false;
    while (i <= d.tok1) {
        let t = toks[i];
        if (tov_punct(t, "{")) { inside = true; }
        else if (tov_punct(t, "}")) { inside = false; }
        else if (inside && t.t == K.id) { out += t.v; };
        i++;
    };
    out
};

// ── the merge ───────────────────────────────────────────────────────────

def tov_line_at(lines: [TovLine], ln: long) -> TovLine {
    if (ln >= 1 && ln <= len(lines)) { lines[ln - 1] } else { { text: "", fid: 0, line: ln, gen: false } }
};

def tov_err(what: str) -> TovOut {
    { ok: false, err: what, lines: [] }
};

def tov_add_range(out: [TovLine], ov: [TovLine], a: long, b: long) -> [TovLine] {
    let i = a;
    while (i <= b) {
        out += tov_line_at(ov, i);
        i++;
    };
    out
};

def tov_overlap(a: TovDecl, b: TovDecl) -> bool {
    a.first <= b.last && b.first <= a.last
};

def tov_find_decl(ds: [TovDecl], name: str) -> long {
    let at = -1;
    let i = 0;
    while (i < len(ds) && at < 0) {
        if (ds[i].name == name && ds[i].kind != "export") { at = i; };
        i++;
    };
    at
};

def tov_find_export(ds: [TovDecl]) -> long {
    let at = -1;
    let i = 0;
    while (i < len(ds) && at < 0) {
        if (ds[i].kind == "export") { at = i; };
        i++;
    };
    at
};

def tov_find_name(xs: [str], n: str) -> long {
    let at = -1;
    let i = 0;
    while (i < len(xs) && at < 0) {
        if (xs[i] == n) { at = i; };
        i++;
    };
    at
};

def tov_texts(lines: [TovLine]) -> [str] {
    let out: [str] = [];
    lines.foreach((l) => {
        out += l.text;
    });
    out
};

// The whole merge.  base and ov already carry origins; base_name/ov_name are
// the paths the error messages name.  A failure returns the first diagnostic
// in err, unspliced.
def tov_merge(base: [TovLine], ov: [TovLine], base_name: str, ov_name: str) -> TovOut {
    let bd = tov_decls(base);
    let od = tov_decls(ov);
    let toks = lexer.tokenize(join(tov_texts(base), "\n"));
    let otoks = lexer.tokenize(join(tov_texts(ov), "\n"));
    // 1. every overlay top-level line is a declaration, a comment, an import
    // or blank; everything else is refused.
    let covered: [bool] = [];
    let i = 0;
    while (i < len(ov)) {
        covered += false;
        i++;
    };
    od.foreach((d) => {
        let l = d.first;
        while (l <= d.last && l <= len(ov)) {
            covered[l - 1] = true;
            l++;
        };
    });
    let imports: [TovLine] = [];
    i = 1;
    while (i <= len(ov)) {
        let t = trim(tov_line_at(ov, i).text);
        if (!covered[i - 1] && t != "" && !tov_comment_line(t)) {
            if (t[:7] == "import ") {
                imports += tov_line_at(ov, i);
                covered[i - 1] = true;
            } else {
                return tov_err("overlay " + ov_name + ":" + tostring(i) + ": an overlay holds only declarations");
            };
        };
        i++;
    };
    // 2. every replaced base declaration must own its lines
    let refusal = "";
    od.foreach((d, k) => {
        if (refusal == "" && d.kind != "export" && d.name != "") {
            let bi = tov_find_decl(bd, d.name);
            if (bi >= 0) {
                bd.foreach((b, j) => {
                    if (refusal == "" && j != bi && tov_overlap(b, bd[bi])) {
                        refusal = "overlay: " + base_name + ":" + tostring(b.line) +
                            " declares more than one name on a line; split it to replace '" + d.name + "'";
                    };
                });
                let oi = 0;
                while (oi < len(od) && refusal == "") {
                    if (oi != k && od[oi].kind != "export" && tov_overlap(od[oi], d)) {
                        refusal = "overlay: " + ov_name + ":" + tostring(od[oi].line) +
                            " declares more than one name on a line; split it to replace '" + d.name + "'";
                    };
                    oi++;
                };
            };
        };
    });
    if (refusal != "") { return tov_err(refusal); };
    // 3. check every replacement
    let bnames: [str] = [];
    let bdecls: [TovDecl] = [];
    bd.foreach((b) => {
        if (b.kind != "export") {
            bnames += b.name;
            bdecls += b;
        };
    });
    let replaces: [long] = [];
    let repl_ov: [long] = [];
    let repl_end: [long] = [];
    i = 0;
    while (i <= len(base)) {
        replaces += -1;
        repl_ov += -1;
        repl_end += 0;
        i++;
    };
    let synth: [str] = [];
    i = 0;
    while (i <= len(base)) {
        synth += "";
        i++;
    };
    let appended: [TovDecl] = [];
    let new_exports: [str] = [];
    od.foreach((d, k) => {
        if (refusal != "") { } else if (d.kind == "export") {
            tov_export_names(otoks, d).foreach((n) => {
                if (!(n in new_exports) && !(n in bnames)) { new_exports += n; };
            });
        } else if (d.name != "" && tov_find_name(bnames, d.name) >= 0) {
            let bi = tov_find_name(bnames, d.name);
            let b = bdecls[bi];
            if (d.kind == "def" || d.kind == "ndef") {
                if (!(b.kind == "def" || b.kind == "ndef")) {
                    refusal = "overlay " + ov_name + ":" + tostring(d.line) + ": '" + d.name +
                        "' changes the signature of " + base_name + ":" + tostring(b.line);
                } else if (!tov_same_toks(tov_sig_keys(toks, b.tok0, tov_head_end(toks, b)),
                    tov_sig_keys(otoks, d.tok0, tov_head_end(otoks, d)))) {
                    refusal = "overlay " + ov_name + ":" + tostring(d.line) + ": '" + d.name +
                        "' changes the signature of " + base_name + ":" + tostring(b.line);
                };
            } else if (d.kind == "let" || d.kind == "const") {
                if (!(b.kind == "let" || b.kind == "const")) {
                    refusal = "overlay " + ov_name + ":" + tostring(d.line) + ": '" + d.name +
                        "' changes the signature of " + base_name + ":" + tostring(b.line);
                };
            } else if (d.kind == "type") {
                let bt = tov_type_info(toks, b);
                let dt = tov_type_info(otoks, d);
                if (b.kind != "type") {
                    refusal = "overlay " + ov_name + ":" + tostring(d.line) + ": '" + d.name +
                        "' changes the signature of " + base_name + ":" + tostring(b.line);
                } else if (bt.is_union) {
                    refusal = "overlay " + ov_name + ":" + tostring(d.line) + ": a union type cannot be replaced";
                } else if (!bt.ok || !bt.rec || !dt.ok || !dt.rec || dt.is_union ||
                    !tov_superset(bt, dt)) {
                    refusal = "overlay " + ov_name + ":" + tostring(d.line) + ": type '" + d.name +
                        "' must keep every field of " + base_name + "'s (it may add fields)";
                };
            } else if (d.kind == "embed") {
                if (b.kind != "embed" || !tov_same_toks(tov_sig_keys(toks, b.tok0, tov_head_end(toks, b)),
                    tov_sig_keys(otoks, d.tok0, tov_head_end(otoks, d)))) {
                    refusal = "overlay " + ov_name + ":" + tostring(d.line) + ": '" + d.name +
                        "' changes the signature of " + base_name + ":" + tostring(b.line);
                };
            } else {
                refusal = "overlay " + ov_name + ":" + tostring(d.line) + ": '" + d.name +
                    "' changes the signature of " + base_name + ":" + tostring(b.line);
            };
            if (refusal == "") {
                replaces[b.first] = 0;
                repl_ov[b.first] = k;
                repl_end[b.first] = b.last;
            };
        } else if (d.name != "") {
            appended += d;
        };
    });
    if (refusal != "") { return tov_err(refusal); };
    // 4. the base's export statement gains the overlay's names
    let be = tov_find_export(bd);
    if (be >= 0 && len(new_exports) > 0) {
        let names = tov_export_names(toks, bd[be]);
        new_exports.foreach((n) => {
            if (!(n in names)) { names += n; };
        });
        // The export statement may span several lines (gui's does): replace the
        // whole declaration, not just its first line, or the names that
        // followed the opening brace would be parsed again as a statement.
        synth[bd[be].line] = "export { " + join(names, ", ") + " };";
        replaces[bd[be].line] = 2;
        repl_end[bd[be].line] = bd[be].last;
    } else if (be < 0) {
        od.foreach((d) => {
            if (d.kind == "export") { appended += d; };
        });
    };
    // 5. splice: a replacement takes the overlay's lines in place
    let out: [TovLine] = [];
    imports.foreach((l) => {
        out += l;
    });
    i = 1;
    while (i <= len(base)) {
        if (replaces[i] == 0) {
            let d = od[repl_ov[i]];
            out = tov_add_range(out, ov, d.first, d.last);
            i = repl_end[i] + 1;
        } else if (replaces[i] == 1) {
            let b = tov_line_at(base, i);
            out += { text: synth[i], fid: b.fid, line: b.line, gen: b.gen };
            i++;
        } else if (replaces[i] == 2) {
            let b = tov_line_at(base, i);
            out += { text: synth[i], fid: b.fid, line: b.line, gen: b.gen };
            i = repl_end[i] + 1;
        } else {
            out += tov_line_at(base, i);
            i++;
        };
    };
    // 6. new declarations go after the base's last line, in overlay order
    let seen_lines: [long] = [];
    i = 0;
    while (i < len(ov)) {
        seen_lines += 0;
        i++;
    };
    appended.foreach((d) => {
        out = tov_add_range(out, ov, d.first, d.last);
        let l = d.first;
        while (l <= d.last) {
            seen_lines[l - 1] = seen_lines[l - 1] + 1;
            l++;
        };
    });
    // two appended declarations that share a line would be inserted twice
    if (len(appended) > 0) {
        let dup = -1;
        i = 0;
        while (i < len(seen_lines)) {
            if (seen_lines[i] > 1 && dup < 0) { dup = i + 1; };
            i++;
        };
        if (dup > 0) {
            let dname = "";
            appended.foreach((d) => {
                if (d.first == dup) { dname = d.name; };
            });
            return tov_err("overlay: " + ov_name + ":" + tostring(dup) +
                " declares more than one name on a line; split it to replace '" + dname + "'");
        };
    };
    { ok: true, err: "", lines: out }
};

// A plain text merge for a unit compiled without the splicer (std_lib_src,
// the language server): the base is file 0, the overlay file 1.
def tov_merge_text(base: str, ov: str, base_name: str, ov_name: str) -> str {
    let b = tov_wrap(base, 0);
    let o = tov_wrap(ov, 1);
    let r = tov_merge(b, o, base_name, ov_name);
    if (!r.ok) {
        puts(r.err + "\n");
        exit(1);
    };
    join(tov_texts(r.lines), "\n")
};

def tov_wrap(text: str, fid: long) -> [TovLine] {
    let out: [TovLine] = [];
    let xs = split(text, "\n");
    let i = 0;
    while (i < len(xs)) {
        out += { text: xs[i], fid: fid, line: i + 1, gen: false };
        i++;
    };
    out
};

export { TovLine, TovDecl, TovOut, tov_targets, tov_path, tov_overlay_target, tov_base_of,
    tov_decls, tov_merge, tov_merge_text, tov_wrap, tov_texts, tov_type_info };
