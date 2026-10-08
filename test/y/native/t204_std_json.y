// std/json: the value model, the parser, the printer, and the four edges a
// caller gets wrong -- trailing data, duplicate keys, null as a value rather
// than an absence, and the depth limit truncating on the way OUT.
//
// Every name the manual's json section documents is called here. That is not
// tidiness: src/tools/ytest/su_coverage.y extracts the name out of each \ic{name( in the
// manual and requires a checked test to call <module>.<name>(, so a name
// documented but never called is reported as uncovered. The LSP's own fixtures
// (src/tools/lsp/test/t001, t002) cover the same ground from the other side --
// they drive the module as the server's transport -- but they live outside the
// directory the coverage gate reads, so they cannot stand in for this.
import json from "../../../src/y/std/json.y";
import test from "../../../src/y/std/test.y";

// the smallest document that is an object and nothing else
const DOC = "{\"id\":7,\"name\":\"ada\",\"ok\":true,\"nothing\":null,"
          + "\"tags\":[\"x\",\"y\"],\"ratio\":1.50,\"sub\":{\"deep\":1}}";

const PRETTY = "{\n  \"id\": 7,\n  \"name\": \"ada\",\n  \"ok\": true,"
             + "\n  \"nothing\": null,\n  \"tags\": [\n    \"x\",\n    \"y\"\n  ],"
             + "\n  \"ratio\": 1.50,\n  \"sub\": {\n    \"deep\": 1\n  }\n}";

def main() -> long {
    test.group("a document parses, and every shape reads back");
    let top = json.parse(DOC);
    test.ck("the top level of an object is the bare map", top != none, DOC);
    let bare = top!;
    let v = json.jobj(bare);

    test.ck_eq("get_long on a number", json.get_long(v, "id", -1), 7);
    test.ck_str("get_str on a string", json.get_str(v, "name", "?"), "ada");
    test.ck_eq("get_long takes the default for a null",
        json.get_long(v, "nothing", -1), -1);
    test.ck_eq("and for an absent key", json.get_long(v, "absent", -1), -1);
    test.ck_eq("and for a member of the wrong shape",
        json.get_long(v, "name", -1), -1);

    let got = json.get_arr(v, "tags");
    test.ck("get_arr on an array", got != none, "two tags");
    let tags = got!;
    test.ck_eq("of the length it has", tags.length, 2);
    test.ck("get_arr is still an option, so it has no default form", {
        json.get_arr(v, "absent") == none
    }, "none, and nothing to fall back on");

    // One binding per member, because `!` binds to the innermost postfix
    // expression: json.as_long(json.field(v, "id")!) unwraps the FIELD and
    // leaves as_long's own option behind, so the second `!` is not optional
    // however it is bracketed. Naming them also reads better than the nesting.
    let m_id = json.field(v, "id")!;
    let m_name = json.field(v, "name")!;
    let m_ok = json.field(v, "ok")!;
    let m_null = json.field(v, "nothing")!;
    let m_tags = json.field(v, "tags")!;
    let m_sub = json.field(v, "sub")!;

    test.ck_eq("as_long", json.as_long(m_id)!, 7);
    test.ck_str("as_str", json.as_str(m_name)!, "ada");
    test.ck("as_bool", json.as_bool(m_ok)! == true, "true");
    test.ck_eq("as_arr", (json.as_arr(m_tags)!).length, 2);
    test.ck_eq("as_obj", json.keys_of((json.as_obj(m_sub)!)).length, 1);
    test.ck("is_null on a null", json.is_null(m_null),
        "true, and it is not an absence");
    test.ck("and not on a string", !json.is_null(m_name), "false");

    test.ck("every as_* answers none for the wrong shape, and traps for none", {
        json.as_long(m_name) == none
        && json.as_str(m_id) == none
        && json.as_arr(m_id) == none
        && json.as_obj(m_id) == none
        && json.as_bool(m_id) == none
    }, "a number is not a string and none of them is a number");

    test.ck_str("keys come back in insertion order",
        tostring(json.keys_of(bare)), "[id, name, ok, nothing, tags, ratio, sub]");

    test.ck("an absent key, a non-object and a bad index are all none", {
        json.field(v, "absent") == none
        && json.field(json.num(1), "anything") == none
        && json.index(json.jarr(json.arr()), 0) == none
        && json.index(m_tags, 9) == none
    }, "an array read is total otherwise, so this is the bounds test");
    test.ck_str("and an index in range is the element", {
        tostring(json.index(m_tags, 1))
    }, tostring(json.str("y")));

    test.group("as_long is tolong over the text: a WHOLE number, or none");
    // The block used to carry five numbers the compiler produced by stopping at
    // the first non-digit and wrapping past 64 bits, with a comment saying every
    // one of them was "a reasonable assumption a caller would bring ... and
    // every one of them is wrong". tolong requires a fully valid input now, so
    // all five are none, and the comment is true of the old answers rather than
    // the new ones: a caller who brings those assumptions gets nothing to use.
    test.ck_eq("\"3.9\" is none, not 3", if (json.as_long(json.numtext("3.9")) == none) { 1 } else { 0 }, 1);
    test.ck_eq("\"-3.9\" is none, not -3", if (json.as_long(json.numtext("-3.9")) == none) { 1 } else { 0 }, 1);
    test.ck_eq("\"1e10\" is none, not 1", if (json.as_long(json.numtext("1e10")) == none) { 1 } else { 0 }, 1);
    test.ck_eq("\"1.50\" is none, not 1", if (json.as_long(json.numtext("1.50")) == none) { 1 } else { 0 }, 1);
    test.ck_eq("and past 64 bits it is none, not a wrapped number", if (json.as_long(json.numtext("12345678901234567890123")) == none) { 1 } else { 0 }, 1);
    test.ck_str("while the text itself is preserved exactly", {
        json.stringify_val(json.numtext("1.50"), 0)
    }, "1.50");

    test.group("four edges a caller gets wrong");
    // 1. Trailing data is an error for all three parsers, and an empty document
    // is none -- while an empty OBJECT is a value with no members.
    test.ck("trailing data is refused", {
        json.parse_val("{} {}") == none
        && json.parse_val("{} x") == none
        && json.parse("{\"a\":1} junk") == none
    }, "so two documents in a row never parse as one");
    test.ck("an empty document is none", {
        json.parse_val("") == none && json.parse_val("   \n ") == none
    }, "not an empty object");
    // parse_err is the entry to reach for when a document is refused and the
    // question is why: the same parse, plus the message and the byte offset.
    let e1 = json.parse_err("{\"a\": }");
    test.ck("parse_err says where, not just that", {
        !e1.ok && e1.value == none && e1.at == 6 && e1.err == "unexpected '}'"
    }, "at 6, one past the value that was expected");
    let e2 = json.parse_err("{\"a\": 1} extra");
    test.ck("and it distinguishes trailing data from a bad value", {
        !e2.ok && e2.err == "trailing 'e'" && e2.at == 9
    }, "trailing, at the first byte of the junk");
    let e3 = json.parse_err("");
    test.ck_str("an empty document has its own message", e3.err,
        "empty document");
    let e4 = json.parse_err("{\"a\": 1}");
    test.ck("and a good document reports ok with no message", {
        e4.ok && e4.err == "" && e4.value != none
    }, "ok, empty err, and the value"); 
    test.ck("but an empty object is a value", {
        let e = json.parse("{}");
        e != none && json.keys_of(e!).length == 0
    }, "no members");

    // 2. Duplicate keys: the last value wins and it keeps the first position.
    let dup = json.parse("{\"a\": 1, \"b\": 2, \"a\": 3}");
    test.ck_eq("a duplicate key keeps the last value",
        json.get_long(json.jobj(dup!), "a", -1), 3);
    test.ck_str("and the first position", tostring(json.keys_of(dup!)),
        "[a, b]");

    // 3. null is a value. Present, printable, and not an absence.
    test.ck_str("and it prints as null", {
        json.stringify_val(json.nul(), 0)
    }, "null");

    // 4. The depth limit: the parser refuses, the PRINTER truncates -- and what
    // it produces is not JSON. Both halves are checked, because only the first
    // one is an error.
    test.ck_eq("the limit is 200", json.json_depth_max, 200);
    test.ck_str("and the marker is that text", json.json_depth_error,
        "<json: too deep>");
    test.ck("the parser refuses past it and accepts under it", {
        json.parse_val(json_deep(260)) == none
        && json.parse_val(json_deep(101)) != none
    }, "101 accepted, 260 refused");
    let out = json.stringify_val(json_tall(210), 0);
    test.ck("the printer does not refuse: the marker goes in", {
        json.index_of(out, json.json_depth_error) >= 0
    }, "so that string, not an error, is the caller's only sign");
    test.ck("which means the printed tree does NOT parse back", {
        json.parse_val(out) == none
    }, "the output is not valid JSON and nothing said so");

    test.group("the printer");
    test.ck_str("stringify is compact: no space after : or ,",
        json.stringify(bare), DOC);
    test.ck_str("stringify_obj is the same at depth 0",
        json.stringify_obj(bare, 0), DOC);
    test.ck_str("stringify_val is the same for the wrapped value",
        json.stringify_val(v, 0), DOC);
    test.ck_str("pretty is one member per line", json.pretty(v, 2, false),
        PRETTY);
    test.ck_str("pretty_val is what pretty calls",
        json.pretty_val(v, 0, 2, false), PRETTY);
    test.ck("pretty(sorted) reorders members, and only pretty does", {
        let doc_order = json.pretty(v, 0, false);
        let byte_order = json.pretty(v, 0, true);
        json.index_of(doc_order, "\"id\"") < json.index_of(doc_order, "\"nothing\"")
            && json.index_of(byte_order, "\"id\"") > json.index_of(byte_order, "\"absent\"")
    }, "stringify and keys_of never sort");
    test.ck_str("sort_keys is a new list in byte order",
        tostring(json.sort_keys(["b", "a", "c"])), "[a, b, c]");
    test.ck("and it does not touch the list it was given", {
        let ks = ["b", "a"];
        json.sort_keys(ks);
        ks[0] == "b"
    }, "an insertion sort, and quadratic");

    test.group("same, node_count and max_depth");
    test.ck("same compares numbers as TEXT", {
        !json.same(json.parse_val("1.5")!, json.parse_val("1.50")!)
    }, "so two documents any other library calls equal compare unequal here");
    test.ck("but it is structural, and order-insensitive for members", {
        json.same(json.jobj(json.parse("{\"a\":1,\"b\":2}")!),
            json.jobj(json.parse("{\"b\":2,\"a\":1}")!))
    }, "member order does not matter");
    test.ck_eq("node_count counts the containers too", json.node_count(v), 11);
    test.ck_eq("max_depth of that document", json.max_depth(v), 3);
    test.ck_eq("and a scalar is depth 1", json.max_depth(json.num(1)), 1);

    test.group("escape, utf8_put and hex2");
    test.ck_str("escape quotes a body without its quotes",
        json.escape("a\"b"), "a\\\"b");
    test.ck_str("and a backslash", json.escape("a\\b"), "a\\\\b");
    test.ck_str("and the C0 controls by name", json.escape("\n\t"),
        "\\n\\t");
    test.ck_str("hex2 is two lowercase digits", json.hex2(10), "0a");
    test.ck_str("hex2 of zero", json.hex2(0), "00");
    test.ck_eq("utf8_put appends one code point as UTF-8", {
        json.utf8_put(json.utf8_put([], 65), 233).length
    }, 3);

    test.group("the parser's own cursor");
    // A P is { s, i }; at, lit and p_show are what the module's own parser uses,
    // and are exported for a caller writing one over the same primitives.
    let p = { s: "true rest", i: 0 };
    test.ck_eq("at is the byte at the cursor", json.at(p), 116);
    test.ck("lit matches and consumes", json.lit(p, "true"), "true");
    test.ck_eq("having consumed it, at has moved", json.at(p), 32);
    let q = { s: "nope", i: 0 };
    test.ck("lit does not consume what it does not match", !json.lit(q, "true"),
        "false");
    test.ck_eq("and leaves the cursor where it was", json.at(q), 110);
    test.ck_str("p_show quotes a printable byte", json.p_show("x", 0), "'x'");
    test.ck_str("and names an unprintable one", json.p_show("\x01", 0), "byte 1");
    test.ck_str("and says so past the end", json.p_show("x", 9), "end of input");
    test.ck_eq("hexval is one digit", json.hexval(102), 15);
    test.ck_eq("and -1 for anything else", json.hexval(120), -1);

    test.group("parse_bytes and the constructors");
    let raw: [byte] = [123, 34, 107, 34, 58, 49, 125];   // {"k":1}, seven bytes
    test.ck_str("parse_bytes over the first len bytes", {
        json.stringify_val(json.parse_bytes(raw, 7)!, 0)
    }, "{\"k\":1}");
    test.ck("and a len that cuts the document short is a refusal, not a partial", {
        json.parse_bytes(raw, 6) == none
    }, "nothing partial comes back");
    test.ck("and it clamps len to what is there", {
        json.parse_bytes(raw, 999) != none
    }, "no trap on a len past the end");
    test.ck("every constructor builds the shape it names", {
        json.is_null(json.nul())
            && json.as_bool(json.boolean(false))! == false
            && json.as_str(json.str("s"))! == "s"
            && json.as_long(json.num(-4))! == -4
            && json.as_long(json.numtext("4"))! == 4
            && (json.as_arr(json.jarr(json.arr()))!).length == 0
            && json.keys_of((json.as_obj(json.jobj(json.obj()))!)).length == 0
    }, "nul, boolean, str, num, numtext, jarr and jobj");

    return test.report();
};

// json_deep(n) -> str -- an array nested n deep, as text.
def json_deep(n: long) -> str {
    let s: [byte] = [];
    for _ in 0..n { s += [91]; };
    for _ in 0..n { s += [93]; };
    from_bytes(s)
};

// json_tall(n) -> json.Val -- the same shape as a value, for the printer.
def json_tall(n: long) -> json.Val {
    let v: json.Val = json.jarr(json.arr());
    for _ in 0..n {
        let outer = json.arr();
        outer += v;
        v = json.jarr(outer);
    };
    v
};

exit(main());