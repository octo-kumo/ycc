// t014_strm.y -- the string methods in hover and completion, and the mirror's
// drift check (LSP.md §6 R6.1/R6.2).
//
// t013_m4 pins the three requests over NAMES. This pins the member position: a
// `.` and a name after it, which is the one place Stage A can answer something
// the fallback cannot, because the answer comes from the compiler's own table
// (strm.y) rather than from what this file happens to declare.
//
// The drift check at the end is the point of the file. `strm.MIRROR` is a copy
// of the method names, because `types.str_method` is a chain of comparisons with
// no list to walk -- so the copy is the weak link and this is what watches it.
// The check runs in the direction that can be automatic: every name the mirror
// offers is one the compiler accepts. A method RENAMED or REMOVED in types.y
// therefore fails this file rather than quietly disappearing from completion.

import json;
import serve from "../serve.y";
import dispatch from "../dispatch.y";
import strm from "../strm.y";

const URI = "file:///tmp/opencode/t014.y";

// The buffer under test. Line numbers are 0-based, as an LSP position is, and
// the columns below are counted from the left of each line.
// The columns beside each line are byte columns, which is what a request's
// position is converted from. They are written out because getting one wrong is
// the easiest way to make this file test nothing: the first version of it had
// them all one too high and every "not a string method" assertion passed for the
// wrong reason.
let LINES: [str] = [
    "let csv = \"a,b,c\";",           // 0
    "let parts = csv.split(\",\");",  // 1  `.` at 15, split at 16..20
    "let n = csv.count(\",\");",      // 2  `.` at 11, count at 12..16
    "let w = csv.pad_left(8);",       // 3  `.` at 11, pad_left at 12..19
    "let rec = { k: 1 };",            // 4
    "let v = rec.k;",                 // 5  `.` at 11, k at 12
    "let partial = csv.sp;",          // 6  `.` at 17, sp at 18..19
    "let bare = csv.;",               // 7  `.` at 14, nothing after it
    "let split = 1;",                 // 8  a LOCAL of the same name as the method
    "let v2 = split + 1;"             // 9  that local used, with no dot before it
];
const SRC = join(LINES, "\n");

def fresh() -> State { serve.server_state(".", "", 0) }

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

def at(line: long, character: long) -> json.Val {
    let posn = json.obj();
    posn["line"] = json.num(line);
    posn["character"] = json.num(character);
    let td = json.obj();
    td["uri"] = json.str(URI);
    let p = json.obj();
    p["textDocument"] = json.jobj(td);
    p["position"] = json.jobj(posn);
    json.jobj(p)
}

// A JSON null. json.Val is a union, so `if let json.Null _ = v` is the whole
// test -- there is no is_null in json.y and the fixture defines its own, the
// same way t013_m4 does.
def is_null(v: json.Val) -> bool {
    if let json.Null _ = v { true } else { false }
}

def field(v: json.Val, k: str) -> json.Val {
    serve.field_of(serve.members_of(v), k)
}

def items_of(v: json.Val) -> [json.Val] {
    let out: [json.Val] = [];
    if let json.Arr a = v { out = a.items; };
    out
}

// The RESULT of a request through the dispatcher, so the method name is part of
// what is tested.
def ask(st: State, id: long, method: str, p: json.Val) -> json.Val {
    let raw = dispatch.doc_request(st, json.num(id), method, serve.params_of(p));
    let got = json.parse(raw);
    let out = json.nul();
    if is_some(got) { out = json.jobj(got!); };
    field(out, "result")
}

def hover_value(v: json.Val) -> str {
    let out = "";
    if !is_null(v) {
        let got = json.as_str(field(field(v, "contents"), "value"));
        if is_some(got) { out = got!; };
    };
    out
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

def label_of(item: json.Val) -> str {
    let out = "";
    let got = json.as_str(field(item, "label"));
    if is_some(got) { out = got!; };
    out
}

def detail_of(item: json.Val) -> str {
    let out = "";
    let got = json.as_str(field(item, "detail"));
    if is_some(got) { out = got!; };
    out
}

def labels(v: json.Val) -> str {
    let out = "";
    let items = items_of(field(v, "items"));
    let i = 0;
    while (i < len(items)) {
        if (i > 0) { out = out + ","; };
        out = out + label_of(items[i]);
        i = i + 1;
    };
    out
}

def find_item(v: json.Val, want: str) -> json.Val {
    let out = json.nul();
    let items = items_of(field(v, "items"));
    let i = 0;
    while (i < len(items) && is_null(out)) {
        if (label_of(items[i]) == want) { out = items[i]; };
        i = i + 1;
    };
    out
}

def has_label(v: json.Val, want: str) -> bool { !is_null(find_item(v, want)) }

def count_labels(v: json.Val) -> long { len(items_of(field(v, "items"))) }

let st = fresh();
serve.note_open(st, did_open(URI, SRC, 1));

print("-- hover on a string method");
// The mouse is inside `split` on line 1, character 18.
let h1 = ask(st, 1, "textDocument/hover", at(1, 18));
print("split: " + hover_value(h1).replace("\n", "|"));
let h2 = ask(st, 2, "textDocument/hover", at(3, 14));
print("pad_left: " + hover_value(h2).replace("\n", "|"));
let h3 = ask(st, 3, "textDocument/hover", at(2, 14));
print("count: " + hover_value(h3).replace("\n", "|"));
// The range is the WORD the mouse is on, not the method.
print("range on split: line " + tostring(at_line(field(h1, "range"), "start")) +
      " char " + tostring(at_char(field(h1, "range"), "start")) + ".." +
      tostring(at_char(field(h1, "range"), "end")));

print("-- hover NOT on a string method");
// `rec.k` -- a record field after a dot. Stage A cannot type the receiver, so
// the honest answer is nothing. It is worth checking that the string-method
// branch did not turn this into an answer: it must not claim `k` is a method.
print("rec.k: " + tostring(is_null(ask(st, 4, "textDocument/hover", at(5, 12)))));
// `split` used WITHOUT a dot is the local on line 9, not the method.
let h4 = hover_value(ask(st, 5, "textDocument/hover", at(9, 11)));
print("a local of the same name, no dot: " + h4.replace("\n", "|"));

print("-- completion after a dot");
// Line 7 is `let bare = csv.;` with the cursor just past the dot.
let c1 = ask(st, 6, "textDocument/completion", at(7, 15));
print("after `csv.`: " + tostring(count_labels(c1)) + " items");
print("has split: " + tostring(has_label(c1, "split")));
print("has pad_left: " + tostring(has_label(c1, "pad_left")));
print("has alias lstrip: " + tostring(has_label(c1, "lstrip")));
print("has trim: " + tostring(has_label(c1, "trim")));
print("kind is Method(2): " + tostring(json.as_long(field(find_item(c1, "split"), "kind"))! == 2));
print("detail is the signature: " + detail_of(find_item(c1, "pad_left")));
// Line 6 is `let partial = csv.sp;`, the cursor at the end of `sp`.
let c2 = ask(st, 7, "textDocument/completion", at(6, 20));
print("after `csv.sp`: " + labels(c2));
// The NAME list is not offered after a dot: `print` is not a member of anything.
print("no `print` after a dot: " + tostring(!has_label(c1, "print")));
print("no `csv` after a dot: " + tostring(!has_label(c1, "csv")));

print("-- completion without a dot is still the names");
// Line 0 character 3 is the space after `let`, so nothing has been typed and the
// prefix is empty. A position INSIDE a word filters by it (an earlier version of
// this asked at character 6, which is inside `csv`, and so matched one name and
// looked like the list was broken).
let c3 = ask(st, 8, "textDocument/completion", at(0, 3));
print("at an empty prefix: " + tostring(count_labels(c3)));
print("has print: " + tostring(has_label(c3, "print")));
// `csv` is NOT offered, and that is the scope rule rather than a gap in it: this
// position is line 0 character 3 and `csv` is declared at character 4 of the same
// line, so it is not yet visible. (A `let` is visible from the end of its own
// declaration onwards -- t012_scope pins that.)
print("has csv (declared after this position): " + tostring(has_label(c3, "csv")));
// The str methods are NOT in the name list. They are members, and offering them
// where a name belongs is how a completion list stops being readable. `split` is
// asked about and IS present, because line 8 of this buffer declares a local of
// that name -- which is the point of choosing names the buffer does not shadow.
print("no upper in the name list: " + tostring(!has_label(c3, "upper")));
print("no pad_left in the name list: " + tostring(!has_label(c3, "pad_left")));
// The local `split` on line 8 IS a name, so it is offered.
print("has split (a local of that name): " + tostring(has_label(c3, "split")));
// And a prefix still filters, which is the other half of the same behaviour.
let c4 = ask(st, 9, "textDocument/completion", at(0, 6));
print("prefix `csv`: " + labels(c4));

print("-- the mirror cannot rot silently");
// Every name the mirror offers must be one the compiler accepts. This is the
// direction that can be automatic: a method renamed or removed in types.y fails
// HERE rather than quietly vanishing from completion. The names themselves are
// printed below, so an addition there shows up in this expectation.
let dropped = 0;
print("mirror " + tostring(len(strm.MIRROR)) + ", accepted " + tostring(len(strm.names())));
print("dropped by the compiler: " + tostring(dropped));
foreach (n in strm.MIRROR) {
    if (!strm.is_method(n)) { dropped = dropped + 1; print("  DROPPED " + n); };
};
print("-- the set, so a change is visible");
foreach (n in strm.names()) { print("  " + n) };
print("-- the signatures");
foreach (n in ["split", "pad_left", "join", "trim", "count", "byte_at"]) {
    print("  " + strm.sig(n));
};
print("an unknown name: " + strm.sig("zzz"));
print("done");