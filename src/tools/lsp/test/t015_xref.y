// t015_xref.y -- cross-file navigation, end to end (LSP.md §11.4).
//
// The single-file index answers for a name the buffer declares. This is the
// other 84%: a name declared in an IMPORTED file, where the answer has to name a
// file the client does not have open and a line in it.
//
// It pins the mechanism rather than the outcome, because the mechanism is the
// part that could change under it. The compiler's renamer gives a binding a name
// of the form `orig$N` shared by its definition and all its uses; a splice puts
// an imported module's declarations at the spliced program's TOP LEVEL; and
// `nr.origin.file` maps each spliced line back to the file it came from. Those
// three facts are what makes this work, and none of them is the LSP's to
// decide, so they are asserted here. If rename changed its naming scheme, or a
// splice stopped inlining at top level, this file fails and says which.
//
// What is deliberately NOT asserted: that a hover shows a type, or that a record's
// fields resolve after a dot. Neither is reachable from a name.

import json;
import serve from "../serve.y";
import dispatch from "../dispatch.y";
import diag from "../diag.y";
import xref from "../xref.y";
// scan.repair, parse_program, tokenize, strip_ns, rename_program_x,
// native_resolve_x and fs.* are all reachable bare: diag's path imports flatten.

const WS = "/tmp/ylsp/t015_ws";
const MAIN_URI = "file://" + WS + "/main.y";
const MOD_URI = "file://" + WS + "/mod.y";

// The import's own file, and the buffer that imports it. `mod.y` is written by
// this fixture, because the answer has to point INTO it.
const MOD = [
    "// doubles a number",
    "def helper(n: long) -> long {",
    "    n * 2",
    "}",
    "",
    "let TOP: long = 7;",
    "",
    "type Pair = { a: long, b: long };",
    "",
    "let both = TOP + TOP;"
];
const MAIN = [
    "import helper from \"./mod.y\";",
    "",
    "let v = helper.helper(3);",
    "print(helper.TOP + v);"
];

// The SAME module, imported BY NAME instead of by path -- a different shape, and
// broken.
//
// `import mod;` resolves through `std_resolve` (next to the importer), and a
// module imported by name KEEPS ITS NAMESPACE, so `mod.TOP` stays a qualified
// Dot and the spliced top level spells the name `mod.TOP`. A PATH import is
// flattened by `strip_ns` instead, so the same name is spliced as `TOP`.
//
// `serve.resolve_name` looked up the bare spelling only, so every member of a
// by-name import was unreachable: ctrl-click answered null, and the hover had a
// type with no declaration under it. `examples/bignum` is this shape -- `bn` is
// not a std unit, it is the file next to it -- and the user reported that.
const MAIN3 = [
    "import mod;",
    "",
    "print(mod.TOP + mod.helper(2));",
];

def fresh() -> State { serve.server_state(WS, "", 0) }

def did_open(uri: str, text: str, version: long) -> { str => json.Val } {
    let td = json.obj();
    td["uri"] = json.str(uri);
    td["languageId"] = json.str("y");
    td["version"] = json.num(version);
    td["text"] = json.str(text);
    let p = json.obj();
    p["textDocument"] = json.jobj(td);
    p
}

def at(uri: str, line: long, character: long) -> json.Val {
    let posn = json.obj();
    posn["line"] = json.num(line);
    posn["character"] = json.num(character);
    let td = json.obj();
    td["uri"] = json.str(uri);
    let p = json.obj();
    p["textDocument"] = json.jobj(td);
    p["position"] = json.jobj(posn);
    json.jobj(p)
}

def is_null(v: json.Val) -> bool {
    if let json.Null _ = v { true } else { false }
}

def field(v: json.Val, k: str) -> json.Val {
    serve.field_of(serve.members_of(v), k)
}

def ask(st: State, id: long, method: str, p: json.Val) -> json.Val {
    let raw = dispatch.doc_request(st, json.num(id), method, serve.params_of(p));
    let got = json.parse(raw);
    let out = json.nul();
    if is_some(got) { out = json.jobj(got!); };
    field(out, "result")
}

def at_line(v: json.Val, k: str) -> long {
    let got = json.as_long(serve.field_of(serve.members_of(field(v, k)), "line"));
    let out = 0;
    if is_some(got) { out = got!; };
    out
}

def at_char(v: json.Val, k: str) -> long {
    let got = json.as_long(serve.field_of(serve.members_of(field(v, k)), "character"));
    let out = 0;
    if is_some(got) { out = got!; };
    out
}

def str_of(v: json.Val) -> str {
    let got = json.as_str(v);
    let out = "";
    if is_some(got) { out = got!; };
    out
}

// ── the mechanism, on the real pipeline ──────────────────────────────────
//
// This is diag.diagnose's own first three steps, kept so the assertions below
// are about the compiler's output and not about the server's request handling.
fs.make_dirs(WS);
fs.write_file(WS + "/mod.y", join(MOD, "\n"));

// The by-name import's own buffer. Opened as a SECOND document so what is under
// test is the shape of the NAME, not the index cache.
const MAIN3_URI = "file://" + WS + "/main3.y";
let main_text = join(MAIN, "\n");
let nr = native_resolve_x(main_text, WS, 0, true, WS + "/main.y");
let ast = parse_program(tokenize(scan.repair(nr.src).text));
let ast2: Block = strip_ns(ast, nr.imports);
let ast3: Block = rename_program_x(ast2, [], nr.origin.file, nr.origin.mods);
let x = xref.tops_of(ast3);

print("-- what the spliced program's top level actually holds");
let kinds = "";
let ki = 0;
while (ki < len(ast3.stmts)) {
    let kn = ast3.stmts[ki];
    let knm = "";
    if (kn.k == K.decl) { let kd: Decl = kn; knm = " " + kd.name };
    if (kn.k == K.typedef) { let kt: TypeDef = kn; knm = " " + kt.name };
    kinds = kinds + "[" + ktag(kn.k) + knm + "]";
    ki = ki + 1;
};
print("top level: " + kinds);

print("-- rename's naming scheme, which everything here rests on");
// A renamed binding is `orig$N`. If this ever stops being true the cross-file
// pairing has nothing to pair on, so it is asserted rather than assumed.
let renamed = 0;
let plain = 0;
let tops = keys(x.tops);
let i = 0;
while (i < len(tops)) {
    let got = x.tops[tops[i]];
    if is_some(got) {
        let t: Top = got!;
        if (index_of(t.uniq, "$") > 0) { renamed = renamed + 1; } else { plain = plain + 1; };
    };
    i = i + 1;
};
print("top-level declarations: " + tostring(len(tops)) + ", renamed " + tostring(renamed) +
      ", not renamed " + tostring(plain));

print("-- an imported module's declarations are TOP LEVEL of the spliced program");
print("helper found: " + tostring(is_some(xref.top_decl(x, "helper"))));
print("TOP found: " + tostring(is_some(xref.top_decl(x, "TOP"))));
// `Pair` is ABSENT, and that is not an oversight in xref.y: `rn_drop_typedefs`
// removes every top-level `typedef` from the statement list, because an alias has
// no value and nothing to emit -- the alias survives in the checker's `st.tys`,
// not as a node. So a tree walk cannot see it. The compiler's own qualified
// spelling of such an alias is also broken (an imported module's type alias
// does not resolve under its qualified name), which is why this is worth
// pinning rather than working around.
print("Pair (a `type` alias, hoisted out of the tree by rename): " +
      tostring(is_some(xref.top_decl(x, "Pair"))));
print("both found: " + tostring(is_some(xref.top_decl(x, "both"))));
// And the SPLICE order: the import comes first, so the module's lines are
// before the buffer's own. This is what makes origin.file a usable map.
let h = xref.top_decl(x, "helper")!;
let t = xref.top_decl(x, "TOP")!;
print("helper is on spliced line " + tostring(h.line) + ", TOP on " + tostring(t.line));
print("mod.y's lines come before main.y's: " + tostring(t.line > h.line));

print("-- the origin map sends each of them back to the right file");
print("helper's file: " + diag.file_of(nr.origin, h.line));
print("TOP's file: " + diag.file_of(nr.origin, t.line));
print("v is the buffer's own: " + diag.file_of(nr.origin, xref.top_decl(x, "v")!.line));

print("-- one name, two files: the pairing itself");
// The use of TOP in main.y is at line 3. Read the spliced program at that line
// and the renamed AST must carry the SAME unique name the declaration does.
// This is the claim that replaces the compiler change.
// main.y line 3 is `print(helper.TOP + v);`, but that is line 3 of the BUFFER,
// and the spliced program's lines are what the AST is indexed by -- mod.y's ten
// lines come first. So find the line rather than assuming: hardcoding it is what
// made the first version of this assert false for the wrong reason.
let src_lines = nr.src.split("\n");
let use_text = MAIN[3];   // the `print(helper.TOP + v);` line
let use_line = 0;
let si2 = 0;
while (si2 < len(src_lines)) {
    if (src_lines[si2] == use_text) { use_line = si2 + 1; };
    si2 = si2 + 1;
};
print("the use is on spliced line " + tostring(use_line) + ": " + src_lines[use_line - 1]);
let same = false;
let use_name = "";
let aj = 0;
while (aj < len(ast3.stmts)) {
    let n = ast3.stmts[aj];
    if (n.line == use_line) {
        // dig for the ids on this statement
        let ids: [str] = [];
        collect_ids(n, ids);
        let jj = 0;
        while (jj < len(ids)) {
            if (ids[jj] == t.uniq) { same = true; use_name = ids[jj]; };
            jj = jj + 1;
        };
    };
    aj = aj + 1;
};
print("the use carries the declaration's own unique name " + t.uniq + ": " + tostring(same));

print("-- what the server answers");
// The real thing, through the dispatcher, against a live open buffer.
let st = fresh();
serve.note_open(st, did_open(MAIN_URI, main_text, 1));

// main.y line 2 is `let v = helper.helper(3);` -- `helper` at 14, the member
// name at 21. Line 3 is `print(helper.TOP + v);` -- `helper` at 6, `TOP` at 13.
let d1 = ask(st, 1, "textDocument/definition", at(MAIN_URI, 2, 21));
print("definition of helper.helper -> " + loc_str(d1));
let d2 = ask(st, 2, "textDocument/definition", at(MAIN_URI, 3, 13));
print("definition of helper.TOP -> " + loc_str(d2));
let d3 = ask(st, 3, "textDocument/definition", at(MAIN_URI, 3, 20));
print("definition of v (the buffer's own) -> " + loc_str(d3));

// ── the same module imported BY NAME: the names keep their namespace ──────
//
// Line 2 is `print(mod.TOP + mod.helper(2));` -- `mod` at 6, `TOP` at 10, and
// `helper` at 20. Written out rather than found, which is the mistake this file's
// own header warns about; a wrong column here answers about `mod` and the test
// passes for the wrong reason, so the two that matter are asserted by content too.
serve.note_open(st, did_open(MAIN3_URI, join(MAIN3, "\n"), 1));
let n1 = ask(st, 4, "textDocument/definition", at(MAIN3_URI, 2, 10));
print("definition of mod.TOP -> " + loc_str(n1));
let n2 = ask(st, 5, "textDocument/definition", at(MAIN3_URI, 2, 20));
print("definition of mod.helper -> " + loc_str(n2));
// And the hover carries the SIGNATURE, not just the call's return type -- which is
// what "hovering bn_from_long shows long instead of the header" was.
let n3 = ask(st, 6, "textDocument/hover", at(MAIN3_URI, 2, 20));
print("hover of mod.helper carries the signature: " + tostring(index_of(hover_str(n3), "helper(n: long) -> long") >= 0));

let h1 = ask(st, 4, "textDocument/hover", at(MAIN_URI, 2, 21));
print("hover on helper.helper: " + hover_str(h1));
// A cross-file hover shows a TYPE as well as the declaration, and that is not
// extra: the checker indexes by the SPLICED line, so getting `long` here means
// `Prepared.mine` mapped this buffer's line to the right line of the spliced
// program -- which was wrong by one until it was derived from the two line counts
// rather than from `origin.file`, and the symptom was a hover on a BLANK line
// returning the next line's type. See xref.own_lines; client-check.js pins the
// symptom.
let h2 = ask(st, 5, "textDocument/hover", at(MAIN_URI, 3, 13));
print("hover on helper.TOP: " + hover_str(h2));

print("-- and what it refuses");
print("a name no file declares: " +
      tostring(is_null(ask(st, 6, "textDocument/definition", at(MAIN_URI, 1, 0)))));

print("done");

// ── helpers ──────────────────────────────────────────────────────────────

// Every identifier a statement READS, as (name, line) pairs -- the pairing claim
// needs the reads, and the renamed AST is where they carry unique names.
def collect_ids(n: Node, out: [str]) -> void {
    if (n.k == K.id) {
        let l: Leaf = n;
        out += l.v;
    } else if (n.k == K.call) {
        let c: Call = n;
        collect_ids(c.callee, out);
        each(c.args, out);
    } else if (n.k == K.bin) {
        let b: Bin = n;
        collect_ids(b.l, out);
        collect_ids(b.r, out);
    } else if (n.k == K.dot) {
        let d: Dot = n;
        collect_ids(d.obj, out);
    } else if (n.k == K.decl) {
        let d: Decl = n;
        collect_ids(d.v, out);
    } else if (n.k == K.block) {
        let b: Block = n;
        each(b.stmts, out);
    } else if (n.k == K.assign) {
        let a: Assign = n;
        collect_ids(a.v, out);
    };
}

def each(xs: [Node], out: [str]) -> void {
    let i = 0;
    while (i < len(xs)) { collect_ids(xs[i], out); i = i + 1; }
}

def loc_str(v: json.Val) -> str {
    if (is_null(v)) { return "null" };
    str_of(field(v, "uri")) + ":" + tostring(at_line(field(v, "range"), "start")) +
        ":" + tostring(at_char(field(v, "range"), "start"))
}

def hover_str(v: json.Val) -> str {
    if (is_null(v)) { return "null" };
    str_of(field(field(v, "contents"), "value")).replace("\n", "|")
}